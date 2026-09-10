import Foundation

enum AccountAvailability: Equatable, Sendable {
    case available
    case exhausted
    case unknown
}

struct RoutingCandidate: Sendable {
    let credentials: RelayCredentials
    let availability: AccountAvailability
    let observedAt: Date
}

/// Selection and quota decisions are shared by concurrent requests under one lock.
final class AccountRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RelayCredentials?
    private var candidates: [RoutingCandidate] = []
    private var automatic = false
    private var exhaustedAt: [String: Date] = [:]
    private let didSwitch: @Sendable (RelayCredentials) -> Void

    init(didSwitch: @escaping @Sendable (RelayCredentials) -> Void = { _ in }) {
        self.didSwitch = didSwitch
    }

    var selected: RelayCredentials? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func isCurrentExhausted(now: Date = .now) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current else { return false }
        return exhaustedAt[current.fingerprint] != nil || candidates.contains {
            $0.credentials.fingerprint == current.fingerprint && $0.availability == .exhausted
                && now.timeIntervalSince($0.observedAt) <= 120
        }
    }

    func select(_ credentials: RelayCredentials) {
        lock.lock(); defer { lock.unlock() }
        current = credentials
    }

    func update(_ candidates: [RoutingCandidate], automatic: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.candidates = candidates
        self.automatic = automatic
        // Only a newer, successful quota query can clear a server-confirmed limit.
        for candidate in candidates where candidate.availability == .available {
            let key = candidate.credentials.fingerprint
            if let blockedAt = exhaustedAt[key], candidate.observedAt > blockedAt {
                exhaustedAt.removeValue(forKey: key)
            }
        }
    }

    func resolve(now: Date = .now, excluding: Set<String> = [], exhausted: RelayCredentials? = nil) -> RelayCredentials? {
        lock.lock()
        if let exhausted { exhaustedAt[exhausted.fingerprint] = now }
        guard let previous = current else { lock.unlock(); return nil }
        guard automatic else {
            lock.unlock()
            return exhausted == nil && !excluding.contains(previous.fingerprint) ? previous : nil
        }
        let knownExhausted = exhaustedAt[previous.fingerprint] != nil || candidates.contains {
            $0.credentials.fingerprint == previous.fingerprint && $0.availability == .exhausted
                && now.timeIntervalSince($0.observedAt) <= 120
        }
        if !knownExhausted && !excluding.contains(previous.fingerprint) {
            lock.unlock(); return previous
        }
        let next = candidates.first {
            $0.availability == .available && now.timeIntervalSince($0.observedAt) <= 120
                && exhaustedAt[$0.credentials.fingerprint] == nil && !excluding.contains($0.credentials.fingerprint)
        }?.credentials
        if let next { current = next }
        lock.unlock()
        if let next, next.fingerprint != previous.fingerprint { didSwitch(next) }
        return next
    }
}

enum QuotaFailure {
    /// A temporary 429 is not an exhausted subscription and must not rotate accounts.
    static func isExhausted(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        return error["type"] as? String == "usage_limit_reached" || error["code"] as? String == "usage_limit_reached"
    }
}
