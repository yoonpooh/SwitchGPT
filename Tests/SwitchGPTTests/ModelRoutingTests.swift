import XCTest
import Network
@testable import SwitchGPT

final class ModelRoutingTests: XCTestCase {
    func testConfigurationPreservesExistingSettingsAndIsIdempotent() throws {
        let original = "# User settings\nmodel = \"gpt-6-astra\"\n[projects.\"/repo\"]\ntrust_level = \"trusted\"\n"
        let endpoint = "http://127.0.0.1:19565/backend-api/codex"
        let updated = try RoutingConfiguration.addRouting(to: original, endpoint: endpoint)
        XCTAssertTrue(updated.hasSuffix(original))
        XCTAssertEqual(try RoutingConfiguration.addRouting(to: updated, endpoint: endpoint), updated)
        XCTAssertThrowsError(try RoutingConfiguration.addRouting(to: "openai_base_url = \"https://existing.example\"\n" + original, endpoint: endpoint))
        XCTAssertThrowsError(try RoutingConfiguration.addRouting(to: "'openai_base_url' = 'https://existing.example'\n", endpoint: endpoint))
    }

    func testRollbackRemovesOnlyOurBlockAndPreservesLaterEdits() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.toml")
        let original = "model = \"gpt-6-astra\"\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let config = RoutingConfiguration(home: root)
        XCTAssertTrue(try config.install())
        XCTAssertFalse(try config.install())
        let updated = try String(contentsOf: file, encoding: .utf8) + "# Another task's edit\n"
        try updated.write(to: file, atomically: true, encoding: .utf8)
        try config.removeInstalledBlock()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original + "# Another task's edit\n")
    }

    func testRequestRejectsCrossOriginAndAmbiguousFraming() throws {
        for request in [
            "POST /backend-api/codex/responses HTTP/1.1\r\nOrigin: https://example.com\r\n\r\n",
            "POST /backend-api/codex/responses HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 4\r\n\r\n",
            "POST /backend-api/codex/responses HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
            "GET /backend-api/codex/%2e%2e/other HTTP/1.1\r\n\r\n",
            "GET https://other.example/backend-api/codex/models HTTP/1.1\r\n\r\n"
        ] { XCTAssertThrowsError(try RelayRequest.parse(Data(request.utf8))) }
        XCTAssertNil(try RelayRequest.parse(Data("POST /backend-api/codex/responses HTTP/1.1\r\nContent-Length: 4\r\n\r\n12".utf8)))
    }

    @MainActor func testAccountSwitchAppliesToNextRequestWithoutChangingDesktopAuth() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = try credential("desktop")
        let auth = root.appendingPathComponent("auth.json")
        try desktop.data.write(to: auth)
        let upstream = StubModelServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!)
        relay.select(try RelayCredentials(credential("first")))
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func request() -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{\"model\":\"gpt-6-astra\"}".utf8)
            request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")
            request.setValue("desktop-account", forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("Bearer desktop-actor", forHTTPHeaderField: "x-openai-actor-authorization")
            return request
        }
        let firstRequest = request()
        async let first = session.data(for: firstRequest)
        for _ in 0..<100 {
            if upstream.requests.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(upstream.requests.count, 1)
        relay.select(try RelayCredentials(credential("second")))
        let (secondBody, secondResponse) = try await session.data(for: request())
        let (firstBody, firstResponse) = try await first
        XCTAssertEqual((firstResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: firstBody, as: UTF8.self).contains("response.completed"))
        // A quota error is returned from the chosen account, without falling back to desktop auth.
        XCTAssertEqual((secondResponse as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertEqual(String(decoding: secondBody, as: UTF8.self), "quota exhausted")
        let calls = upstream.requests
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map { $0.headers["authorization"] }, ["Bearer first-token", "Bearer second-token"])
        XCTAssertEqual(calls.map { $0.headers["chatgpt-account-id"] }, ["first-account", "second-account"])
        XCTAssertTrue(calls.allSatisfy { $0.headers["x-openai-actor-authorization"] == nil })
        XCTAssertEqual(try Data(contentsOf: auth), desktop.data)
        var unauthorized = request()
        unauthorized.setValue("Bearer unknown", forHTTPHeaderField: "Authorization")
        let (_, unauthorizedResponse) = try await session.data(for: unauthorized)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(upstream.requests.count, 2)
    }

    @MainActor func testHardQuotaRetriesSameRequestOnAvailableAccountBeforeReturningResponse() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = try credential("desktop")
        let auth = root.appendingPathComponent("auth.json")
        try desktop.data.write(to: auth)
        let upstream = StubModelServer(limitedBody: "{\"error\":{\"type\":\"usage_limit_reached\"}}")
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let first = try RelayCredentials(credential("first")), second = try RelayCredentials(credential("second"))
        let router = AccountRouter()
        router.select(second)
        router.update([second, first].map { RoutingCandidate(credentials: $0, availability: .available, observedAt: .now) }, automatic: true)
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!, router: router)
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"model\":\"gpt-6-astra\",\"input\":\"same request\"}".utf8)
        request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")
        request.setValue("codex_desktop", forHTTPHeaderField: "originator")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("response.completed"))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("usage_limit_reached"))
        XCTAssertEqual(upstream.requests.map { $0.headers["authorization"] }, ["Bearer second-token", "Bearer first-token"])
        XCTAssertTrue(upstream.requests.allSatisfy { $0.body == request.httpBody })
        XCTAssertEqual(router.selected?.fingerprint, first.fingerprint)
        XCTAssertEqual(try Data(contentsOf: auth), desktop.data)
        XCTAssertEqual(RelayEvent.client(for: try XCTUnwrap(upstream.requests.first)), "desktop")
    }

    @MainActor func testTemporaryRateLimitAndAuthenticationErrorsNeverRotateWithAutomaticEnabled() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        try credential("desktop").data.write(to: auth)
        for (status, errorType) in [(429, "rate_limit_exceeded"), (401, "invalid_token")] {
            let expected = "{\"error\":{\"type\":\"\(errorType)\"}}"
            let upstream = StubModelServer(limitedBody: expected, limitedStatus: status)
            let upstreamPort = try await upstream.start()
            let first = try RelayCredentials(credential("first")), second = try RelayCredentials(credential("second"))
            let router = AccountRouter()
            router.select(second)
            router.update([second, first].map { RoutingCandidate(credentials: $0, availability: .available, observedAt: .now) }, automatic: true)
            let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!, router: router)
            let port = try await relay.start(port: 0)
            let session = URLSession(configuration: .ephemeral)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")
            let (body, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status)
            XCTAssertEqual(String(decoding: body, as: UTF8.self), expected)
            XCTAssertEqual(upstream.requests.count, 1)
            XCTAssertEqual(router.selected?.fingerprint, second.fingerprint)
            session.invalidateAndCancel()
            relay.stop()
            upstream.stop()
        }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func credential(_ name: String) throws -> Credential {
        let claims = Data("{\"sub\":\"\(name)-subject\"}".utf8).base64EncodedString()
        return try Credential(data: Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"\(name)-account\",\"access_token\":\"\(name)-token\",\"refresh_token\":\"fake-refresh\",\"id_token\":\"header.\(claims).signature\"}}".utf8))
    }
}

private final class StubModelServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "switchgpt.test.upstream")
    private let lock = NSLock()
    private var captured: [RelayRequest] = []
    private var listener: NWListener?
    private let limitedBody: String
    private let limitedStatus: Int
    init(limitedBody: String = "quota exhausted", limitedStatus: Int = 429) {
        self.limitedBody = limitedBody
        self.limitedStatus = limitedStatus
    }
    var requests: [RelayRequest] { lock.lock(); defer { lock.unlock() }; return captured }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }

    private func read(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
            var all = previous
            if let data { all.append(data) }
            guard let request = try? RelayRequest.parse(all) else { read(connection, previous: all); return }
            lock.lock(); captured.append(request); lock.unlock()
            let limited = request.headers["authorization"] == "Bearer second-token"
            let body = limited ? limitedBody : "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n"
            let response = "HTTP/1.1 \(limited ? limitedStatus : 200) Response\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            queue.asyncAfter(deadline: .now() + 0.1) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
