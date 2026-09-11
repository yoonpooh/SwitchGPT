import Foundation

struct ResetCreditReceipt {
    let result: ResetCreditResult
    let usage: AccountUsage?
    let details: ResetCreditDetails?
    let observedAt: Date?
    let reconciled: Bool
}

@MainActor
struct ResetCreditService {
    let client: UsageClient
    let ledger: ResetCreditLedger

    func redeem(_ credential: Credential) async throws -> ResetCreditReceipt {
        // An uncertain previous request must be retried even if the refreshed count is zero.
        if try ledger.pending(credential.id) == nil {
            let queriedAt = Date.now
            let usage = try await client.fetch(credential)
            guard let credits = usage.rateLimitResetCredits else {
                throw SwitchError(message: L10n.text("reset_unavailable"))
            }
            if !credits.canUse {
                return ResetCreditReceipt(result: ResetCreditResult(code: credits.availableCount > 0 ? .nothingToReset : .noCredit),
                                          usage: usage, details: nil, observedAt: queriedAt, reconciled: true)
            }
        }
        let requestID = try ledger.begin(credential.id)
        let result = try await client.consumeResetCredit(credential, requestID: requestID)
        do {
            let queriedAt = Date.now
            let usage = try await client.fetch(credential)
            guard usage.rateLimitResetCredits != nil, usage.rateLimit != nil else {
                throw SwitchError(message: L10n.text("reset_unavailable"))
            }
            let details = (usage.rateLimitResetCredits?.availableCount ?? 0) > 0
                ? try? await client.fetchResetCredits(credential) : nil
            try ledger.finish(credential.id, requestID: requestID)
            return ResetCreditReceipt(result: result, usage: usage, details: details, observedAt: queriedAt, reconciled: true)
        } catch {
            // The redemption result is known, but retain its ID until the read-back succeeds.
            return ResetCreditReceipt(result: result, usage: nil, details: nil, observedAt: nil, reconciled: false)
        }
    }
}
