import XCTest
import Network
@testable import SwitchGPT

final class OpenCodeGoTests: XCTestCase {
    private func request(_ model: String = OpenCodeGo.model) -> RelayRequest {
        RelayRequest(method: "POST", target: "/backend-api/codex/responses", headers: [
            "authorization": "Bearer desktop-secret", "chatgpt-account-id": "private-account",
            "cookie": "private-cookie", "x-openai-actor-authorization": "private-actor",
            "session_id": "stable-session", "content-encoding": "identity"
        ], body: ClaudeBridge.encode(["model": model, "input": [["type": "function_call_output", "call_id": "call_1", "output": "done"]],
                                     "reasoning": ["effort": "ultra"], "service_tier": "priority"]))
    }

    func testOnlyGoCredentialsAndSessionCrossProviderBoundary() throws {
        let go = OpenCodeGo()
        go.setKey("go-test-key")
        let result = try go.request(request())
        XCTAssertEqual(result.url?.absoluteString, "https://opencode.ai/zen/go/v1/responses")
        XCTAssertEqual(result.value(forHTTPHeaderField: "Authorization"), "Bearer go-test-key")
        XCTAssertEqual(result.value(forHTTPHeaderField: "x-opencode-session"), "stable-session")
        for name in ["Cookie", "ChatGPT-Account-Id", "x-openai-actor-authorization", "content-encoding"] {
            XCTAssertNil(result.value(forHTTPHeaderField: name))
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(result.httpBody)) as? [String: Any])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "max")
        XCTAssertNil(body["service_tier"])
        XCTAssertEqual((body["input"] as? [[String: Any]])?.first?["call_id"] as? String, "call_1")
        XCTAssertFalse(String(describing: result.allHTTPHeaderFields).contains("desktop-secret"))
    }

    func testForkedThreadSessionTakesPrecedenceOverParentSession() throws {
        let go = OpenCodeGo()
        go.setKey("test-key")
        let original = request()
        var headers = original.headers
        headers["x-codex-turn-metadata"] = #"{"thread_id":"fork-thread"}"#
        let fork = RelayRequest(method: original.method, target: original.target, headers: headers, body: original.body)
        XCTAssertEqual(try go.request(fork).value(forHTTPHeaderField: "x-opencode-session"), "fork-thread")
        headers = ["session-id": "desktop-session"]
        let desktop = RelayRequest(method: original.method, target: original.target, headers: headers, body: original.body)
        XCTAssertEqual(try go.request(desktop).value(forHTTPHeaderField: "x-opencode-session"), "desktop-session")
    }

    func testDisabledUnknownAndMissingSessionRequestsFailClosed() throws {
        let go = OpenCodeGo()
        XCTAssertThrowsError(try go.request(request()))
        go.setKey("test-key")
        XCTAssertThrowsError(try go.request(request("deepseek-unknown")))
        XCTAssertThrowsError(try go.request(request("gpt-6.1-sol")))
        XCTAssertThrowsError(try go.request(request().removingHeader("session_id")))
        for key in ["", " \n", "key\r\nInjected: true", "bad key"] { XCTAssertThrowsError(try OpenCodeGo.validatedKey(key)) }
        XCTAssertEqual(try OpenCodeGo.validatedKey("  oc_sk_test\n"), "oc_sk_test")
        go.setKey(nil)
        XCTAssertThrowsError(try go.request(request()))
    }

    func testDeepSeekRoutingDoesNotApplyOpenAIHistoryCleanup() throws {
        let body = ClaudeBridge.encode(["model": OpenCodeGo.model, "input": [["type": "reasoning", "summary": []]]])
        let req = RelayRequest(method: "POST", target: "/backend-api/codex/responses", headers: [:], body: body)
        guard case .openCode(let routed) = try ClaudeBridge.route(req, claudeEnabled: false) else { return XCTFail("Wrong provider") }
        XCTAssertEqual(routed.body, body)
        let unknown = RelayRequest(method: "POST", target: req.target, headers: ["content-encoding": "br"], body: body)
        XCTAssertThrowsError(try ClaudeBridge.route(unknown, claudeEnabled: false, openCodeEnabled: true))
    }

    func testCatalogPreservesGPTAndClaudeAndDoesNotDuplicateDeepSeek() throws {
        let initial = ClaudeBridge.encode(["models": [["slug": "gpt-6.1-sol", "priority": 1]]])
        let claude = try XCTUnwrap(ClaudeBridge.addingCatalogItems(to: initial, models: [.fallback]))
        let updated = try XCTUnwrap(OpenCodeGo.addingCatalogItem(to: claude))
        XCTAssertNil(OpenCodeGo.addingCatalogItem(to: updated))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["slug"] as? String }, ["gpt-6.1-sol", ClaudeModel.fallback.slug, OpenCodeGo.model])
        XCTAssertEqual(models.last?["tool_mode"] as? String, "standard")
        XCTAssertEqual(models.last?["supports_search_tool"] as? Bool, false)
    }

    @MainActor func testKeyPersistenceAndFailuresKeepThePreviousState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = GoTestVault()
        let index = root.appendingPathComponent("accounts.json")
        let store = AccountStore(index: index, session: CodexSession(home: root), vault: vault)
        XCTAssertFalse(store.openCodeConfigured)
        XCTAssertTrue(store.saveOpenCodeKey("go-key"))
        XCTAssertEqual(vault.values[OpenCodeGo.vaultID], Data("go-key".utf8))
        XCTAssertTrue(AccountStore(index: index, session: CodexSession(home: root), vault: vault).openCodeConfigured)
        vault.fail = true
        XCTAssertFalse(store.saveOpenCodeKey("replacement"))
        XCTAssertFalse(store.removeOpenCodeKey())
        XCTAssertTrue(store.openCodeConfigured)
        XCTAssertEqual(vault.values[OpenCodeGo.vaultID], Data("go-key".utf8))
        vault.fail = false
        XCTAssertTrue(store.removeOpenCodeKey())
        XCTAssertFalse(store.openCodeConfigured)
        XCTAssertNil(vault.values[OpenCodeGo.vaultID])
    }

    @MainActor func testRelayStreamsGoAndNeverFallsBackToGPTOnGoQuotaError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        let claims = Data(#"{"sub":"desktop"}"#.utf8).base64EncodedString()
        let credential = try Credential(data: ClaudeBridge.encode(["auth_mode": "chatgpt", "tokens": [
            "account_id": "desktop", "access_token": "desktop-secret", "refresh_token": "test-refresh", "id_token": "header.\(claims).signature"]]))
        try credential.data.write(to: auth)
        let server = GoTestServer()
        let upstreamPort = try await server.start()
        defer { server.stop() }
        let go = OpenCodeGo(baseURL: URL(string: "http://127.0.0.1:\(upstreamPort)/v1")!)
        go.setKey("go-test-key")
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)/gpt")!, openCode: go)
        relay.select(try RelayCredentials(credential))
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        var call = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        call.httpMethod = "POST"
        call.httpBody = request().body
        call.setValue("Bearer desktop-secret", forHTTPHeaderField: "Authorization")
        call.setValue("stable-session", forHTTPHeaderField: "session_id")
        let (data, response) = try await client.data(for: call)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let stream = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(stream.contains("response.completed"))
        // DeepSeek's chain of thought never reaches a client that renders reasoning_text as the answer.
        XCTAssertFalse(stream.contains("secret thinking"), stream)
        XCTAssertTrue(stream.contains(#""delta":"4""#), stream)
        XCTAssertTrue(stream.contains(#""text":"4""#), stream)
        go.setKey("exhausted-key")
        let (_, limited) = try await client.data(for: call)
        XCTAssertEqual((limited as? HTTPURLResponse)?.statusCode, 429)
        call.setValue("Bearer unauthorized", forHTTPHeaderField: "Authorization")
        let (_, denied) = try await client.data(for: call)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(server.headers.count, 2)
        XCTAssertTrue(server.headers.allSatisfy { $0.hasPrefix("POST /v1/responses ") && !$0.contains("desktop-secret") })
        XCTAssertEqual(relay.router.selected?.accessToken, "desktop-secret")
    }
}

@MainActor private final class GoTestVault: CredentialVault {
    var values: [String: Data] = [:]
    var fail = false
    func save(_ data: Data, id: String) throws { if fail { throw HTTPFailure(status: 500) }; values[id] = data }
    func read(_ id: String) throws -> Data { guard let value = values[id] else { throw HTTPFailure(status: 404) }; return value }
    func remove(_ id: String) throws { if fail { throw HTTPFailure(status: 500) }; values[id] = nil }
}

private final class GoTestServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.go-upstream")
    private let lock = NSLock()
    private var captured: [String] = []
    private var listener: NWListener?
    var headers: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in connection.start(queue: queue); read(connection, data: Data()) }
        return await withCheckedContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener?.cancel() }
    private func read(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] next, _, complete, error in
            let data = data + (next ?? Data())
            guard let split = data.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { read(connection, data: data) }; return
            }
            let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
            lock.lock(); captured.append(head); lock.unlock()
            let limited = head.contains("Bearer exhausted-key")
            let events = [
                #"{"type":"response.reasoning_text.delta","delta":"secret thinking"}"#,
                #"{"type":"response.reasoning_text.done","text":"secret thinking"}"#,
                #"{"type":"response.content_part.done","part":{"type":"reasoning_text","text":"secret thinking"}}"#,
                #"{"type":"response.output_item.done","item":{"type":"reasoning","content":[{"type":"reasoning_text","text":"secret thinking"}]}}"#,
                #"{"type":"response.output_text.delta","delta":"4"}"#,
                #"{"type":"response.completed","response":{"model":"deepseek-v4.1-flash","output":[{"type":"reasoning","content":[{"type":"reasoning_text","text":"secret thinking"}]},{"type":"message","content":[{"type":"output_text","text":"4"}]}]}}"#,
            ]
            let body = limited ? #"{"error":{"type":"usage_limit_reached"}}"# : events.map { "data: " + $0 + "\n\n" }.joined()
            let response = "HTTP/1.1 \(limited ? 429 : 200) Test\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
