import Foundation
import Network

struct RelayEvent: Codable, Sendable {
    var date = Date()
    let accountFingerprint: String
    let path: String
    var model: String?
    var status: Int = 0
    var completed = false
    var inputTokens: Int?
    var outputTokens: Int?
    var client: String?
    var finishedAt: Date?
    var quotaExhausted: Bool?
    var modelRouting: ModelRoutingDecision?

    static func client(for request: RelayRequest) -> String {
        let origin = (request.headers["originator"]?.lowercased() ?? "").replacingOccurrences(of: " ", with: "_")
        let agent = (request.headers["user-agent"]?.lowercased() ?? "").replacingOccurrences(of: " ", with: "_")
        if origin == "codex_desktop" || agent.contains("codex_desktop") { return "desktop" }
        if origin.contains("cli") || origin.contains("exec") { return "cli" }
        return "unknown"
    }
}

/// A loopback-only model relay. A request captures its account once; selecting another
/// account affects the next request and never rewrites desktop authentication.
final class ModelRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.switchgpt.model-relay")
    let router: AccountRouter
    private var listener: NWListener?
    private var connections: [UUID: RelayConnection] = [:]
    private let desktopAuth: URL
    private let initialDesktopToken: String?
    private let upstreamBaseURL: URL
    private let eventURL: URL?
    private let didRecord: @Sendable (RelayEvent) -> Void

    init(desktopAuth: URL, upstreamBaseURL: URL = URL(string: "https://chatgpt.com")!, eventURL: URL? = nil,
         router: AccountRouter = AccountRouter(),
         didRecord: @escaping @Sendable (RelayEvent) -> Void = { _ in }) {
        self.desktopAuth = desktopAuth
        initialDesktopToken = Self.accessToken(at: desktopAuth)
        self.upstreamBaseURL = upstreamBaseURL
        self.eventURL = eventURL
        self.router = router
        self.didRecord = didRecord
    }

    func select(_ credentials: RelayCredentials) {
        router.select(credentials)
    }

    private func credentials(for request: RelayRequest) throws -> RelayCredentials {
        guard let snapshot = router.selected, let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer ") else { throw HTTPFailure(status: 401) }
        let token = String(authorization.dropFirst(7))
        guard !token.isEmpty,
              token == initialDesktopToken || token == snapshot.accessToken || token == Self.accessToken(at: desktopAuth) else {
            throw HTTPFailure(status: 401)
        }
        guard request.isModelRequest else { return snapshot }
        guard let selected = router.resolve() else { throw HTTPFailure(status: 429) }
        return selected
    }

    private static func accessToken(at file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = value["tokens"] as? [String: Any] else { return nil }
        return tokens["access_token"] as? String
    }

    func start(port: UInt16 = RoutingConfiguration.port) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let existing = self.listener?.port { continuation.resume(returning: existing.rawValue); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    let startup = RelayStartup(continuation)
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        switch state {
                        case .ready:
                            if let port = listener?.port { startup.finish(.success(port.rawValue)) }
                        case .failed:
                            startup.finish(.failure(SwitchError(message: L10n.text("relay_start_failed"))))
                            self?.listener = nil
                            listener?.cancel()
                        case .cancelled:
                            startup.finish(.failure(SwitchError(message: L10n.text("relay_start_failed"))))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: SwitchError(message: L10n.text("relay_start_failed"))) }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in Array(self.connections.values) { connection.close() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let client = RelayConnection(connection: connection, queue: queue, upstreamBaseURL: upstreamBaseURL,
                                     credentials: { [weak self] request in
                                         guard let self else { throw HTTPFailure(status: 503) }
                                         return try self.credentials(for: request)
                                     },
                                     fallback: { [router] failed, tried in router.resolve(excluding: tried, exhausted: failed) },
                                     report: { [weak self] in self?.record($0) },
                                     onClose: { [weak self] in self?.connections.removeValue(forKey: id) })
        connections[id] = client
        client.start()
    }

    private func record(_ event: RelayEvent) {
        didRecord(event)
        guard let file = eventURL, var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0a)
        // Only model, opaque account fingerprint, status, and usage counts; never prompts or tokens.
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        if let size = try? handle.seekToEnd(), size > 262_144 { try? handle.truncate(atOffset: 0); try? handle.seek(toOffset: 0) }
        try? handle.write(contentsOf: data)
    }
}

