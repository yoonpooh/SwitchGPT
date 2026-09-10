import XCTest
@testable import SwitchGPT

final class AccountRouterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testEitherQuotaWindowCanExhaustAnAccountAndResetDataMustBeRefreshed() throws {
        func usage(_ primary: Double, _ secondary: Double, reset: Double = 2_000_000_100) throws -> AccountUsage {
            try AccountUsage.decode(Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(primary),\"limit_window_seconds\":18000,\"reset_at\":\(reset)},\"secondary_window\":{\"used_percent\":\(secondary),\"limit_window_seconds\":604800,\"reset_at\":\(reset)}}}".utf8))
        }
        XCTAssertEqual(try usage(100, 10).availability(at: now), .exhausted)
        XCTAssertEqual(try usage(10, 100).availability(at: now), .exhausted)
        XCTAssertEqual(try usage(99.9, 10).availability(at: now), .available)
        XCTAssertEqual(try usage(100, 100, reset: now.timeIntervalSince1970 - 1).availability(at: now), .unknown)
        XCTAssertEqual(try AccountUsage.decode(Data("{}".utf8)).availability(at: now), .unknown)
    }

    func testKnownZeroSkipsUnknownAndStaleCandidatesInListOrder() throws {
        let router = AccountRouter()
        let first = try credentials("first"), second = try credentials("second"), third = try credentials("third")
        router.select(first)
        router.update([
            RoutingCandidate(credentials: first, availability: .exhausted, observedAt: now),
            RoutingCandidate(credentials: second, availability: .unknown, observedAt: now),
            RoutingCandidate(credentials: third, availability: .available, observedAt: now.addingTimeInterval(-121))
        ], automatic: true)
        XCTAssertNil(router.resolve(now: now))
        router.update([
            RoutingCandidate(credentials: first, availability: .exhausted, observedAt: now),
            RoutingCandidate(credentials: third, availability: .available, observedAt: now),
            RoutingCandidate(credentials: second, availability: .available, observedAt: now)
        ], automatic: true)
        XCTAssertEqual(router.resolve(now: now)?.fingerprint, third.fingerprint)
    }

    func testAllExhaustedStopsAndFreshQuotaRestoresEligibility() throws {
        let router = AccountRouter()
        let first = try credentials("first"), second = try credentials("second")
        router.select(first)
        let candidates = [first, second].map { RoutingCandidate(credentials: $0, availability: .available, observedAt: now) }
        router.update(candidates, automatic: true)
        XCTAssertEqual(router.resolve(now: now, excluding: [first.fingerprint], exhausted: first)?.fingerprint, second.fingerprint)
        XCTAssertNil(router.resolve(now: now, excluding: [first.fingerprint, second.fingerprint], exhausted: second))
        router.update(candidates, automatic: true)
        XCTAssertNil(router.resolve(now: now)) // The old available snapshot cannot clear the rejection.
        router.update([RoutingCandidate(credentials: first, availability: .available, observedAt: now.addingTimeInterval(1))], automatic: true)
        XCTAssertEqual(router.resolve(now: now.addingTimeInterval(1))?.fingerprint, first.fingerprint)
    }

    func testManualSelectionWinsOverLateFailureAndAutomaticCanBeDisabled() throws {
        let router = AccountRouter()
        let first = try credentials("first"), second = try credentials("second"), third = try credentials("third")
        router.select(first)
        router.update([first, second, third].map { RoutingCandidate(credentials: $0, availability: .available, observedAt: now) }, automatic: true)
        router.select(third)
        XCTAssertEqual(router.resolve(now: now, excluding: [first.fingerprint], exhausted: first)?.fingerprint, third.fingerprint)
        router.update([RoutingCandidate(credentials: third, availability: .exhausted, observedAt: now)], automatic: false)
        XCTAssertEqual(router.resolve(now: now)?.fingerprint, third.fingerprint)
        XCTAssertNil(router.resolve(now: now, excluding: [third.fingerprint], exhausted: third))
    }

    func testOnlyStructuredSubscriptionQuotaErrorsPermitRetry() {
        XCTAssertTrue(QuotaFailure.isExhausted(Data("{\"error\":{\"type\":\"usage_limit_reached\"}}".utf8)))
        for body in ["quota exhausted", "{\"error\":{\"type\":\"rate_limit_exceeded\"}}", "{\"error\":{\"type\":\"invalid_token\"}}"] {
            XCTAssertFalse(QuotaFailure.isExhausted(Data(body.utf8)))
        }
    }

    func testDesktopAndMobileRemoteOriginsAreRecognizedWithoutCLIConfirmation() throws {
        for origin in ["codex desktop", "codex_desktop"] {
            let request = RelayRequest(method: "POST", target: "/backend-api/codex/responses",
                                       headers: ["originator": origin], body: Data())
            XCTAssertEqual(RelayEvent.client(for: request), "desktop")
        }
        let cli = RelayRequest(method: "POST", target: "/backend-api/codex/responses", headers: ["originator": "codex_exec"], body: Data())
        XCTAssertEqual(RelayEvent.client(for: cli), "cli")
    }

    @MainActor func testSetupRemainsPendingUntilDesktopRequestAndSelectionStaysSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"))
        store.accounts = ["first", "second"].map { Account(id: $0, name: $0, savedAt: now) }
        store.currentID = "second"
        store.routingPreferences.configuredAt = now
        store.desktopLaunchedAt = now.addingTimeInterval(-1)
        XCTAssertTrue(store.needsRestart)
        let first = RelayCredentials.fingerprint("first")
        let old = RelayEvent(date: now.addingTimeInterval(-1), accountFingerprint: first, path: "/backend-api/codex/responses", status: 200, completed: true, client: "desktop")
        store.received(old)
        XCTAssertTrue(store.needsRestart)
        store.received(RelayEvent(date: now, accountFingerprint: first, path: "/backend-api/codex/models", status: 200, completed: true, client: "desktop"))
        XCTAssertTrue(store.needsRestart)
        store.received(RelayEvent(date: now, accountFingerprint: first, path: "/backend-api/codex/responses", status: 200, completed: true, client: "cli"))
        XCTAssertTrue(store.needsRestart)
        store.desktopLaunchedAt = now.addingTimeInterval(1)
        XCTAssertFalse(store.needsRestart)
        XCTAssertFalse(store.routingPreferences.desktopVerified)
        store.received(RelayEvent(date: now.addingTimeInterval(2), accountFingerprint: first, path: "/backend-api/codex/responses", status: 200, completed: true, client: "desktop"))
        XCTAssertTrue(store.routingPreferences.desktopVerified)
        XCTAssertEqual(store.lastRequestAccount?.id, "first")
        XCTAssertEqual(store.selectedAccount?.id, "second")
        XCTAssertTrue(AccountStore(index: root.appendingPathComponent("accounts.json")).routingPreferences.desktopVerified)
    }

    private func credentials(_ name: String) throws -> RelayCredentials {
        let claims = Data("{\"sub\":\"\(name)\"}".utf8).base64EncodedString()
        let credential = try Credential(data: Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"\(name)\",\"access_token\":\"\(name)-token\",\"refresh_token\":\"fake\",\"id_token\":\"header.\(claims).sig\"}}".utf8))
        return try RelayCredentials(credential)
    }
}
