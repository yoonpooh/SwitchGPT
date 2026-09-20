import XCTest
import Network
@testable import SwitchGPT

@MainActor
final class JevRelayIntegrationTests: XCTestCase {
    func testRoutedRequestReachesUpstreamAndRecordsActualCompletion() async throws {
        try await exercise(reject: false, quota: false)
    }

    func testUnsupportedModelRetriesExactBaselineBeforeSendingResponse() async throws {
        try await exercise(reject: true, quota: false)
    }

    func testQuotaRetryKeepsRoutedBodyOnNextAccount() async throws {
        try await exercise(reject: false, quota: true)
    }

    func testZstdRequestIsClassifiedRewrittenAndForwardedUncompressed() async throws {
        try await exercise(reject: false, quota: false, compressed: true)
    }

    func testZstdUnsupportedModelRetriesExactCompressedBaseline() async throws {
        try await exercise(reject: true, quota: false, compressed: true)
    }

    private func exercise(reject: Bool, quota: Bool, compressed: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = root.appendingPathComponent("auth.json")
        let desktop = try credential("desktop")
        try desktop.data.write(to: auth)
        let upstream = JevRelayServer(rejectRoutedModel: reject, quotaAccount: quota ? "first" : nil)
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let recorder = JevRelayRecorder()
        let engine = IntelligentModelRouter(classifier: { _, _ in
            recorder.classified()
            return JevRoutingAnswer(preset: "luna_max", confidence: 0.99)
        })
        engine.update(enabled: true, apiKey: "fixture-key")
        let accounts = try ["first", "second"].map { try RelayCredentials(credential($0)) }
        let accountRouter = AccountRouter()
        accountRouter.select(accounts[0])
        accountRouter.update(accounts.map {
            RoutingCandidate(credentials: $0, availability: .available, observedAt: .now)
        }, automatic: true)
        let relay = ModelRelay(desktopAuth: auth,
            upstreamBaseURL: URL(string: "http://127.0.0.1:\(upstreamPort)")!,
            router: accountRouter, intelligentRouter: engine,
            didRecord: { recorder.record($0) })
        let port = try await relay.start(port: 0)
        defer { relay.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        var baseline = try request(port: port)
        if compressed {
            baseline.httpBody = try zstdFixture(try XCTUnwrap(baseline.httpBody))
            baseline.setValue("zstd", forHTTPHeaderField: "Content-Encoding")
        }
        let (data, response) = try await client.data(for: baseline)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("response.completed"))
        XCTAssertEqual(recorder.classifications, 1)
        let calls = upstream.requests
        XCTAssertEqual(calls.count, reject || quota ? 2 : 1)
        let routed = try XCTUnwrap(try JSONSerialization.jsonObject(with: calls[0].body) as? [String: Any])
        XCTAssertEqual(routed["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual((routed["reasoning"] as? [String: Any])?["effort"] as? String, "max")
        XCTAssertNil(calls[0].headers["content-encoding"])
        if reject {
            XCTAssertEqual(calls[1].body, baseline.httpBody)
            XCTAssertEqual(calls[1].headers["content-encoding"], compressed ? "zstd" : nil)
        }
        if quota {
            XCTAssertEqual(calls[0].body, calls[1].body)
            XCTAssertEqual(calls[1].headers["authorization"], "Bearer second-token")
        }
        let completed = try XCTUnwrap(recorder.events.last { $0.completed })
        XCTAssertEqual(completed.model, reject ? "gpt-6-astra" : "gpt-5.6-luna")
        XCTAssertEqual(completed.modelRouting?.changed, !reject)
        if reject { XCTAssertEqual(completed.modelRouting?.reason, "upstream_unsupported") }
        XCTAssertEqual(try Data(contentsOf: auth), desktop.data)

        let (unauthorizedBody, unauthorizedResponse) = try await client.data(for: request(port: port, token: "unknown"))
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertTrue(unauthorizedBody.isEmpty)
        XCTAssertEqual(recorder.classifications, 1)
        XCTAssertEqual(upstream.requests.count, calls.count)
        if reject {
            var continuation = baseline
            let originalBody = try XCTUnwrap(compressed ? ZstdRequestBody.decode(baseline.httpBody!) : baseline.httpBody)
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: originalBody) as? [String: Any])
            var input = try XCTUnwrap(object["input"] as? [[String: Any]])
            input.append(["type": "function_call_output", "call_id": "fixture-call", "output": "done"])
            object["input"] = input
            let nextBody = try JSONSerialization.data(withJSONObject: object)
            continuation.httpBody = compressed ? try zstdFixture(nextBody) : nextBody
            let (_, continuationResponse) = try await client.data(for: continuation)
            XCTAssertEqual((continuationResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(upstream.requests.count, calls.count + 1)
            XCTAssertEqual(upstream.requests.last?.body, continuation.httpBody)
            XCTAssertEqual(recorder.classifications, 1)
        }
    }

    private func credential(_ name: String) throws -> Credential {
        let claims = Data("{\"sub\":\"\(name)\"}".utf8).base64EncodedString()
        return try Credential(data: Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"\(name)\",\"access_token\":\"\(name)-token\",\"refresh_token\":\"fixture\",\"id_token\":\"header.\(claims).signature\"}}".utf8))
    }

    private func request(port: UInt16, token: String = "desktop-token") throws -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-6-astra", "reasoning": ["effort": "medium"],
            "input": [["role": "user", "content": [["type": "input_text", "text": "Change the specified button label and verify the UI."]]]],
            "stream": true
        ])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("codex_desktop", forHTTPHeaderField: "originator")
        request.setValue("fixture-thread", forHTTPHeaderField: "thread-id")
        request.setValue("{\"thread_id\":\"fixture-thread\",\"turn_id\":\"fixture-turn\",\"request_kind\":\"turn\"}", forHTTPHeaderField: "x-codex-turn-metadata")
        return request
    }
}

