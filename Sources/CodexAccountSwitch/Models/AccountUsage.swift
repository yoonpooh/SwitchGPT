import Foundation

struct AccountUsage: Decodable {
    let planType: String?
    let rateLimit: Limit?
    let rateLimitResetCredits: ResetCredits?
    struct ResetCredits: Decodable {
        let availableCount: Int
        let applicableAvailableCount: Int?
    }
    struct Limit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }
    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int
        let resetAt: Double
        var remaining: Double { max(0, min(100, 100 - usedPercent)) }
        var label: String {
            if limitWindowSeconds == 604800 { return L10n.text("weekly") }
            if limitWindowSeconds % 3600 == 0 { return L10n.format("hours", limitWindowSeconds / 3600) }
            return L10n.format("minutes", limitWindowSeconds / 60)
        }
        var resetDate: Date { Date(timeIntervalSince1970: resetAt) }
    }
    static func decode(_ data: Data) throws -> AccountUsage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}

struct ResetCreditDetails: Decodable {
    let credits: [Credit]
    struct Credit: Decodable {
        let status: String
        let expires_at: String?
        var expiration: Date? {
            guard let value = expires_at else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
    }
    var availableCredits: [Credit] {
        credits.filter { $0.status == "available" }
            .sorted { ($0.expiration ?? .distantFuture) < ($1.expiration ?? .distantFuture) }
    }
}
