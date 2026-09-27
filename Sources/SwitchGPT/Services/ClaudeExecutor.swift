import Foundation

/// One HTTP exchange handed to Claude: an SSE response to Codex or a JSON reply to the MCP relay.
protocol ClaudeSink: AnyObject, Sendable {
    func beginEventStream()
    func write(_ data: Data)
    func finish()
    func respond(status: Int, json: Data)
    func observeClose(_ handler: @escaping @Sendable () -> Void)
}

/// Runs Claude models through the Claude Code CLI signed in on this Mac while Codex executes every tool except web search.
/// Claude's private MCP relay parks it at a tool boundary; that call becomes a real Codex tool call,
/// and the next Codex request returns the result to the same Claude process.
final class ClaudeExecutor: @unchecked Sendable {
    let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    private let queue = DispatchQueue(label: "local.switchgpt.claude-executor")
    private let lock = NSLock()
    private var isEnabled = false
    private var port: UInt16 = 0
    let models: ClaudeModelCatalog
    private let claudeExecutable: @Sendable () -> URL?
    private let relayExecutable: URL?
    private let stallLimit: TimeInterval
    private let startLimit: TimeInterval
    private var timer: DispatchSourceTimer?
    // Confined to queue.
    private var runs: [String: ClaudeRun] = [:]
    private var runsByID: [String: ClaudeRun] = [:]
    /// Completed responses by request fingerprint. A paused one (a tool call) is valid only while its run lives.
    private var cache: [(key: String, date: Date, wire: Data, run: String, paused: Bool)] = []

