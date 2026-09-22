import XCTest
@testable import SwitchGPT

@MainActor
final class JevSettingsTests: XCTestCase {
    func testOlderPreferencesDecodeWithEffortRoutingOffAndPreserveSetupState() throws {
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
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertEqual(store.routingPreferences.configuredAt, configuredAt)
        XCTAssertTrue(store.routingPreferences.desktopVerified)
    }

    func testLegacyModelToggleMigratesToEffortRoutingAndIsRewritten() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = root.appendingPathComponent("routing-preferences.json")
        let old = try JSONSerialization.data(withJSONObject: [
            "automatic": true,
            "modelAutomatic": true
        ])
        try old.write(to: preferences)
        let vault = TestCredentialVault()
        vault.values[AccountStore.jevAPIKeyID] = Data("legacy-key".utf8)

        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), vault: vault)

        XCTAssertTrue(store.routingPreferences.effortAutomatic)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any])
        XCTAssertEqual(saved["effortAutomatic"] as? Bool, true)
        XCTAssertNil(saved["modelAutomatic"])
    }

    func testEffortRoutingRequiresAKeyAndKeyLifecycleStaysOutOfPreferences() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), vault: vault)

        store.setEffortAutomatic(true)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertFalse(store.hasJevAPIKey)
        XCTAssertNil(vault.values[AccountStore.jevAPIKeyID])

        XCTAssertTrue(store.saveJevAPIKey("jev-secret"))
        XCTAssertTrue(store.hasJevAPIKey)
        XCTAssertEqual(vault.values[AccountStore.jevAPIKeyID], Data("jev-secret".utf8))
        store.setEffortAutomatic(true)
        XCTAssertTrue(store.routingPreferences.effortAutomatic)

        let preferences = try String(contentsOf: root.appendingPathComponent("routing-preferences.json"), encoding: .utf8)
        XCTAssertFalse(preferences.contains("jev-secret"))

        XCTAssertTrue(store.removeJevAPIKey())
        XCTAssertFalse(store.hasJevAPIKey)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertNil(vault.values[AccountStore.jevAPIKeyID])
    }

    func testEffortPreferenceReloadsWithoutModelRouting() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let index = root.appendingPathComponent("accounts.json")
        let store = AccountStore(index: index, vault: vault)

        XCTAssertTrue(store.saveJevAPIKey("jev-secret"))
        store.setEffortAutomatic(true)
        XCTAssertTrue(store.routingPreferences.effortAutomatic)

        let reloaded = AccountStore(index: index, vault: vault)
        XCTAssertTrue(reloaded.routingPreferences.effortAutomatic)
    }

    func testLegacyEnabledPreferenceWithoutKeyIsDisabled() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = root.appendingPathComponent("routing-preferences.json")
        let old = try JSONSerialization.data(withJSONObject: ["modelAutomatic": true])
        try old.write(to: preferences)

        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), vault: TestCredentialVault())

        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        let saved = try JSONDecoder().decode(RoutingPreferences.self, from: Data(contentsOf: preferences))
        XCTAssertFalse(saved.effortAutomatic)
        let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: preferences)) as? [String: Any])
        XCTAssertNil(savedObject["modelAutomatic"])
    }

    func testDisablingEffortTakesEffectWhenPreferencesCannotBeSaved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        let vault = TestCredentialVault()
        let store = AccountStore(index: blocked.appendingPathComponent("accounts.json"), vault: vault)
        XCTAssertTrue(store.saveJevAPIKey("jev-secret"))

        store.setEffortAutomatic(true)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertEqual(store.message, L10n.text("jev_settings_save_failed"))

        store.routingPreferences.effortAutomatic = true
        store.setEffortAutomatic(false)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertEqual(store.message, L10n.text("jev_settings_save_failed"))
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
