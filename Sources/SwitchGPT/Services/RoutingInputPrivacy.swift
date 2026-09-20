import Foundation

/// A deliberately narrow guard for credential-shaped text sent to the Jev classifier.
///
/// This is not a general secret scanner. It only blocks values that look like an
/// embedded credential with enough structure to make forwarding the request unsafe.
enum RoutingInputPrivacy {
    static func containsCredential(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        return containsPEMPrivateKey(text)
            || containsRecognizableToken(text)
            || containsBearerToken(text)
            || containsCredentialAssignment(text)
            || containsCredentialURL(text)
    }

    private static func containsPEMPrivateKey(_ text: String) -> Bool {
        let pattern = #"(?is)-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----\s*([A-Za-z0-9+/=\r\n]{16,})\s*-----END(?: [A-Z0-9]+)* PRIVATE KEY-----"#
        return matches(pattern: pattern, in: text).contains { match in
            guard match.numberOfRanges > 1,
                  let bodyRange = Range(match.range(at: 1), in: text) else {
                return false
            }
            return !isPlaceholder(String(text[bodyRange]))
        }
    }

    private static func containsRecognizableToken(_ text: String) -> Bool {
        let patterns = [
            #"(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{20,}"#,
            #"(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{28,}"#,
            #"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}"#,
            #"(?<![A-Za-z0-9_])AKIA[0-9A-Z]{16}(?![A-Za-z0-9_])"#
        ]

        return patterns.contains { pattern in
            matches(pattern: pattern, in: text).contains { match in
                guard let range = Range(match.range, in: text) else { return false }
                return !isPlaceholder(String(text[range]))
            }
        }
    }

    private static func containsBearerToken(_ text: String) -> Bool {
        let pattern = #"(?i)(?:\bauthorization\b\s*:\s*['\"]?bearer\s+)([A-Za-z0-9._~+/=-]{20,})"#
        return matches(pattern: pattern, in: text).contains { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                return false
            }
            return !isPlaceholder(String(text[valueRange]))
        }
    }

    private static func containsCredentialAssignment(_ text: String) -> Bool {
        let pattern = #"(?i)(?:^|[^A-Za-z0-9_])(?:api[\s_-]*key|access[\s_-]*token|password|비밀번호)\s*['\"]?\s*[:=]\s*['\"]?([^'\"\s,;}\])]+)"#
        return matches(pattern: pattern, in: text).contains { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                return false
            }
            return isConcrete(String(text[valueRange]), minimumLength: 12)
        }
    }

    private static func containsCredentialURL(_ text: String) -> Bool {
        let pattern = #"(?i)\b[a-z][a-z0-9+.-]*:\/\/[^\/\s:@]+:([^@\/\s]+)@[^\/\s?#]+"#
        return matches(pattern: pattern, in: text).contains { match in
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: text) else {
                return false
            }
            return isConcrete(String(text[valueRange]), minimumLength: 8)
        }
    }

    private static func isConcrete(_ value: String, minimumLength: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength, !isPlaceholder(trimmed) else { return false }

        return true
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return true }
        if normalized.contains("<...>") || normalized.contains("…") { return true }

        let exactPlaceholders: Set<String> = [
            "example", "redacted", "placeholder", "dummy", "sample", "changeme",
            "password", "secret", "access_token", "api_key", "token", "pass", "value",
            "your token"
        ]
        if exactPlaceholders.contains(normalized) { return true }

        if normalized.range(of: #"^(?:sk-|ghp_|github_pat_)?(?:example|redacted)[0x*._-]*$"#,
                            options: .regularExpression) != nil { return true }

        // These are explicit documentation templates, rather than arbitrary
        // substrings that could also occur inside a real password or token.
        let templatePrefixes = [
            "example_", "example-", "example ",
            "redacted_", "redacted-", "redacted ",
            "your_", "your-", "your ",
            "replace_me", "replace-me"
        ]
        return templatePrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func matches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range)
    }
}