    /// stallLimit: how long an open response may wait without any Claude Code output.
    /// startLimit: how long a new Claude Code process may take to report that it started.
    init(claudeExecutable: @escaping @Sendable () -> URL? = { ClaudeCLI.locate() }, models: ClaudeModelCatalog = ClaudeModelCatalog(),
         relayExecutable: URL? = Bundle.main.executableURL, stallLimit: TimeInterval = 1200, startLimit: TimeInterval = 90) {
        self.claudeExecutable = claudeExecutable
        self.models = models
        self.relayExecutable = relayExecutable
        self.stallLimit = stallLimit
        self.startLimit = startLimit
        // A Claude process that already exited must not terminate SwitchGPT on a pipe write.
        signal(SIGPIPE, SIG_IGN)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    var enabled: Bool { lock.withLock { isEnabled } }
    func setEnabled(_ enabled: Bool) {
        lock.withLock { isEnabled = enabled }
        if enabled { models.refresh() }
        // Nothing may keep running or wait for a tool result once Claude is turned off.
        else { stop(reason: "Claude models were turned off in SwitchGPT") }
    }
    var relayPort: UInt16 {
        get { lock.withLock { port } }
        set { lock.withLock { port = newValue } }
    }

    func stop(reason: String = "SwitchGPT stopped") {
        queue.async { [self] in
            for run in allRuns() {
                cancel(run, reason)
                forget(run)
            }
        }
    }

    /// Called while SwitchGPT quits: no Claude Code process may outlive the app.
    func shutdown() {
        let processes: [Process] = queue.sync {
            let all = allRuns()
            let processes = all.compactMap(\.process)
            for run in all {
                cancel(run, "SwitchGPT quit")
                forget(run)
            }
            return processes
        }
        let deadline = Date().addingTimeInterval(2)
        while processes.contains(where: \.isRunning), Date() < deadline { usleep(50_000) }
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    // MARK: Codex requests

    func respond(to request: RelayRequest, sink: ClaudeSink) {
        queue.async { [self] in
            do { try begin(request, sink: sink) }
            catch let failure as ClaudeFailure { sink.respond(status: failure.status, json: ClaudeBridge.errorBody(failure.message)) }
            catch { sink.respond(status: 400, json: ClaudeBridge.errorBody("Invalid request")) }
        }
    }

    private func begin(_ request: RelayRequest, sink: ClaudeSink) throws {
        guard let data = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            throw ClaudeFailure(status: 400, message: "Invalid JSON request")
        }
        guard let slug = data["model"] as? String, ClaudeModel.isClaude(slug) else { throw ClaudeFailure(status: 400, message: "Unsupported model") }
        guard let model = models.model(for: slug) else { throw ClaudeFailure(status: 400, message: ClaudeBridge.unavailableMessage(slug)) }
        // A model without an effort setting ignores the one Codex sends.
        guard model.efforts.isEmpty || model.efforts.contains(ClaudeBridge.effort(data)) else {
            throw ClaudeFailure(status: 400, message: "Unsupported effort")
        }
        let metadata = request.headers["x-codex-turn-metadata"]
            .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        // The thread comes first: a forked thread such as /side keeps its parent's prompt_cache_key and session-id,
        // and must not reach (or end) the parent's Claude process.
        let candidates = [metadata?["thread_id"] as? String, request.headers["thread-id"], data["prompt_cache_key"] as? String,
                          request.headers["session-id"], request.headers["session_id"], metadata?["session_id"] as? String]
        guard let key = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw ClaudeFailure(status: 400, message: "Codex did not identify the conversation; send the message again")
        }
        let turnID = metadata?["turn_id"] as? String
        let fingerprint = ClaudeBridge.digest(["data": data, "turn_id": turnID ?? NSNull(), "key": key] as [String: Any])
        let inputs = data["input"] as? [Any] ?? [["role": "user", "content": data["input"] ?? ""] as [String: Any]]
        let last = inputs.last as? [String: Any]

        if let cached = cache.last(where: { $0.key == fingerprint }) {
            // Codex retried a response that already completed; replay it instead of running Claude again.
            sink.beginEventStream()
            sink.write(cached.wire)
            sink.finish()
            return
        }
        var run = runs[key]
        if last?["type"] as? String == "compaction_trigger" {
            // Codex replaces the history; the next request continues from the compaction item.
            if let run {
                cancel(run, "Codex compacted the conversation; continuing from the compacted history")
                forget(run)
            }
            compact(data, model: model, key: key, turnID: turnID, fingerprint: fingerprint, sink: sink)
            return
        }
        let results = Self.toolResults(inputs)
        let table = try ClaudeBridge.toolTable(data["tools"])
        if let current = run, current.writer == nil {
            let answered = !current.waiting.isEmpty && current.waiting.isSubset(of: results.keys)
            let changed = model != current.model || ClaudeBridge.effort(data) != current.effort
                || ClaudeBridge.digest(Self.roles(inputs)) != ClaudeBridge.digest(Self.roles(current.inputs))
                || ClaudeBridge.digest(data["instructions"]) != ClaudeBridge.digest(current.data["instructions"])
                || ClaudeBridge.tableDigest(table) != ClaudeBridge.tableDigest(current.table)
                || ClaudeBridge.webSearch(data["tools"]) != current.search
            if !answered || changed || (turnID != nil && current.turnID != nil && turnID != current.turnID) {
                // Codex moved on (new message, new turn, another model, changed context or tools): replay its complete,
                // authoritative history in a fresh CLI. Never smuggle a steering message inside a tool result.
                cancel(current, "Codex continued the conversation; continuing from complete Codex history")
                forget(current)
                run = nil
            }
        }
        let fresh = run == nil
        let active: ClaudeRun
        if let run { active = run } else {
            // A fresh process reads the whole history, including tool calls of an ended run and their results.
            active = ClaudeRun(key: key, turnID: turnID, model: model, data: data, inputs: inputs, table: table)
            runs[key] = active
            runsByID[active.id] = active
        }
        guard active.writer == nil else { throw ClaudeFailure(status: 409, message: "A model request is already running") }
        if !fresh {
            active.table = table
            active.inputs = inputs
            // Execution has already happened in Codex. Forward its success or denial unchanged.
            for callID in active.waiting {
                active.calls[callID]?.resolve(["content": ClaudeBridge.resultContent(results[callID]?["output"] ?? "")])
            }
            active.waiting.removeAll()
        }
        attach(active, sink: sink, fingerprint: fingerprint)
        if fresh { launch(active) }
        pump(active)
    }

    /// One tool-less Claude call that turns the Codex history into a Codex compaction item.
    private func compact(_ data: [String: Any], model: ClaudeModel, key: String, turnID: String?, fingerprint: String, sink: ClaudeSink) {
        var request = data
        request["tools"] = [Any]()
        let run = ClaudeRun(key: key, turnID: turnID, model: model, data: request, inputs: request["input"] as? [Any] ?? [],
                            table: [:], compacting: true)
        runsByID[run.id] = run
        attach(run, sink: sink, fingerprint: fingerprint)
        launch(run)
        pump(run)
    }

    private func attach(_ run: ClaudeRun, sink: ClaudeSink, fingerprint: String) {
        let writer = ClaudeResponseWriter(sink: sink, fingerprint: fingerprint, model: run.model.slug)
        run.writer = writer
        run.touched = Date()
        run.output = Date()
        sink.observeClose { [weak self, weak run, weak writer] in
            guard let self, let run, let writer else { return }
            self.queue.async { self.disconnected(run, writer) }
        }
        sink.beginEventStream()
        writer.event("response.created", ["response": writer.response("in_progress")])
    }

