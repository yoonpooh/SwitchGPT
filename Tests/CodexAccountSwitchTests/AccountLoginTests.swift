import XCTest
@testable import CodexAccountSwitch

final class AccountLoginTests: XCTestCase {
    @MainActor func testLoginUsesIsolatedHomeAndCleansItUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-login")
        let marker = directory.appendingPathComponent("home-path")
        let payload = Data("{\"sub\":\"fake-user\"}".utf8).base64EncodedString()
        let fixture = "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"fake-account\",\"access_token\":\"fake\",\"refresh_token\":\"fake\",\"id_token\":\"header.\(payload).signature\"}}"
        let source = """
        #!/bin/sh
        test "$1" = login || exit 4
        test "$3" = 'cli_auth_credentials_store="file"' || exit 5
        test "$CODEX_HOME" != "$HOME/.codex" || exit 6
        printf '%s' "$CODEX_HOME" > '\(marker.path)'
        printf '%s' '\(fixture)' > "$CODEX_HOME/auth.json"
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let credential = try await AccountLogin().run(executable: script)
        XCTAssertEqual(credential.id, "fake-account|fake-user")
        let temporaryHome = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryHome))
    }
    @MainActor func testTimeoutTerminatesLoginAndCleansDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-login")
        let marker = directory.appendingPathComponent("home-path")
        try "#!/bin/sh\nprintf '%s' \"$CODEX_HOME\" > '\(marker.path)'\nexec /bin/sleep 20\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        do {
            _ = try await AccountLogin().run(executable: script, timeout: .milliseconds(300))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error.localizedDescription, L10n.text("login_timeout")) }
        let temporaryHome = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryHome))
    }
    func testResetExpiryIgnoresRedeemedAndFindsEarliest() throws {
        let data = Data(#"{"credits":[{"status":"redeemed","expires_at":"2026-09-01T00:00:00Z"},{"status":"available","expires_at":"2026-10-05T04:19:10.819354Z"},{"status":"available","expires_at":"2026-10-10T00:00:00Z"}]}"#.utf8)
        let details = try JSONDecoder().decode(ResetCreditDetails.self, from: data)
        XCTAssertEqual(details.availableCredits.count, 2)
        XCTAssertEqual(details.availableCredits[0].expiration?.timeIntervalSince1970 ?? 0, 1791173950.819354, accuracy: 0.01)
        XCTAssertEqual(details.availableCredits[1].expiration?.timeIntervalSince1970 ?? 0, 1791590400, accuracy: 0.01)
    }
    func testResetCreditsDistinguishesOwnedAndApplicable() throws {
        let usage = try AccountUsage.decode(Data(#"{"rate_limit_reset_credits":{"available_count":1,"applicable_available_count":0}}"#.utf8))
        XCTAssertEqual(usage.rateLimitResetCredits?.availableCount, 1)
        XCTAssertEqual(usage.rateLimitResetCredits?.applicableAvailableCount, 0)
        XCTAssertNil(try AccountUsage.decode(Data("{}".utf8)).rateLimitResetCredits)
    }
    func testUsageOnlyShowsReturnedWindowAndClampsRemaining() throws {
        let data = Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":73,"limit_window_seconds":604800,"reset_at":1789436413},"secondary_window":null}}"#.utf8)
        let usage = try AccountUsage.decode(data)
        XCTAssertEqual(usage.rateLimit?.primaryWindow?.remaining, 27)
        XCTAssertEqual(usage.rateLimit?.primaryWindow?.label, L10n.text("weekly"))
        XCTAssertNil(usage.rateLimit?.secondaryWindow)
        XCTAssertEqual(AccountUsage.Window(usedPercent: 110, limitWindowSeconds: 18000, resetAt: 0).remaining, 0)
        XCTAssertNil(try AccountUsage.decode(Data("{}".utf8)).rateLimit)
    }
}
