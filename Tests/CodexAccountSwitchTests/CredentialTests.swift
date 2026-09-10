import XCTest
@testable import CodexAccountSwitch

final class CredentialTests: XCTestCase {
    private func fixture(subject: String = "user-a", account: String = "workspace") throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["sub": subject, "email": "person@example.com"]).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["account_id": account, "access_token": "fake", "refresh_token": "fake", "id_token": "header.\(payload).signature"]])
    }
    func testEmailComesFromLoginClaims() throws {
        XCTAssertEqual(try Credential(data: fixture()).email, "person@example.com")
    }
    func testRejectsAPIKeyAndIncompleteTokens() {
        XCTAssertThrowsError(try Credential(data: Data("{\"auth_mode\":\"apikey\"}".utf8)))
        XCTAssertThrowsError(try Credential(data: Data("{}".utf8)))
    }
    func testUsersInSameWorkspaceRemainDistinct() throws {
        XCTAssertNotEqual(try Credential(data: fixture(subject: "a")).id, try Credential(data: fixture(subject: "b")).id)
    }
    @MainActor func testCredentialReplacementAndRollbackStayPrivate() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = CodexSession(home: home)
        let first = try Credential(data: fixture(subject: "first"))
        let second = try Credential(data: fixture(subject: "second"))
        try session.write(first)
        let backup = try session.read()
        try session.write(second)
        XCTAssertEqual(try session.read().id, second.id)
        try session.write(backup)
        XCTAssertEqual(try session.read().id, first.id)
        let attributes = try FileManager.default.attributesOfItem(atPath: session.auth.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), ["auth.json"])
    }
    @MainActor func testRejectsKeychainStore() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("cli_auth_credentials_store = \"keyring\"".utf8).write(to: home.appendingPathComponent("config.toml"))
        XCTAssertThrowsError(try CodexSession(home: home).validateStore())
    }
}