    private func disconnected(_ run: ClaudeRun, _ writer: ClaudeResponseWriter) {
        guard run.writer === writer else { return }
        run.writer = nil
        cancel(run, "Codex cancelled or disconnected")
        forget(run)
    }

    // MARK: MCP relay

    func relay(_ request: RelayRequest, sink: ClaudeSink) {
        queue.async { [self] in
            guard Self.constantTimeEqual(request.headers["authorization"] ?? "", "Bearer " + token) else {
                sink.respond(status: 401, json: ClaudeBridge.errorBody("Local bridge authentication required"))
                return
            }
            guard let data = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
                sink.respond(status: 400, json: ClaudeBridge.errorBody("Invalid JSON request"))
                return
            }
            guard let runID = data["run_id"] as? String, let run = runsByID[runID] else {
                sink.respond(status: 404, json: ClaudeBridge.errorBody("Unknown Claude run"))
                return
            }
            let params = data["params"] as? [String: Any] ?? [:]
            switch data["method"] as? String {
            case "tools/list":
                var tools = run.table.keys.sorted().compactMap { run.table[$0]?.mcp }
                // Claude Code's plan mode runs only read-only tools. Codex Plan mode keeps every tool for exploration and
                // forbids mutations by instruction, as it does for GPT; Claude models reach everything through exec, so
                // without the hint Claude could not even read a file. Codex's sandbox and approvals still apply.
                if run.permissionMode == .plan { tools = tools.map { $0.merging(["annotations": ["readOnlyHint": true]]) { $1 } } }
                sink.respond(status: 200, json: ClaudeBridge.encode(["tools": tools]))
            case "tools/call":
                invoke(run, name: params["name"] as? String ?? "", arguments: params["arguments"] as? [String: Any] ?? [:], sink: sink)
            default:
                sink.respond(status: 400, json: ClaudeBridge.errorBody("Unsupported relay method"))
            }
        }
    }

    private func invoke(_ run: ClaudeRun, name: String, arguments: [String: Any], sink: ClaudeSink) {
        func refuse(_ reason: String) {
            sink.respond(status: 200, json: ClaudeBridge.encode(["content": [["type": "text", "text": reason]], "isError": true] as [String: Any]))
        }
        guard !run.cancelled else { refuse("Run cancelled"); return }
        guard let tool = run.table[name] else { refuse("Tool was not declared by Codex"); return }
        let callID = ClaudeBridge.callPrefix + ClaudeBridge.identifier()
        // OpenAI's own prefixes, so the history stays valid if the thread later switches to a GPT model.
        var item: [String: Any] = ["id": (tool.kind == "custom" ? "ctc_" : "fc_") + ClaudeBridge.identifier(),
                                   "call_id": callID, "name": tool.name, "status": "completed"]
        if let namespace = tool.namespace { item["namespace"] = namespace }
        if tool.kind == "custom" {
            guard let input = arguments["input"] as? String else { refuse("Custom tool requires a raw input string"); return }
            item["type"] = "custom_tool_call"
            item["input"] = input
        } else {
            item["type"] = "function_call"
            item["arguments"] = ClaudeBridge.text(arguments)
        }
        let pending = ClaudePending(callID: callID, item: item, sink: sink)
        run.calls[callID] = pending
        run.events.append(.call(pending))
        pump(run)
    }

    // MARK: Claude process

    private func launch(_ run: ClaudeRun) {
        do {
            guard let executable = claudeExecutable() else {
                throw ClaudeFailure(status: 503, message: "Claude Code CLI was not found on this Mac. Install Claude Code and sign in.")
            }
            guard run.table.isEmpty || relayExecutable != nil else {
                throw ClaudeFailure(status: 500, message: "SwitchGPT could not locate its executable for the Codex tool relay")
            }
            let prompt = ClaudeBridge.promptContent(run.data, compacting: run.compacting)
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("switchgpt-claude-" + run.id)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            run.scratch = scratch
            let config = scratch.appendingPathComponent("relay.json")
            let settings: [String: Any] = ["run_id": run.id, "token": token, "url": "http://127.0.0.1:\(relayPort)\(ClaudeBridge.relayPath)"]
            guard FileManager.default.createFile(atPath: config.path, contents: ClaudeBridge.encode(settings), attributes: [.posixPermissions: 0o600]) else {
                throw ClaudeFailure(status: 500, message: "Could not prepare the Codex tool relay")
            }
            let process = Process()
            process.executableURL = executable
            process.arguments = run.arguments(relay: relayExecutable, config: config)
            // Claude Code has no local tools of its own, so it never needs the Codex folder. Starting it there would make it
            // read a protected folder such as Documents, where macOS blocks it behind a permission prompt.
            process.currentDirectoryURL = scratch
            var environment = ClaudeCLI.environment(executable: executable)
            // Codex already truncates tool output; Claude Code's own 25,000-token MCP cap would cut screenshots and results again.
            if environment["MAX_MCP_OUTPUT_TOKENS"] == nil { environment["MAX_MCP_OUTPUT_TOKENS"] = "100000" }
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            // The end of stderr explains a CLI that never starts or exits early.
            errors.fileHandleForReading.readabilityHandler = { [weak self, weak run] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                guard let self, let run, !data.isEmpty else { return }
                self.queue.async { run.recordError(data) }
            }
            output.fileHandleForReading.readabilityHandler = { [weak self, weak run] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                guard let self, let run else { return }
                self.queue.async { self.consume(run, data) }
            }
            try process.run()
            run.process = process
            run.launched = Date()
            var line = ClaudeBridge.encode(["type": "user", "message": ["role": "user", "content": prompt]] as [String: Any])
            line.append(0x0a)
            let message = line
            let stdin = input.fileHandleForWriting
            // Large histories exceed the pipe buffer; never block the executor while Claude reads them.
            DispatchQueue.global().async { try? stdin.write(contentsOf: message) }
        } catch let failure as ClaudeFailure {
            cancel(run, failure.message)
        } catch {
            cancel(run, "Claude Code could not start: " + error.localizedDescription)
        }
    }

    private func consume(_ run: ClaudeRun, _ data: Data) {
        guard !data.isEmpty else { stdoutClosed(run); return }
        run.output = Date()
        run.buffer.append(data)
        while let newline = run.buffer.firstIndex(of: 0x0a) {
            let line = Data(run.buffer[run.buffer.startIndex..<newline])
            run.buffer.removeSubrange(run.buffer.startIndex...newline)
            guard !run.cancelled, !run.collected,
                  let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(run, event)
        }
    }

    private func handle(_ run: ClaudeRun, _ event: [String: Any]) {
        run.touched = Date()
        switch event["type"] as? String {
        case "system" where event["subtype"] as? String == "init":
            run.initialized = true
            if Set(event["tools"] as? [String] ?? []) != Set(run.allowedTools) {
                cancel(run, "Claude tool isolation failed: expected only Codex relay tools and WebSearch")
            }
        case "stream_event":
            guard let value = event["event"] as? [String: Any] else { return }
            run.events.append(.stream(value))
            pump(run)
        case "user" where run.search:
            // Claude Code ran a tool: the results of a WebSearch complete its card.
            let content = (event["message"] as? [String: Any])?["content"] as? [Any] ?? []
            for case let block as [String: Any] in content where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String { run.events.append(.toolResult(id, failed: block["is_error"] as? Bool == true)) }
            }
            pump(run)
        case "result":
            run.collected = true
            if event["is_error"] as? Bool == true {
                let result = event["result"] as? String
                let detail = (result?.isEmpty == false ? result : nil) ?? event["subtype"] as? String ?? "unknown error"
                if detail.lowercased().contains("prompt is too long") || detail.lowercased().contains("context window") {
                    run.failureCode = "context_length_exceeded"
                }
                cancel(run, "Claude Code failed: " + String(detail.prefix(300)))
            } else {
                run.events.append(.result(event))
                pump(run)
                stopProcess(run) // stream-json input otherwise keeps the CLI alive.
            }
        default: break
        }
    }

    private func stdoutClosed(_ run: ClaudeRun) {
        if !run.collected { cancel(run, "Claude Code exited without a result" + run.diagnostic) }
        stopProcess(run)
    }

    private func stopProcess(_ run: ClaudeRun) {
        if let process = run.process, process.isRunning {
            let pid = process.processIdentifier
            // Claude Code's children (the MCP relay) are ended with it; they must not outlive the run.
            for child in Self.descendants(of: pid) { kill(child, SIGTERM) }
            process.terminate()
            queue.asyncAfter(deadline: .now() + 5) { [run] in
                if run.process?.isRunning == true { kill(pid, SIGKILL) }
            }
        }
        if let scratch = run.scratch {
            try? FileManager.default.removeItem(at: scratch)
            run.scratch = nil
        }
    }

    private func cancel(_ run: ClaudeRun, _ reason: String) {
        guard !run.cancelled else { return }
        run.cancelled = true
        for pending in run.calls.values {
            pending.resolve(["content": [["type": "text", "text": reason]], "isError": true])
        }
        run.events.append(.error(reason))
        stopProcess(run)
        pump(run)
    }

    private func forget(_ run: ClaudeRun) {
        if runs[run.key] === run { runs[run.key] = nil }
        runsByID[run.id] = nil
        // A retried tool call of an ended run would hand Codex a call no Claude process can answer.
        cache.removeAll { $0.run == run.id && $0.paused }
        stopProcess(run)
    }

    private func allRuns() -> [ClaudeRun] {
        var seen = Set<String>()
        return (Array(runs.values) + Array(runsByID.values)).filter { seen.insert($0.id).inserted }
    }

    private func tick() {
        let now = Date()
        cache.removeAll { now.timeIntervalSince($0.date) >= 600 }
        for run in allRuns() {
            if let writer = run.writer {
                if let launched = run.launched, !run.initialized, now.timeIntervalSince(launched) > startLimit {
                    failResponse(run, writer, "Claude Code did not start within \(Int(startLimit)) seconds" + run.diagnostic
                                 + ". Check that Claude Code is signed in (run claude in Terminal), then send the message again.")
                } else if now.timeIntervalSince(run.output) > stallLimit {
                    failResponse(run, writer, "Claude Code stopped responding; send the message again to continue")
                } else { writer.sink.write(Data(": keepalive\n\n".utf8)) }
            } else if now.timeIntervalSince(run.touched) > 3600 {
                cancel(run, "Codex continuation idle for one hour; start a new message")
                forget(run)
            }
        }
    }

    // MARK: Response stream

    private func pump(_ run: ClaudeRun) {
        while let writer = run.writer, !run.events.isEmpty {
            let event = run.events.removeFirst()
            run.touched = Date()
            switch event {
            case .error(let message):
                failResponse(run, writer, message)
                return
            case .stream(let value):
                writer.trackUsage(value, run: run)
                guard !run.compacting else { continue }
                let index = ClaudeBridge.integer(value["index"])
                switch value["type"] as? String {
                case "content_block_start":
                    let block = value["content_block"] as? [String: Any]
                    switch block?["type"] as? String {
                    case "text": writer.startItem("message")
                    case "thinking": writer.startItem("reasoning")
                    case "tool_use":
                        writer.finishItem()
                        let name = block?["name"] as? String ?? ""
                        if name.hasPrefix("mcp__codex__") { run.codexCallInMessage = true }
                        if run.search, name == ClaudeBridge.searchTool, let id = block?["id"] as? String {
                            run.searches[index] = (id, "")
                        }
                    default: break
                    }
                case "content_block_delta":
                    guard let delta = value["delta"] as? [String: Any] else { break }
                    switch delta["type"] as? String {
                    case "text_delta": if let text = delta["text"] as? String { writer.delta(text) }
                    case "thinking_delta": if let text = delta["thinking"] as? String { writer.delta(text) }
                    case "input_json_delta": if let json = delta["partial_json"] as? String { run.searches[index]?.input += json }
                    default: break
                    }
                case "content_block_stop":
                    // The query is complete only now. Its card waits for the end of the message.
                    guard let search = run.searches.removeValue(forKey: index) else { break }
                    let input = (try? JSONSerialization.jsonObject(with: Data(search.input.utf8))) as? [String: Any]
                    run.pendingSearches[search.id] = input?["query"] as? String ?? ""
                    run.unshownSearches.append(search.id)
                case "message_start":
                    run.codexCallInMessage = false
                case "message_stop":
                    // A Codex tool call in the same message pauses this response before the search can finish, so
                    // such a search gets no in-progress card here, only a finished one once its results arrive.
                    if !run.codexCallInMessage {
                        for id in run.unshownSearches { if let query = run.pendingSearches[id] { writer.startSearch(id, query: query) } }
                    }
                    run.unshownSearches.removeAll()
                default: break
                }
            case .toolResult(let id, let failed):
                // Any other tool result belongs to a Codex tool call, which Codex already shows.
                guard let query = run.pendingSearches.removeValue(forKey: id) else { break }
                writer.finishSearch(id, query: query, status: failed ? "failed" : "completed")
            case .call(let pending):
                writer.finishItem()
                // Only reached by a search whose message had no Codex call, e.g. one Claude Code never finished.
                writer.closeSearches()
                writer.addItem(pending.item)
                run.waiting.insert(pending.callID)
                if writer.usage == nil { writer.usage = run.lastUsage }
                writer.event("response.completed", ["response": writer.response("completed")])
                complete(run, writer, paused: true)
                return
            case .result(let value):
                if run.compacting {
                    let summary = (value["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !summary.isEmpty else { failResponse(run, writer, "Claude returned an empty compaction summary"); return }
                    writer.addItem(["id": "cmp_" + ClaudeBridge.identifier(), "type": "compaction",
                                    "encrypted_content": ClaudeBridge.compactionPrefix + summary])
                    // Report only the summary size; the pre-compaction history no longer occupies the context.
                    writer.usage = ClaudeBridge.usage(context: 0, cached: 0, output: ClaudeBridge.integer(writer.usage?["output_tokens"]))
                } else {
                    if !writer.markFinalAnswer(), let text = value["result"] as? String, !text.isEmpty {
                        writer.startItem("message", phase: "final_answer")
                        writer.delta(text)
                    }
                    writer.finishItem()
                    writer.closeSearches()
                    if writer.usage == nil { writer.usage = run.lastUsage }
                }
                writer.event("response.completed", ["response": writer.response("completed")])
                complete(run, writer, paused: false)
                return
            }
        }
    }

    private func complete(_ run: ClaudeRun, _ writer: ClaudeResponseWriter, paused: Bool) {
        if cache.count >= 64 { cache.removeFirst() }
        cache.append((writer.fingerprint, Date(), writer.wire, run.id, paused))
        run.writer = nil
        writer.sink.finish()
        if !paused { forget(run) }
    }

    private func failResponse(_ run: ClaudeRun, _ writer: ClaudeResponseWriter, _ message: String) {
        writer.closeSearches()
        var failed = writer.response("failed")
        failed["error"] = ["code": run.failureCode ?? "bridge_error", "message": message]
        writer.event("response.failed", ["response": failed])
        run.writer = nil
        writer.sink.finish()
        cancel(run, message)
        forget(run)
    }

    // MARK: Helpers

    private static func toolResults(_ inputs: [Any]) -> [String: [String: Any]] {
        var results: [String: [String: Any]] = [:]
        for case let item as [String: Any] in inputs
        where ["function_call_output", "custom_tool_call_output"].contains(item["type"] as? String ?? "") {
            if let callID = item["call_id"] as? String { results[callID] = item }
        }
        return results
    }

    private static func roles(_ inputs: [Any]) -> [[String: Any]] {
        inputs.compactMap { $0 as? [String: Any] }.filter { ["user", "developer", "system"].contains($0["role"] as? String ?? "") }
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var pending = [pid]
        while let parent = pending.popLast() {
            var buffer = [pid_t](repeating: 0, count: 256)
            let count = proc_listchildpids(parent, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { continue }
            let children = buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 && !found.contains($0) }
            found += children
            pending += children
        }
        return found
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// One Claude Code process for one Codex turn. Confined to the executor queue.
final class ClaudeRun: @unchecked Sendable {
    enum Event {
        case stream([String: Any])
        case call(ClaudePending)
        /// Claude Code returned the result of a tool call, by tool_use ID.
        case toolResult(String, failed: Bool)
        case result([String: Any])
        case error(String)
    }

    let id = ClaudeBridge.identifier()
    let key: String
    let turnID: String?
    let model: ClaudeModel
    let data: [String: Any]
    let compacting: Bool
    let permissionMode: ClaudePermissionMode
    /// Claude Code's WebSearch is allowed, because Codex offers web search.
    let search: Bool
    var inputs: [Any]
    var table: [String: ClaudeTool]
    var events: [Event] = []
    /// WebSearch calls being streamed, by content block index: the tool_use ID and the input JSON so far.
    var searches: [Int: (id: String, input: String)] = [:]
    /// Queries of the WebSearch calls waiting for results, by tool_use ID. They may outlast a paused response.
    var pendingSearches: [String: String] = [:]
    /// WebSearch calls of the current message whose card is not shown yet, in order.
    var unshownSearches: [String] = []
    /// The current Claude message also calls a Codex tool, which pauses the response.
    var codexCallInMessage = false
    var calls: [String: ClaudePending] = [:]
    var waiting: Set<String> = []
    var writer: ClaudeResponseWriter?
    var cancelled = false
    var collected = false
    var initialized = false
    var launched: Date?
    var failureCode: String?
    var lastUsage: [String: Any]?
    var touched = Date()
    var output = Date()
    var process: Process?
    var scratch: URL?
    var buffer = Data()
    private var errors = Data()

    init(key: String, turnID: String?, model: ClaudeModel, data: [String: Any], inputs: [Any], table: [String: ClaudeTool],
         compacting: Bool = false) {
        self.key = key
        self.turnID = turnID
        self.model = model
        self.data = data
        self.inputs = inputs
        self.table = table
        self.compacting = compacting
        permissionMode = compacting ? .dontAsk : .mirroring(inputs)
        search = ClaudeBridge.webSearch(data["tools"])
    }

    var effort: String { compacting ? ClaudeBridge.compactionEffort : ClaudeBridge.effort(data) }

    /// The only tools Claude Code may have: the Codex relay tools, and WebSearch while Codex offers web search.
    var allowedTools: [String] { table.keys.sorted().map { "mcp__codex__" + $0 } + (search ? [ClaudeBridge.searchTool] : []) }

    func recordError(_ data: Data) {
        errors.append(data)
        if errors.count > 4096 { errors = Data(errors.suffix(4096)) }
    }

    /// The last stderr line of Claude Code, for failure messages. Empty when there is none.
    var diagnostic: String {
        let line = String(decoding: errors, as: UTF8.self).split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { ": " + String($0.trimmingCharacters(in: .whitespaces).prefix(300)) } ?? ""
    }

    func arguments(relay: URL?, config: URL) -> [String] {
        // Claude Code refuses bypassPermissions in restricted mode. It still has no tools, settings or MCP servers of its own.
        var arguments = permissionMode == .bypassPermissions ? [] : ["--restricted"]
        arguments += ["-p", "--model", model.cliModel]
        if model.efforts.contains(effort) { arguments += ["--effort", effort] }
        arguments += ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--tools", search ? ClaudeBridge.searchTool : "", "--setting-sources", "", "--strict-mcp-config"]
        if !table.isEmpty, let relay {
            let server: [String: Any] = ["command": relay.path, "args": [ClaudeMCPRelay.flag, config.path]]
            arguments += ["--mcp-config", ClaudeBridge.text(["mcpServers": ["codex": server]])]
        }
        let settings: [String: Any] = ["disableAllHooks": true, "enabledPlugins": [String: Any](), "autoMemoryEnabled": false]
        let prompt = compacting ? ClaudeBridge.compactionSystemPrompt
            : ClaudeBridge.systemPrompt + (permissionMode == .plan ? ClaudeBridge.planModePrompt : "")
        arguments += ["--permission-mode", permissionMode.rawValue, "--permission-prompts", "none", "--disable-slash-commands", "--no-chrome",
                      "--no-session-persistence", "--system-prompt-snapshot", "off", "--settings", ClaudeBridge.text(settings),
                      "--append-system-prompt", prompt]
        if !allowedTools.isEmpty { arguments += ["--allowedTools", allowedTools.joined(separator: ",")] }
        return arguments
    }
}

/// A Claude tool call waiting for Codex. Resolving it answers the parked MCP relay request.
final class ClaudePending: @unchecked Sendable {
    let callID: String
    let item: [String: Any]
    private var sink: ClaudeSink?

    init(callID: String, item: [String: Any], sink: ClaudeSink) {
        self.callID = callID
        self.item = item
        self.sink = sink
    }

    func resolve(_ result: [String: Any]) {
        guard let sink else { return }
        self.sink = nil
        sink.respond(status: 200, json: ClaudeBridge.encode(result))
    }
}

/// Builds one Codex Responses SSE stream. Confined to the executor queue.
final class ClaudeResponseWriter: @unchecked Sendable {
    let sink: ClaudeSink
    let fingerprint: String
    let model: String
    let responseID = "resp_" + ClaudeBridge.identifier()
    var usage: [String: Any]?
    private(set) var wire = Data()
    private var sequence = 0
    private var items: [[String: Any]] = []
    /// Output indexes of this response's search cards still in progress, by WebSearch tool_use ID.
    private var searches: [String: Int] = [:]
    private var active: (index: Int, reasoning: Bool, text: String)?
    private var contextInput: Int?
    private var contextCached = 0

    init(sink: ClaudeSink, fingerprint: String, model: String) {
        self.sink = sink
        self.fingerprint = fingerprint
        self.model = model
    }

    func event(_ kind: String, _ payload: [String: Any] = [:]) {
        var payload = payload
        payload["type"] = kind
        payload["sequence_number"] = sequence
        sequence += 1
        var data = Data("event: \(kind)\ndata: ".utf8)
        data.append(ClaudeBridge.encode(payload))
        data.append(Data("\n\n".utf8))
        wire.append(data)
        sink.write(data)
    }

    func response(_ status: String) -> [String: Any] {
        ["id": responseID, "object": "response", "created_at": Int(Date().timeIntervalSince1970), "status": status,
         "model": model, "output": items, "usage": usage ?? NSNull()]
    }

    /// The latest Claude API call is the context actually occupied, including Claude Code's own prompt.
    func trackUsage(_ value: [String: Any], run: ClaudeRun) {
        let output: Int
        switch value["type"] as? String {
        case "message_start":
            let usage = (value["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
            contextInput = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ClaudeBridge.integer(usage[$1]) }
            contextCached = ClaudeBridge.integer(usage["cache_read_input_tokens"])
            output = ClaudeBridge.integer(usage["output_tokens"])
        case "message_delta" where contextInput != nil:
            output = ClaudeBridge.integer((value["usage"] as? [String: Any])?["output_tokens"])
        default: return
        }
        usage = ClaudeBridge.usage(context: contextInput ?? 0, cached: contextCached, output: output)
        run.lastUsage = usage
    }

    func addItem(_ item: [String: Any]) {
        let index = items.count
        items.append(item)
        event("response.output_item.added", ["output_index": index, "item": item])
        event("response.output_item.done", ["output_index": index, "item": item])
    }

    func startItem(_ kind: String, phase: String = "commentary") {
        finishItem()
        let index = items.count
        let reasoning = kind == "reasoning"
        let id = (reasoning ? "rs_" : "msg_") + ClaudeBridge.identifier()
        let item: [String: Any] = reasoning
            ? ["id": id, "type": "reasoning", "summary": [Any]()]
            : ["id": id, "type": "message", "role": "assistant", "status": "in_progress", "content": [Any](), "phase": phase]
        items.append(item)
        active = (index, reasoning, "")
        event("response.output_item.added", ["output_index": index, "item": item])
        if reasoning {
            event("response.reasoning_summary_part.added", ["item_id": id, "output_index": index, "summary_index": 0, "part": contentPart(reasoning: true, text: "")])
        } else {
            event("response.content_part.added", ["item_id": id, "output_index": index, "content_index": 0, "part": contentPart(reasoning: false, text: "")])
        }
    }

    func delta(_ text: String) {
        if active == nil { startItem("message") }
        guard let current = active, let id = items[current.index]["id"] else { return }
        active?.text += text
        if current.reasoning {
            event("response.reasoning_summary_text.delta", ["item_id": id, "output_index": current.index, "summary_index": 0, "delta": text])
        } else {
            event("response.output_text.delta", ["item_id": id, "output_index": current.index, "content_index": 0, "delta": text])
        }
    }

    func finishItem() {
        guard let current = active, let id = items[current.index]["id"] else { return }
        active = nil
        let part = contentPart(reasoning: current.reasoning, text: current.text)
        if current.reasoning {
            items[current.index]["summary"] = [part]
            event("response.reasoning_summary_text.done", ["item_id": id, "output_index": current.index, "summary_index": 0, "text": current.text])
            event("response.reasoning_summary_part.done", ["item_id": id, "output_index": current.index, "summary_index": 0, "part": part])
        } else {
            items[current.index]["status"] = "completed"
            items[current.index]["content"] = [part]
            event("response.output_text.done", ["item_id": id, "output_index": current.index, "content_index": 0, "text": current.text])
            event("response.content_part.done", ["item_id": id, "output_index": current.index, "content_index": 0, "part": part])
        }
        event("response.output_item.done", ["output_index": current.index, "item": items[current.index]])
    }

    /// A Claude WebSearch as the web_search_call item Codex shows for its own hosted search.
    func startSearch(_ id: String, query: String) {
        searches[id] = addSearch(query, status: "in_progress")
    }

    /// Completes the search's card, or adds a finished card when the search began in an earlier, paused response.
    func finishSearch(_ id: String, query: String, status: String) {
        let index = searches.removeValue(forKey: id) ?? addSearch(query, status: status)
        items[index]["status"] = status
        event("response.output_item.done", ["output_index": index, "item": items[index]])
    }

    /// No response ends with a search card in progress. One without results is incomplete, never completed.
    func closeSearches() {
        for index in searches.values.sorted() {
            items[index]["status"] = "incomplete"
            event("response.output_item.done", ["output_index": index, "item": items[index]])
        }
        searches.removeAll()
    }

    private func addSearch(_ query: String, status: String) -> Int {
        finishItem()
        let index = items.count
        items.append(["id": ClaudeBridge.searchPrefix + ClaudeBridge.identifier(), "type": "web_search_call", "status": status,
                      "action": ["type": "search", "query": query]])
        event("response.output_item.added", ["output_index": index, "item": items[index]])
        return index
    }

    /// Marks an open message as the final answer. Returns false when no message is open.
    func markFinalAnswer() -> Bool {
        guard let current = active, !current.reasoning else { return false }
        items[current.index]["phase"] = "final_answer"
        return true
    }

    private func contentPart(reasoning: Bool, text: String) -> [String: Any] {
        reasoning ? ["type": "summary_text", "text": text] : ["type": "output_text", "text": text, "annotations": [Any]()]
    }
}