private final class RelayStartup: @unchecked Sendable {
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

private final class RelayConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let upstreamBaseURL: URL
    private let credentials: @Sendable (RelayRequest) throws -> RelayCredentials
    private let fallback: @Sendable (RelayCredentials, Set<String>) -> RelayCredentials?
    private let report: @Sendable (RelayEvent) -> Void
    private let onClose: @Sendable () -> Void
    private var buffer = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var closed = false
    private var responseStarted = false
    private var event: RelayEvent?
    private var eventLine = Data()
    private var timeout: DispatchWorkItem?
    private var originalRequest: RelayRequest?
    private var baselineRequest: RelayRequest?
    private var modelRouting: ModelRoutingDecision?
    private var usedModelFallback = false
    private var selected: RelayCredentials?
    private var attempted: Set<String> = []
    private var deferredResponse: HTTPURLResponse?
    private var deferredBody = Data()

    init(connection: NWConnection, queue: DispatchQueue, upstreamBaseURL: URL,
         credentials: @escaping @Sendable (RelayRequest) throws -> RelayCredentials,
         fallback: @escaping @Sendable (RelayCredentials, Set<String>) -> RelayCredentials?,
         report: @escaping @Sendable (RelayEvent) -> Void,
         onClose: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.queue = queue
        self.upstreamBaseURL = upstreamBaseURL
        self.credentials = credentials
        self.fallback = fallback
        self.report = report
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.fail(408) }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            do {
                guard self.buffer.count <= RelayRequest.bodyLimit + RelayRequest.headerLimit else { throw HTTPFailure(status: 413) }
                if let request = try RelayRequest.parse(self.buffer) {
                    self.timeout?.cancel()
                    self.buffer.removeAll()
                    self.forward(request)
                } else if complete || error != nil { self.close() }
                else { self.receive() }
            } catch let failure as HTTPFailure { self.fail(failure.status) }
            catch { self.fail(400) }
        }
    }

    private func forward(_ request: RelayRequest) {
        do {
            let selected = try credentials(request)
            // Codex explicitly falls back to HTTP/SSE on 426. This avoids a WebSocket
            // retaining the old account across turns after the user selects a new one.
            if request.headers["upgrade"]?.lowercased() == "websocket" { fail(426); return }
            baselineRequest = request
            let routed = MiniModelRouter.route(request)
            originalRequest = routed.request
            modelRouting = routed.decision
            startAttempt(routed.request, selected: selected)
        } catch let failure as HTTPFailure { fail(failure.status) }
        catch { fail(400) }
    }

    private func startAttempt(_ request: RelayRequest, selected: RelayCredentials) {
        do {
            self.selected = selected
            attempted.insert(selected.fingerprint)
            responseStarted = false
            deferredResponse = nil
            deferredBody.removeAll()
            eventLine.removeAll()
            let upstream = try request.upstreamRequest(baseURL: upstreamBaseURL, credentials: selected)
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            event = RelayEvent(accountFingerprint: selected.fingerprint,
                               path: request.target.components(separatedBy: "?")[0], model: body?["model"] as? String,
                               client: RelayEvent.client(for: request))
            event?.modelRouting = modelRouting
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 3600
            let delegateQueue = OperationQueue()
            delegateQueue.maxConcurrentOperationCount = 1
            delegateQueue.underlyingQueue = queue
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            self.session = session
            let task = session.dataTask(with: upstream)
            self.task = task
            task.resume()
        } catch { fail(400) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !closed, let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        event?.status = response.statusCode
        if originalRequest?.isModelRequest == true && (response.statusCode == 429 ||
            (modelRouting?.changed == true && !usedModelFallback && [400, 403, 404, 422].contains(response.statusCode))) {
            // Hold retryable error responses before any bytes reach Codex. Successful streams are never replayed.
            deferredResponse = response
        } else { sendHead(response) }
        completionHandler(.allow)
    }

    private func sendHead(_ response: HTTPURLResponse) {
        responseStarted = true
        var head = "HTTP/1.1 \(response.statusCode) Response\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n"
        for (rawName, rawValue) in response.allHeaderFields {
            guard let name = rawName as? String, let value = rawValue as? String,
                  !["content-length", "transfer-encoding", "connection", "content-encoding", "set-cookie"].contains(name.lowercased()),
                  !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else { continue }
            head += "\(name): \(value)\r\n"
        }
        send(Data((head + "\r\n").utf8))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !closed else { return }
        if let response = deferredResponse {
            deferredBody.append(data)
            if deferredBody.count > 65_536 {
                deferredResponse = nil
                sendHead(response)
                sendChunk(deferredBody)
                deferredBody.removeAll()
            }
            return
        }
        inspectEvents(data)
        sendChunk(data)
    }

    private func sendChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8))
        chunk.append(data)
        chunk.append(Data("\r\n".utf8))
        send(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !closed else { return }
        event?.finishedAt = .now
        if let response = deferredResponse {
            if error == nil, [400, 403, 404, 422].contains(response.statusCode),
               !usedModelFallback, modelRouting?.changed == true,
               Self.isUnsupportedRoute(deferredBody), let selected, let baseline = baselineRequest {
                if let event { report(event) }
                event = nil
                usedModelFallback = true
                if let decision = modelRouting {
                    modelRouting = ModelRoutingDecision(originalModel: decision.originalModel,
                        originalEffort: decision.originalEffort, selectedModel: decision.originalModel,
                        selectedEffort: decision.originalEffort, reason: "upstream_unsupported")
                }
                originalRequest = baseline
                session.finishTasksAndInvalidate()
                startAttempt(baseline, selected: selected)
                return
            }
            if error == nil, response.statusCode == 429, QuotaFailure.isExhausted(deferredBody), let selected, let request = originalRequest {
                event?.quotaExhausted = true
                if let event { report(event) }
                event = nil
                if let next = fallback(selected, attempted) {
                    session.finishTasksAndInvalidate()
                    startAttempt(request, selected: next)
                    return
                }
            }
            sendHead(response)
            sendChunk(deferredBody)
            deferredBody.removeAll()
            deferredResponse = nil
        }
        if let event { report(event) }
        if !responseStarted { fail(502) }
        else if error != nil { close() } // A truncated upstream response must stay truncated.
        else { send(Data("0\r\n\r\n".utf8), final: true) }
    }

    private func inspectEvents(_ data: Data) {
        eventLine.append(data)
        while let end = eventLine.firstIndex(of: 0x0a) {
            let line = Data(eventLine[..<end])
            eventLine.removeSubrange(...end)
            guard line.starts(with: Data("data: ".utf8)),
                  let value = try? JSONSerialization.jsonObject(with: line.dropFirst(6)) as? [String: Any],
                  value["type"] as? String == "response.completed",
                  let response = value["response"] as? [String: Any] else { continue }
            event?.completed = true
            if let model = response["model"] as? String { event?.model = model }
            if let usage = response["usage"] as? [String: Any] {
                event?.inputTokens = usage["input_tokens"] as? Int
                event?.outputTokens = usage["output_tokens"] as? Int
            }
        }
        if eventLine.count > 4 * 1024 * 1024 { eventLine.removeAll() }
    }

    /// Retry only an explicit capability rejection, before forwarding any response bytes.
    /// Authentication, quota, transport failures, and already-started streams are never replayed here.
    static func isUnsupportedRoute(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = value["error"] as? [String: Any] else { return false }
        let code = error["code"] as? String ?? error["type"] as? String ?? ""
        if ["model_not_found", "model_not_available", "unsupported_model"].contains(code) { return true }
        let parameter = error["param"] as? String ?? ""
        let capabilityError = ["unsupported_value", "invalid_value", "unsupported_parameter", "invalid_request_error"].contains(code)
        return parameter == "model" && capabilityError
    }

    private func fail(_ status: Int) {
        guard !closed else { return }
        let body = status == 429 ? "{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"SwitchGPT: no account with confirmed remaining quota is available.\"}}" : ""
        send(Data("HTTP/1.1 \(status) SwitchGPT\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8), final: true)
    }

    private func send(_ data: Data, final: Bool = false) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if final || error != nil { self?.close() }
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        connection.cancel()
        onClose()
    }
}