private final class JevRelayServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "switchgpt.jev-test-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var captured: [RelayRequest] = []
    let rejectRoutedModel: Bool
    let quotaAccount: String?
    init(rejectRoutedModel: Bool = false, quotaAccount: String? = nil) {
        self.rejectRoutedModel = rejectRoutedModel
        self.quotaAccount = quotaAccount
    }
    var requests: [RelayRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            read(connection, previous: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener?.cancel() }
    private func read(_ connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            var buffer = previous
            buffer.append(data ?? Data())
            guard let request = try? RelayRequest.parse(buffer) else {
                if complete || error != nil { connection.cancel() }
                else { read(connection, previous: buffer) }
                return
            }
            lock.lock(); captured.append(request); lock.unlock()
            let decoded = request.headers["content-encoding"] == "zstd" ? ZstdRequestBody.decode(request.body) : request.body
            let object = decoded.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let model = object?["model"] as? String ?? "unknown"
            let status: Int
            let body: String
            if let quotaAccount, request.headers["authorization"] == "Bearer \(quotaAccount)-token" {
                status = 429
                body = "{\"error\":{\"type\":\"usage_limit_reached\"}}"
            } else if rejectRoutedModel && model == "gpt-5.6-luna" {
                status = 400
                body = "{\"error\":{\"code\":\"model_not_found\",\"param\":\"model\"}}"
            } else {
                status = 200
                body = "data: {\"type\":\"response.completed\",\"response\":{\"model\":\"\(model)\",\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}}\n\n"
            }
            let response = "HTTP/1.1 \(status) Response\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class JevRelayRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RelayEvent] = []
    private var count = 0
    func record(_ event: RelayEvent) { lock.lock(); defer { lock.unlock() }; values.append(event) }
    func classified() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var events: [RelayEvent] { lock.lock(); defer { lock.unlock() }; return values }
    var classifications: Int { lock.lock(); defer { lock.unlock() }; return count }
}
