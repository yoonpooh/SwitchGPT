import XCTest
@testable import SwitchGPT

@MainActor
final class TokenRefreshTests: XCTestCase {
    func credential(access: String = "old-access", refresh: String = "old-refresh", subject: String = "user") throws -> Credential {
        let payload = try JSONSerialization.data(withJSONObject: ["sub": subject]).base64EncodedString()
        return try Credential(data: JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "extra": "keep",
            "tokens": ["account_id": "workspace", "access_token": access, "refresh_token": refresh, "id_token": "h.\(payload).s"]]))
    }
    func testRefreshGrantPreservesIdentityAndRotatesTokens() async throws {
        let backend = RefreshBackend(statuses: [200], bodies: ["{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}"])
        let before = try credential()
        let after = try await TokenRefreshClient(send: { try await backend.send($0) }).refresh(before)
        XCTAssertEqual(after.id, before.id)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: after.data) as? [String: Any])
        XCTAssertEqual(object["extra"] as? String, "keep")
        XCTAssertNotNil(object["last_refresh"])
        let tokens = try XCTUnwrap(object["tokens"] as? [String: String])
        XCTAssertEqual(tokens["refresh_token"], "new-refresh")
        let requests = await backend.requests
        XCTAssertEqual(requests[0].url?.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: String])
        XCTAssertEqual(body["grant_type"], "refresh_token")
        XCTAssertEqual(body["refresh_token"], "old-refresh")
        XCTAssertEqual(body["client_id"], "app_EMoamEEZ73f0CkXaXp7hrann")
    }
    func test401RefreshesOnceAndRetriesWithNewToken() async throws {
        let backend = RefreshBackend(statuses: [401, 200], bodies: ["{}", "{}"])
        var renewals = 0
        let initial = try credential()
        let new = try credential(access: "new-access")
        let result = try await UsageClient(send: { try await backend.send($0) }).fetchWithRefresh(initial, proactively: false) { _ in
            renewals += 1
            return new
        }
        XCTAssertEqual(result.0.data, new.data)
        XCTAssertEqual(renewals, 1)
        let requests = await backend.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer old-access", "Bearer new-access"])
    }
    func testRepeated401And403DoNotLoop() async throws {
        for status in [401, 403, 429, 500] {
            let backend = RefreshBackend(statuses: [status, status], bodies: ["{}", "{}"])
            var renewals = 0
            let initial = try credential()
            do {
                _ = try await UsageClient(send: { try await backend.send($0) }).fetchWithRefresh(initial, proactively: false) { value in
                    renewals += 1; return value
                }
                XCTFail("Expected error")
            } catch {}
            XCTAssertEqual(renewals, status == 401 ? 1 : 0)
        }
    }
    func testProactiveRefreshDoesNotRefreshAgainOn401() async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["exp": 1]).base64EncodedString()
        let initial = try credential(access: "h.\(payload).s")
        XCTAssertTrue(initial.accessTokenExpiresSoon)
        let backend = RefreshBackend(statuses: [401], bodies: ["{}"])
        var renewals = 0
        do {
            _ = try await UsageClient(send: { try await backend.send($0) }).fetchWithRefresh(initial, proactively: true) { value in
                renewals += 1; return value
            }
            XCTFail("Expected error")
        } catch {}
        XCTAssertEqual(renewals, 1)
    }
    func testPersistenceFailureKeepsRotatedTokenForRetry() async throws {
        let backend = RefreshBackend(statuses: [200], bodies: ["{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}"])
        let refresher = CredentialRefresher(client: TokenRefreshClient(send: { try await backend.send($0) }))
        let initial = try credential()
        var saved = initial
        do {
            _ = try await refresher.refresh(initial, load: { saved }, save: { _ in throw SwitchError(message: "storage failed") })
            XCTFail("Expected persistence failure")
        } catch {}
        let result = try await refresher.refresh(initial, load: { saved }, save: { saved = $0 })
        XCTAssertEqual(try RelayCredentials(result).accessToken, "new-access")
        XCTAssertEqual(saved.data, result.data)
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testPermanentFailureIsNotRepeatedUntilNewLogin() async throws {
        let backend = RefreshBackend(statuses: [400, 200], bodies: ["{\"error\":\"invalid_grant\"}", "{\"access_token\":\"new-access\"}"])
        let refresher = CredentialRefresher(client: TokenRefreshClient(send: { try await backend.send($0) }))
        let initial = try credential()
        for _ in 0..<2 {
            do {
                _ = try await refresher.refresh(initial, load: { initial }, save: { _ in })
                XCTFail("Expected reauthentication")
            } catch is RefreshFailure {} catch { XCTFail("Unexpected error") }
        }
        let newLogin = try credential(refresh: "new-login")
        _ = try await refresher.refresh(newLogin, load: { newLogin }, save: { _ in })
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 2)
    }
    func testConcurrentRefreshSharesRequestAndPersistsOnce() async throws {
        let backend = RefreshBackend(statuses: [200], bodies: ["{\"access_token\":\"new-access\"}"])
        let refresher = CredentialRefresher(client: TokenRefreshClient(send: { try await backend.send($0) }))
        let initial = try credential()
        var saved = initial
        var writes = 0
        let first = Task { try await refresher.refresh(initial, load: { saved }, save: { saved = $0; writes += 1 }) }
        let second = Task { try await refresher.refresh(initial, load: { saved }, save: { saved = $0; writes += 1 }) }
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a.data, b.data)
        XCTAssertEqual(writes, 1)
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testRefreshResultSurvivesReadFailureAfterRotation() async throws {
        let backend = RefreshBackend(statuses: [200], bodies: ["{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}"])
        let refresher = CredentialRefresher(client: TokenRefreshClient(send: { try await backend.send($0) }))
        let initial = try credential()
        var reads = 0
        do {
            _ = try await refresher.refresh(initial, load: {
                reads += 1
                if reads == 2 { throw SwitchError(message: "temporarily locked") }
                return initial
            }, save: { _ in XCTFail("Read failed") })
            XCTFail("Expected read error")
        } catch {}
        var saved = initial
        _ = try await refresher.refresh(initial, load: { saved }, save: { saved = $0 })
        XCTAssertEqual(try RelayCredentials(saved).accessToken, "new-access")
        let requests = await backend.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testStorePublishesRefreshedRoutingCredentialEvenWhenUsageFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try credential()
        let desktop = try credential(subject: "desktop")
        let session = CodexSession(home: root)
        try session.write(desktop)
        let vault = MemoryCredentialVault(data: initial.data)
        let oauth = RefreshBackend(statuses: [200], bodies: ["{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\"}"])
        let usage = RefreshBackend(statuses: [401, 500], bodies: ["{}", "{}"])
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"),
            usageClient: UsageClient(send: { try await usage.send($0) }), session: session, vault: vault,
            tokenRefreshClient: TokenRefreshClient(send: { try await oauth.send($0) }))
        store.accounts = [Account(id: initial.id, name: "Test", savedAt: .now)]
        await store.refreshUsage()
        XCTAssertNotNil(store.usageErrors[initial.id])
        XCTAssertEqual(store.routingCredentials[initial.id]?.accessToken, "new-access")
        XCTAssertEqual(try RelayCredentials(Credential(data: vault.data)).accessToken, "new-access")
        XCTAssertEqual(try session.read().data, desktop.data)
    }
    func testDesktopTokensAreSyncedWithoutIndependentOAuthRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try credential()
        let current = try credential(access: "desktop-new", refresh: "desktop-refresh")
        let session = CodexSession(home: root)
        try session.write(current)
        let vault = MemoryCredentialVault(data: old.data)
        let oauth = RefreshBackend(statuses: [], bodies: [])
        let usage = RefreshBackend(statuses: [200, 200], bodies: ["{}", "{}"])
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"),
            usageClient: UsageClient(send: { try await usage.send($0) }), session: session, vault: vault,
            tokenRefreshClient: TokenRefreshClient(send: { try await oauth.send($0) }))
        store.accounts = [Account(id: current.id, name: "Test", savedAt: .now)]
        await store.refreshUsage()
        XCTAssertNil(store.usageErrors[current.id])
        XCTAssertEqual(vault.data, current.data)
        XCTAssertEqual(try session.read().data, current.data)
        let requests = await oauth.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testNewLoginWinsOverStaleRefreshInput() async throws {
        let backend = RefreshBackend(statuses: [], bodies: [])
        let refresher = CredentialRefresher(client: TokenRefreshClient(send: { try await backend.send($0) }))
        let initial = try credential()
        let new = try credential(access: "new-login")
        let value = try await refresher.refresh(initial, load: { new }, save: { _ in XCTFail("Must not overwrite") })
        XCTAssertEqual(value.data, new.data)
        let requests = await backend.requests
        XCTAssertTrue(requests.isEmpty)
    }
}

private actor RefreshBackend {
    var requests: [URLRequest] = []
    var statuses: [Int]
    var bodies: [String]
    init(statuses: [Int], bodies: [String]) { self.statuses = statuses; self.bodies = bodies }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !statuses.isEmpty else { throw URLError(.badServerResponse) }
        let status = statuses.removeFirst()
        let body = bodies.removeFirst()
        try await Task.sleep(for: .milliseconds(10))
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class MemoryCredentialVault: CredentialVault {
    var data: Data
    init(data: Data) { self.data = data }
    func read(_ id: String) throws -> Data { data }
    func save(_ data: Data, id: String) throws { self.data = data }
    func remove(_ id: String) throws {}
}
