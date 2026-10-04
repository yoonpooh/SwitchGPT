import Foundation

/// Reads top-level assignments without mistaking quoted instructions or array contents for tables.
/// This is a lexical scanner, not a replacement for Codex's full TOML validation.
enum TOMLTopLevel {
    struct Assignment { let key: String; let value: String }
    private enum Quote { case basic, literal, multilineBasic, multilineLiteral }

    static func assignments(in config: String) -> [Assignment] {
        let bytes = Array(config.utf8)
        var result: [Assignment] = []
        var line: [UInt8] = []
        var quote: Quote?
        var depth = 0, index = 0
        var comment = false
        func finish() -> Bool {
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            line.removeAll(keepingCapacity: true)
            if text.hasPrefix("[") { return false }
            guard let equals = text.firstIndex(of: "=") else { return true }
            let rawKey = text[..<equals].trimmingCharacters(in: .whitespaces)
            let key = string(rawKey) ?? rawKey
            result.append(Assignment(key: key, value: text[text.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)))
            return true
        }
        while index < bytes.count {
            let byte = bytes[index]
            if comment {
                if byte == 10 { comment = false; if depth == 0 && !finish() { return result } }
                index += 1
                continue
            }
            if let current = quote {
                let delimiter: UInt8 = current == .literal || current == .multilineLiteral ? 39 : 34
                line.append(byte)
                if byte == 92 && (current == .basic || current == .multilineBasic), index + 1 < bytes.count {
                    index += 1
                    line.append(bytes[index])
                } else if byte == delimiter {
                    if current == .multilineBasic || current == .multilineLiteral {
                        var end = index + 1
                        while end < bytes.count && bytes[end] == delimiter { end += 1 }
                        if end - index >= 3 {
                            line.append(contentsOf: bytes[(index + 1)..<end])
                            index = end - 1
                            quote = nil
                        }
                    } else { quote = nil }
                }
            } else if byte == 35 { comment = true }
            else if byte == 34 || byte == 39 {
                let triple = index + 2 < bytes.count && bytes[index + 1] == byte && bytes[index + 2] == byte
                quote = byte == 34 ? (triple ? .multilineBasic : .basic) : (triple ? .multilineLiteral : .literal)
                line.append(byte)
                if triple { line.append(contentsOf: bytes[(index + 1)...(index + 2)]); index += 2 }
            } else if byte == 10 && depth == 0 {
                if !finish() { return result }
            } else {
                line.append(byte)
                if byte == 91 || byte == 123 { depth += 1 }
                if byte == 93 || byte == 125 { depth = max(0, depth - 1) }
            }
            index += 1
        }
        _ = finish()
        return result
    }

    /// Values can use triple quotes and basic-string line continuations; keys cannot.
    static func valueString(_ value: String) -> String? {
        let basic = value.hasPrefix("\"\"\"") && value.hasSuffix("\"\"\"")
        let literal = value.hasPrefix("'''") && value.hasSuffix("'''")
        guard value.count >= 6, basic || literal else { return string(value) }
        var body = String(value.dropFirst(3).dropLast(3))
        if body.hasPrefix("\r\n") { body.removeFirst(2) }
        else if body.hasPrefix("\n") { body.removeFirst() }
        if literal { return body }
        let scalars = Array(body.unicodeScalars)
        var unfolded = String.UnicodeScalarView(), index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                var end = index + 1, newline = false
                while end < scalars.count && [9, 10, 13, 32].contains(scalars[end].value) {
                    newline = newline || scalars[end] == "\n"
                    end += 1
                }
                if newline { index = end; continue }
                // Preserve escaped backslashes so the following newline is not mistaken for a continuation.
                unfolded.append(scalar)
                index += 1
                unfolded.append(scalars[index])
            } else { unfolded.append(scalar) }
            index += 1
        }
        return string("\"" + String(unfolded) + "\"")
    }

    static func string(_ value: String) -> String? {
        guard value.count >= 2 else { return nil }
        if value.hasPrefix("'"), value.hasSuffix("'"), !value.hasPrefix("'''") { return String(value.dropFirst().dropLast()) }
        guard value.hasPrefix("\""), value.hasSuffix("\""), !value.hasPrefix("\"\"\"") else { return nil }
        // TOML supports both four- and eight-digit Unicode escapes; JSON only supports four.
        let scalars = Array(value.unicodeScalars.dropFirst().dropLast())
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar != "\\" {
                guard scalar != "\"", scalar.value >= 0x20, scalar.value != 0x7f else { return nil }
                result.append(scalar)
                continue
            }
            guard index < scalars.count else { return nil }
            let escaped = scalars[index]
            index += 1
            switch escaped {
            case "b": result.append("\u{8}")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "f": result.append("\u{c}")
            case "r": result.append("\r")
            case "\"", "\\": result.append(escaped)
            case "u", "U":
                let digits = escaped == "u" ? 4 : 8
                guard scalars.count - index >= digits else { return nil }
                var code: UInt32 = 0
                for digit in scalars[index..<(index + digits)] {
                    let nibble: UInt32
                    switch digit.value {
                    case 48...57: nibble = digit.value - 48
                    case 65...70: nibble = digit.value - 65 + 10
                    case 97...102: nibble = digit.value - 97 + 10
                    default: return nil
                    }
                    code = (code << 4) | nibble
                }
                guard let decoded = Unicode.Scalar(code) else { return nil }
                result.append(decoded)
                index += digits
            default: return nil
            }
        }
        return String(result)
    }
}
