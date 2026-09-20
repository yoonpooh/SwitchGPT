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
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertEqual(store.routingPreferences.configuredAt, configuredAt)
        XCTAssertTrue(store.routingPreferences.desktopVerified)
    }

    func testLegacyModelToggleMigratesToEffortRouting() throws {
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

        XCTAssertTrue(store.routingPreferences.modelAutomatic)
        XCTAssertTrue(store.routingPreferences.effortAutomatic)
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

        store.setEffortAutomatic(true)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)

        XCTAssertTrue(store.saveJevAPIKey("jev-secret"))
        XCTAssertTrue(store.hasJevAPIKey)
        XCTAssertEqual(vault.values[AccountStore.jevAPIKeyID], Data("jev-secret".utf8))
        store.setModelAutomatic(true)
        XCTAssertTrue(store.routingPreferences.modelAutomatic)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)

        store.setEffortAutomatic(true)
        XCTAssertTrue(store.routingPreferences.modelAutomatic)
        XCTAssertTrue(store.routingPreferences.effortAutomatic)

        store.setModelAutomatic(false)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertTrue(store.routingPreferences.effortAutomatic)

        store.setEffortAutomatic(false)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)

        let preferences = try String(contentsOf: root.appendingPathComponent("routing-preferences.json"), encoding: .utf8)
        XCTAssertFalse(preferences.contains("jev-secret"))

        store.setModelAutomatic(true)
        store.setEffortAutomatic(true)
        XCTAssertTrue(store.removeJevAPIKey())
        XCTAssertFalse(store.hasJevAPIKey)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertNil(vault.values[AccountStore.jevAPIKeyID])
    }

    func testIndependentFlagsReloadWithoutCoupling() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCredentialVault()
        let index = root.appendingPathComponent("accounts.json")
        let store = AccountStore(index: index, vault: vault)

        XCTAssertTrue(store.saveJevAPIKey("jev-secret"))
        store.setEffortAutomatic(true)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertTrue(store.routingPreferences.effortAutomatic)

        let reloaded = AccountStore(index: index, vault: vault)
        XCTAssertFalse(reloaded.routingPreferences.modelAutomatic)
        XCTAssertTrue(reloaded.routingPreferences.effortAutomatic)
    }

    func testLegacyEnabledPreferenceWithoutKeyIsDisabledForBothDimensions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = root.appendingPathComponent("routing-preferences.json")
        let old = try JSONSerialization.data(withJSONObject: ["modelAutomatic": true])
        try old.write(to: preferences)

        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), vault: TestCredentialVault())

        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        let saved = try JSONDecoder().decode(RoutingPreferences.self, from: Data(contentsOf: preferences))
        XCTAssertFalse(saved.modelAutomatic)
        XCTAssertFalse(saved.effortAutomatic)
    }

    func testDisablingEachDimensionTakesEffectWhenPreferencesCannotBeSaved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blocked)
        let vault = TestCredentialVault()
        let store = AccountStore(index: blocked.appendingPathComponent("accounts.json"), vault: vault)
        XCTAssertTrue(store.saveJevAPIKey("jev-secret"))

        store.setModelAutomatic(true)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertEqual(store.message, L10n.text("jev_settings_save_failed"))

        store.setEffortAutomatic(true)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertFalse(store.routingPreferences.effortAutomatic)
        XCTAssertEqual(store.message, L10n.text("jev_settings_save_failed"))

        store.routingPreferences.modelAutomatic = true
        store.routingPreferences.effortAutomatic = true
        store.setModelAutomatic(false)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
        XCTAssertTrue(store.routingPreferences.effortAutomatic)
        XCTAssertEqual(store.message, L10n.text("jev_settings_save_failed"))

        store.setEffortAutomatic(false)
        XCTAssertFalse(store.routingPreferences.modelAutomatic)
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
