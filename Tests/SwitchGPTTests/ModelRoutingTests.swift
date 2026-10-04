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

    func testRequestKeepsHeaderAndBodyLimitsSeparateAndWaitsForCompleteBody() throws {
        let prefix = "POST /backend-api/codex/responses HTTP/1.1\r\nContent-Length: 3\r\nX-Padding: "
        let header = prefix + String(repeating: "A", count: RelayRequest.headerLimit - prefix.utf8.count)
        let incomplete = Data((header + "\r\n\r\nab").utf8)
        XCTAssertNil(try RelayRequest.parse(incomplete))
        XCTAssertEqual(try XCTUnwrap(RelayRequest.parse(incomplete + Data("c".utf8))).body, Data("abc".utf8))
        XCTAssertThrowsError(try RelayRequest.parse(Data((header + "A\r\n\r\nabc").utf8)))
        XCTAssertThrowsError(try RelayRequest.parse(Data(repeating: UInt8(ascii: "A"), count: RelayRequest.headerLimit + 1))) { error in
            XCTAssertEqual((error as? HTTPFailure)?.status, 431)
        }
        // A valid maximum-length declaration must wait for its body, without requiring a 256 MB allocation here.
        XCTAssertEqual(RelayRequest.bodyLimit, 256 * 1024 * 1024)
        let atLimit = "POST /backend-api/codex/responses HTTP/1.1\r\nContent-Length: \(RelayRequest.bodyLimit)\r\n\r\n"
        XCTAssertNil(try RelayRequest.parse(Data(atLimit.utf8)))
    }

    @MainActor func testCompactionRequestPastFormer64MiBLimitReachesUpstreamUnchanged() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        try credential("desktop").data.write(to: auth)
        let upstream = StubModelServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!)
        relay.select(try RelayCredentials(credential("first")))
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var body = Data(#"{"model":"gpt-6-astra","input":[{"role":"user","content":[{"type":"input_text","text":""#.utf8)
        body.append(Data(repeating: UInt8(ascii: "A"), count: 64 * 1024 * 1024 + 1))
        body.append(Data(#""}]},{"type":"compaction_trigger"}]}"#.utf8))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")

        let (responseBody, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: responseBody, as: UTF8.self).contains("response.completed"))
        let calls = upstream.requests
        XCTAssertEqual(calls.count, 1)
        let forwarded = try XCTUnwrap(calls.first)
        XCTAssertEqual(forwarded.body.count, body.count)
        XCTAssertEqual(forwarded.body, body)
        XCTAssertEqual(forwarded.headers["authorization"], "Bearer first-token")
    }

    @MainActor func testOversizeDeclaredBodyReturns413BeforeUploadOrUpstreamRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        try credential("desktop").data.write(to: auth)
        let upstream = StubModelServer()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!)
        relay.select(try RelayCredentials(credential("first")))
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        // Send only headers over a raw socket: URLSession would replace Content-Length with the actual body's size.
        let request = "POST /backend-api/codex/responses HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer desktop-token\r\nContent-Length: \(256 * 1024 * 1024 + 1)\r\n\r\n"
        let response = try await RawRelayExchange(port: port, request: Data(request.utf8)).response()
        let split = try XCTUnwrap(response.range(of: Data("\r\n\r\n".utf8)))
        XCTAssertTrue(String(decoding: response[..<split.lowerBound], as: UTF8.self).hasPrefix("HTTP/1.1 413 "))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response[split.upperBound...])) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "request_too_large")
        XCTAssertTrue(try XCTUnwrap(error["message"] as? String).contains("256 MB"))
        XCTAssertEqual(upstream.requests.count, 0)
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

    @MainActor func testPriorityRecoveryAppliesToNextRequestWhileOriginalStreamCompletes() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let desktop = try credential("desktop")
        let auth = root.appendingPathComponent("auth.json")
        try desktop.data.write(to: auth)
        let upstream = StubModelServer(pauseFirstResponse: true)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let first = try RelayCredentials(credential("first")), third = try RelayCredentials(credential("third"))
        let router = AccountRouter()
        router.select(third)
        router.update([
            RoutingCandidate(credentials: first, availability: .exhausted, observedAt: .now),
            RoutingCandidate(credentials: third, availability: .available, observedAt: .now)
        ], automatic: true)
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!, router: router)
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"model\":\"gpt-6-astra\"}".utf8)
        request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")
        let (stream, originalResponse) = try await session.bytes(for: request)
        var lines = stream.lines.makeAsyncIterator()
        let firstEvent = try await lines.next()
        XCTAssertTrue(try XCTUnwrap(firstEvent).contains("response.output_text.delta"))

        router.update([first, third].map { RoutingCandidate(credentials: $0, availability: .available, observedAt: .now) }, automatic: true)
        XCTAssertEqual(router.resolve()?.fingerprint, first.fingerprint)
        let (nextBody, nextResponse) = try await session.data(for: request)
        XCTAssertEqual((nextResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: nextBody, as: UTF8.self).contains("response.completed"))

        upstream.finishFirstResponse()
        var completed = false
        while let line = try await lines.next() {
            if line.contains("response.completed") { completed = true }
        }
        XCTAssertEqual((originalResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(completed)
        XCTAssertEqual(upstream.requests.map { $0.headers["authorization"] }, ["Bearer third-token", "Bearer first-token"])
        XCTAssertEqual(try Data(contentsOf: auth), desktop.data)
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
        let events = root.appendingPathComponent("events.jsonl")
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!, eventURL: events, router: router)
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
        let recorded = try String(contentsOf: events, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(RelayEvent.self, from: Data($0.utf8))
        }
        XCTAssertEqual(recorded.map(\.model), ["gpt-6-astra", "gpt-6-astra"])
        XCTAssertEqual(recorded.map(\.status), [429, 200])
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

    @MainActor func testMiniRequestIsForwardedUnchangedWithoutModelRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        try credential("desktop").data.write(to: auth)
        let upstream = StubModelServer(rejectLuna: true)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let relay = ModelRelay(desktopAuth: auth, upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!)
        relay.select(try RelayCredentials(credential("first")))
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"gpt-5.4-mini","reasoning":{"effort":"low"},"input":"Hello"}"#.utf8)
        request.setValue("Bearer desktop-token", forHTTPHeaderField: "Authorization")

        let (body, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("response.completed"))
        let calls = upstream.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].body, request.httpBody)
        XCTAssertEqual(calls[0].headers["authorization"], "Bearer first-token")
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
    private final class RequestBuffer: @unchecked Sendable {
        var data = Data()
    }
    private let queue = DispatchQueue(label: "switchgpt.test.upstream")
    private let lock = NSLock()
    private var captured: [RelayRequest] = []
    private var listener: NWListener?
    private let limitedBody: String
    private let limitedStatus: Int
    private let pauseFirstResponse: Bool
    private let rejectLuna: Bool
    private var resumeFirstResponse: (@Sendable () -> Void)?
    init(limitedBody: String = "quota exhausted", limitedStatus: Int = 429,
         pauseFirstResponse: Bool = false, rejectLuna: Bool = false) {
        self.limitedBody = limitedBody
        self.limitedStatus = limitedStatus
        self.pauseFirstResponse = pauseFirstResponse
        self.rejectLuna = rejectLuna
    }
    var requests: [RelayRequest] { lock.lock(); defer { lock.unlock() }; return captured }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection, buffer: RequestBuffer())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }

    func finishFirstResponse() {
        queue.async { [self] in
            resumeFirstResponse?()
            resumeFirstResponse = nil
        }
    }

    private func read(_ connection: NWConnection, buffer: RequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            if let data { buffer.data.append(data) }
            let request: RelayRequest
            do {
                guard let parsed = try RelayRequest.parse(buffer.data) else {
                    if complete || error != nil { connection.cancel() }
                    else { read(connection, buffer: buffer) }
                    return
                }
                request = parsed
            } catch {
                connection.cancel()
                return
            }
            lock.lock(); captured.append(request); let isFirst = captured.count == 1; lock.unlock()
            let limited = request.headers["authorization"] == "Bearer second-token"
            let model = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["model"] as? String
            let rejected = rejectLuna && model == "gpt-6-luna"
            let body = rejected ? #"{"error":{"code":"unsupported_model"}}"#
                : limited ? limitedBody : "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n"
            if pauseFirstResponse && isFirst && !limited {
                let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"still streaming\"}\n\n"
                let head = "HTTP/1.1 200 Response\r\nContent-Type: text/event-stream\r\nContent-Length: \(delta.utf8.count + body.utf8.count)\r\nConnection: close\r\n\r\n\(delta)"
                resumeFirstResponse = {
                    connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                return
            }
            let response = "HTTP/1.1 \(rejected ? 400 : limited ? limitedStatus : 200) Response\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            queue.asyncAfter(deadline: .now() + 0.1) {
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

/// A small raw HTTP client for testing a rejected body declaration without allocating or uploading that body.
private final class RawRelayExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let queue = DispatchQueue(label: "switchgpt.test.raw-relay")
    private var continuation: CheckedContinuation<Data, any Error>?
    private var data = Data()
    private var timeout: DispatchWorkItem?

    init(port: UInt16, request: Data) {
        self.connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.request = request
    }

    func response() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let timeout = DispatchWorkItem { [self] in
                finish(.failure(NSError(domain: "SwitchGPTTests.RawRelayExchange", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Relay did not reject the oversized declaration promptly"])))
            }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 5, execute: timeout)
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { [self] error in
                        if let error { finish(.failure(error)) }
                        else { receive() }
                    })
                case .failed(let error): finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] next, _, complete, error in
            if let next { data.append(next) }
            if let error { finish(.failure(error)) }
            else if complete { finish(.success(data)) }
            else { receive() }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
