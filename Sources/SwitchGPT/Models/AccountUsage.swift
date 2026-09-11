import Foundation

struct AccountUsage: Decodable {
    let planType: String?
    let rateLimit: Limit?
    let rateLimitResetCredits: ResetCredits?
    struct ResetCredits: Decodable {
        let availableCount: Int
        let applicableAvailableCount: Int?
        var canUse: Bool { availableCount > 0 && (applicableAvailableCount ?? availableCount) > 0 }
    }
    struct Limit: Decodable {
        let allowed: Bool?
        let limitReached: Bool?
        let primaryWindow: Window?
        let secondaryWindow: Window?
    }
    func availability(at now: Date = .now) -> AccountAvailability {
        guard let limit = rateLimit else { return .unknown }
        let windows = [limit.primaryWindow, limit.secondaryWindow].compactMap { $0 }
        if windows.contains(where: { $0.usedPercent >= 100 && $0.resetDate > now }) { return .exhausted }
        // A window that has rolled over needs a fresh query; don't reuse its old zero.
        if windows.contains(where: { $0.resetDate <= now || !$0.usedPercent.isFinite }) { return .unknown }
        if limit.limitReached == true || limit.allowed == false { return .exhausted }
        return windows.isEmpty ? .unknown : .available
    }
    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int
        let resetAt: Double
        var remaining: Double { max(0, min(100, 100 - usedPercent)) }
        var label: String {
            if limitWindowSeconds == 604800 { return L10n.text("weekly") }
            if limitWindowSeconds == 2592000 { return L10n.text("monthly") }
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

struct ResetCreditResult: Decodable, Sendable {
    enum Code: String, Decodable, Sendable {
        case reset
        case alreadyRedeemed = "already_redeemed"
        case nothingToReset = "nothing_to_reset"
        case noCredit = "no_credit"
    }
    let code: Code
}

struct ResetCreditMessage {
    let text: String
    let succeeded: Bool
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
