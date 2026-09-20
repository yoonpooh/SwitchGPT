import XCTest
@testable import SwitchGPT

@MainActor
final class JevSettingsTests: XCTestCase {
    func testOlderPreferencesDecodeWithModelRoutingOffAndPreserveSetupState() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = root.appendingPathComponent("routing-preferences.json")
        let configuredAt = Date(timeIntervalSince1970: 2_000_000_000)
        let old = try JSONSerialization.data(withJSONObject: [
            "automatic": false,
            "configuredAt": configuredAt.timeIntervalSinceReferenceDate,
            "desktopVerified": true
        ])
        try old.write(to: preferences)

        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), vault: TestCredentialVault())

        XCTAssertFalse(store.routingPreferences.automatic)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertEqual(store.routingPreferences.configuredAt, configuredAt)
        XCTAssertTrue(store.routingPreferences.desktopVerified)
    }

    func testModelRoutingRequiresAKeyAndKeyLifecycleStaysOutOfPreferences() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), vault: vault)

        store.setModelAutomatic(true)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertFalse(store.hasJevAPIKey)
        XCTAssertNil(vault.values[AccountStore.jevAPIKeyID])

        XCTAssertTrue(store.saveJevAPIKey("jev-secret"))
        XCTAssertTrue(store.hasJevAPIKey)
        XCTAssertEqual(vault.values[AccountStore.jevAPIKeyID], Data("jev-secret".utf8))
        store.setModelAutomatic(true)
        XCTAssertTrue(store.routingPreferences.modelAutomatic)

        let preferences = try String(contentsOf: root.appendingPathComponent("routing-preferences.json"), encoding: .utf8)
        XCTAssertFalse(preferences.contains("jev-secret"))

        XCTAssertTrue(store.removeJevAPIKey())
        XCTAssertFalse(store.hasJevAPIKey)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertNil(vault.values[AccountStore.jevAPIKeyID])
    }

    func testCompletedChangedRouteIsShownThenClearedByUnchangedCompletion() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), vault: TestCredentialVault())
        let decision = ModelRoutingDecision(originalModel: "gpt-6-astra", originalEffort: "medium",
                                             selectedModel: "gpt-5.6-luna", selectedEffort: "max", reason: "routed")
        var changed = RelayEvent(date: .now, accountFingerprint: "account", path: "/backend-api/codex/responses",
                                 model: "gpt-5.6-luna", status: 200, completed: true)
        changed.modelRouting = decision
        store.received(changed)
        XCTAssertEqual(store.lastCompletedModelRouting, decision)
        XCTAssertEqual(RoutingStatusView.modelRoutingSummary(decision), "Astra medium → Luna max")

        var unchanged = RelayEvent(date: .now.addingTimeInterval(1), accountFingerprint: "account",
                                    path: "/backend-api/codex/responses", model: "gpt-6-astra", status: 200, completed: true)
        unchanged.modelRouting = ModelRoutingDecision(originalModel: "gpt-6-astra", originalEffort: "medium",
                                                       selectedModel: "gpt-6-astra", selectedEffort: "medium", reason: "keep")
        store.received(unchanged)
        XCTAssertNil(store.lastCompletedModelRouting)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

@MainActor
private final class TestCredentialVault: CredentialVault {
    var values: [String: Data] = [:]

    func save(_ data: Data, id: String) throws { values[id] = data }
    func read(_ id: String) throws -> Data {
        guard let value = values[id] else { throw SwitchError(message: "missing") }
        return value
    }
    func remove(_ id: String) throws { values.removeValue(forKey: id) }
}
