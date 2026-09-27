import Foundation

/// Plan limits of the Claude Code account signed in on this Mac, from api.anthropic.com/api/oauth/usage.
struct ClaudeUsage: Decodable, Equatable, Sendable {
    let limits: [Limit]

    struct Limit: Decodable, Equatable, Sendable {
        let kind: String
        let percent: Double
        let resetsAt: String?
        let scope: Scope?
    }
    struct Scope: Decodable, Equatable, Sendable {
        struct Name: Decodable, Equatable, Sendable { let displayName: String? }
        let model: Name?
        let surface: Name?
    }
    struct Meter: Equatable {
        let label: String
        let remaining: Double
        let resetDate: Date?
    }

    /// The 5-hour session, the weekly limit, then each model-scoped weekly limit such as Fable.
    var meters: [Meter] {
        let order = ["session": 0, "weekly_all": 1, "weekly_scoped": 2]
        return limits.enumerated()
            .compactMap { position, limit in order[limit.kind].map { (rank: $0, position: position, limit: limit) } }
            .sorted { ($0.rank, $0.position) < ($1.rank, $1.position) }
            .compactMap { entry -> Meter? in
                let limit = entry.limit
                let label: String
                switch limit.kind {
                case "session": label = L10n.format("hours", 5)
                case "weekly_all": label = L10n.text("weekly")
                default:
                    guard let name = limit.scope?.model?.displayName ?? limit.scope?.surface?.displayName else { return nil }
                    label = L10n.format("claude_scoped_weekly", name)
                }
                return Meter(label: label, remaining: max(0, min(100, 100 - limit.percent)),
                             resetDate: limit.resetsAt.flatMap(Self.date))
            }
    }

    /// Accepts microsecond fractions ("2026-09-27T18:09:59.991290+00:00"), which ISO8601DateFormatter rejects.
    static func date(_ value: String) -> Date? {
        let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    static func decode(_ data: Data) throws -> ClaudeUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}

struct ClaudeAccountUsage: Equatable, Sendable {
    let usage: ClaudeUsage
    let plan: String?
    let email: String?
}

struct ClaudeAccountSettings: Codable {
    var nickname: String?
}
