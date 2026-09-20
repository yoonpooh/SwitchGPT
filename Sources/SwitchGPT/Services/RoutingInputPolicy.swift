import Foundation

/// High-precision opt-out for explicit file-preservation constraints in user text.
/// Preserves the incoming model; this does not enforce filesystem permissions.
enum RoutingInputPolicy {
    static func preservesProtectedFiles(_ text: String) -> Bool {
        // Quoted policies/examples are data. Keep inline path backticks available below.
        var value = text.replacingOccurrences(of: #"(?s)```.*?```"#, with: "", options: .regularExpression)
        // Quoted filenames remain actionable targets, unlike quoted policy sentences.
        value = value.replacingOccurrences(of: #"["“]([\w./-]+\.(?:py|swift|ts|tsx|js|json|md))["”]"#,
                                           with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\"[^\"]*\"|“[^”]*”"#, with: "", options: .regularExpression)
        value = value.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
        let target = #"(?:existing\s+(?:test(?:s|\s+files?)|files?)|protected\s+files?|agents\.md|[\w./-]+\.(?:py|swift|ts|tsx|js|json|md))"#
        let patterns = [
            #"(?im)(?:^|[.!?;\n])\s*(?:please\s+)?(?:do\s+not|don't|never)\s+(?:edit|change|modify|remove|overwrite|append\s+to)\b[^\n.!?;]{0,80}\b"# + target,
            #"(?im)\b"# + target + #"\b[^\n;]{0,80}\b(?:are|is|must\s+remain)\s+(?:read-only|immutable)\b"#,
            #"(?m)(?:^|[.!?;\n])\s*(?:기존\s*테스트(?:\s*파일)?|보호(?:된)?\s*파일)[^\n.!?;]{0,60}(?:수정|변경|삭제)[^\n.!?;]{0,20}(?:금지|하지\s*(?:마|말|않))"#
        ]
        return patterns.contains { value.range(of: $0, options: .regularExpression) != nil }
    }
}
