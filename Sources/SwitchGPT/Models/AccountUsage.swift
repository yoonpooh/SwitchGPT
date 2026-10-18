import Foundation

struct AccountUsage: Decodable {
    let planType: String?
    let rateLimit: Limit?
    let rateLimitResetCredits: ResetCredits?
    let credits: Credits?
    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
    }
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

enum CreditBalanceState: Equatable {
    case balance(String)
    case unlimited
    case unavailable
    case failed

    static func resolve(usage: AccountUsage?, queryFailed: Bool) -> Self {
        guard !queryFailed else { return .failed }
        guard let credits = usage?.credits else { return .unavailable }
        if credits.unlimited == true { return .unlimited }
        guard let balance = credits.balance?.trimmingCharacters(in: .whitespacesAndNewlines),
              balance.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
        else { return .unavailable }
        return .balance(balance)
    }

    var text: String {
        switch self {
        case .balance(let value): return Self.formattedBalance(value)
        case .unlimited: return L10n.text("credits_balance_unlimited")
        case .unavailable: return L10n.text("credits_balance_unavailable")
        case .failed: return L10n.text("credits_balance_failed")
        }
    }

    private static func formattedBalance(_ value: String) -> String {
        let parts = value.split(separator: ".")
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        let whole = parts[0].drop(while: { $0 == "0" })
        var digits = Array((whole.isEmpty ? "0" : String(whole)).utf8)

        // Round decimal digits directly to avoid binary floating-point and precision limits.
        if let firstFractionDigit = fraction.first, firstFractionDigit >= "5" {
            var carry = true
            for index in digits.indices.reversed() {
                if digits[index] < 57 {
                    digits[index] += 1
                    carry = false
                    break
                }
                digits[index] = 48
            }
            if carry { digits.insert(49, at: 0) }
        }

        var grouped: [UInt8] = []
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index).isMultiple(of: 3) { grouped.append(44) }
            grouped.append(digit)
        }
        return String(decoding: grouped, as: UTF8.self)
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
    let detail: String?
    let succeeded: Bool
}

/// Why a reset cannot be used right now; nil from AccountStore.resetBlock means it can.
enum ResetBlock: Equatable {
    case busy
    case storage
    case stale
    case noCredit
    case notApplicable
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
