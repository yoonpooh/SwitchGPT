import Foundation

/// Finds the Claude Code CLI that the user installed and signed in to. Credentials are never read here.
enum ClaudeCLI {
    static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home.appendingPathComponent(".local/bin/claude"), home.appendingPathComponent(".claude/local/claude"),
         URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")]
    }

    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        candidates(home: home).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The user's environment, minus anything that would replace Claude Code's own sign-in, with the CLI's folder on PATH.
    static func environment(executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Authentication stays entirely inside the original CLI; no credentials are read or injected here.
        for name in ["CLAUDE_CODE_SAFE_MODE", "CLAUDE_CODE_SIMPLE", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
                     "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            environment[name] = nil
        }
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin", environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        return environment
    }
}

/// Private stdio MCP transport started by Claude Code as "SwitchGPT <flag> <relay.json>".
/// It requests execution from Codex through SwitchGPT and executes no tools itself.
struct ClaudeMCPRelay: Sendable {
    static let flag = "--switchgpt-claude-mcp-relay"
    let runID: String
    let token: String
    let url: URL
    let session: URLSession
    private let output = NSLock()

    init?(config: Data, session: URLSession) {
        guard let config = (try? JSONSerialization.jsonObject(with: config)) as? [String: Any],
              let runID = config["run_id"] as? String, let token = config["token"] as? String,
              let address = config["url"] as? String, let url = URL(string: address) else { return nil }
        self.runID = runID
        self.token = token
        self.url = url
        self.session = session
    }

    static func run(config path: String) -> Never {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 3600
        configuration.connectionProxyDictionary = [:]
        guard let data = FileManager.default.contents(atPath: path),
              let relay = ClaudeMCPRelay(config: data, session: URLSession(configuration: configuration)) else { exit(2) }
        let parent = getppid()
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 2, repeating: 2)
        // If Claude Code dies without closing stdin, this relay must not outlive it.
        watchdog.setEventHandler { if getppid() != parent { exit(0) } }
        watchdog.resume()
        let pending = DispatchGroup()
        withExtendedLifetime(watchdog) {
            while let line = readLine(strippingNewline: true) {
                // A parked tools/call must not block ping or other calls.
                DispatchQueue.global().async(group: pending) { relay.handle(line) }
            }
            pending.wait() // Answer requests already received before stdin closed.
        }
        exit(0)
    }

    func handle(_ line: String) {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let id = request["id"] else { return } // Notifications need no reply.
        var message = ClaudeBridge.encode(reply(id: id, method: request["method"] as? String ?? "",
                                                params: request["params"] as? [String: Any] ?? [:]))
        message.append(0x0a)
        output.withLock { FileHandle.standardOutput.write(message) }
    }

    func reply(id: Any, method: String, params: [String: Any]) -> [String: Any] {
        switch method {
        case "initialize":
            return ["jsonrpc": "2.0", "id": id, "result": [
                "protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05", "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "Codex native executor relay", "version": "1.0"]] as [String: Any]]
        case "ping":
            return ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
        case "tools/list", "tools/call":
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = ClaudeBridge.encode(["run_id": runID, "method": method, "params": params] as [String: Any])
            let result = post(request) ?? ["content": [["type": "text", "text": "Codex relay unavailable"]], "isError": true]
            return ["jsonrpc": "2.0", "id": id, "result": result]
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported MCP method"] as [String: Any]]
        }
    }

    private func post(_ request: URLRequest) -> [String: Any]? {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        session.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                box.value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            done.signal()
        }.resume()
        done.wait()
        return box.value
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: [String: Any]?
}
