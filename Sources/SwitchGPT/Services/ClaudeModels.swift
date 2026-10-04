import Foundation

/// A Claude model Claude Code offers the signed-in account, listed in the Codex model picker under its Claude model ID,
/// such as "claude-opus-5-5".
struct ClaudeModel: Codable, Equatable, Sendable {
    let slug: String
    let name: String
    /// Passed to claude --model.
    let cliModel: String
    /// Empty when Claude Code has no effort setting for the model.
    let efforts: [String]
    /// Claude Code's own auto-compact threshold, so Codex compacts the thread before Claude Code would have to.
    let contextWindow: Int

    static let prefix = "claude-"
    static let largeContext = 967_000
    static let smallContext = 167_000
    /// Listed until Claude Code has been asked, and still served for threads that already use it.
    static let fallback = ClaudeModel(slug: "claude-opus-5-5", name: "Opus 5.5", cliModel: "claude-opus-5-5[1m]",
                                      efforts: ["low", "medium", "high", "xhigh", "max"], contextWindow: largeContext)

    init(slug: String, name: String, cliModel: String, efforts: [String], contextWindow: Int) {
        self.slug = slug
        self.name = name
        self.cliModel = cliModel
        self.efforts = efforts
        self.contextWindow = contextWindow
    }

    static func isClaude(_ model: Any?) -> Bool { (model as? String)?.hasPrefix(prefix) == true }

    /// One entry of Claude Code's model list. An alias such as "sonnet" is pinned to the model it resolves to,
    /// so a slug never silently starts running a different model after a Claude Code update.
    init?(option: [String: Any]) {
        guard let value = option["value"] as? String else { return nil }
        let resolved = option["resolvedModel"] as? String ?? value
        let cliModel = value.hasPrefix("claude-") ? value : resolved
        let base = Self.base(cliModel)
        guard cliModel.hasPrefix("claude-"), !base.isEmpty,
              base.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        let description = option["description"] as? String ?? ""
        let named = description.range(of: #"^[A-Z][A-Za-z]* [0-9]+(\.[0-9]+)*"#, options: .regularExpression).map { String(description[$0]) }
        let levels = option["supportsEffort"] as? Bool == true ? option["supportedEffortLevels"] as? [String] ?? [] : []
        self.init(slug: Self.prefix + base, name: named ?? Self.name(base), cliModel: cliModel,
                  // Codex rejects a whole model list with an effort it does not know.
                  efforts: levels.filter(ClaudeBridge.efforts.contains),
                  contextWindow: [value, resolved].contains { $0.contains("[1m]") } ? Self.largeContext : Self.smallContext)
    }

    func with(contextWindow: Int) -> ClaudeModel {
        ClaudeModel(slug: slug, name: name, cliModel: cliModel, efforts: efforts, contextWindow: contextWindow)
    }

    /// "claude-opus-5-5" -> ("opus", [5, 5]).
    var family: (name: String, version: [Int]) {
        let parts = slug.dropFirst(Self.prefix.count).split(separator: "-")
        return (parts.filter { Int($0) == nil }.joined(separator: "-"), parts.compactMap { Int($0) })
    }

    /// Claude Code also offers every earlier version of a model; keeps only the newest of each family, in order.
    static func newest(_ models: [ClaudeModel]) -> [ClaudeModel] {
        models.filter { model in
            let own = model.family
            return !models.contains { $0.family.name == own.name && own.version.lexicographicallyPrecedes($0.family.version) }
        }
    }

    /// "claude-haiku-4-5-20251001" -> "haiku-4-5", "claude-opus-5-5[1m]" -> "opus-5-5".
    static func base(_ model: String) -> String {
        var base = model.lowercased()
        if let bracket = base.firstIndex(of: "[") { base = String(base[..<bracket]) }
        if base.hasPrefix("claude-") { base.removeFirst("claude-".count) }
        return base.replacingOccurrences(of: #"-[0-9]{8}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ".", with: "-")
    }

    /// "opus-5-5" -> "Opus 5.5".
    static func name(_ base: String) -> String {
        let parts = base.split(separator: "-").map(String.init)
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }.map(\.capitalized)
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }
}

/// Asks the Claude Code CLI signed in on this Mac which models it offers. Makes no model call and spends no usage.
enum ClaudeModelDiscovery {
    static func run(executable: URL) throws -> [ClaudeModel] {
        let options = try control(executable, subtype: "initialize")["models"] as? [[String: Any]] ?? []
        var models: [ClaudeModel] = []
        for option in options {
            guard let model = ClaudeModel(option: option), !models.contains(where: { $0.slug == model.slug }) else { continue }
            models.append(model)
        }
        guard !models.isEmpty else { throw ClaudeFailure(status: 502, message: "Claude Code listed no models") }
        let listed = models
        let windows = Windows()
        DispatchQueue.concurrentPerform(iterations: listed.count) { index in
            let model = listed[index]
            guard let usage = try? control(executable, model: model.cliModel, subtype: "get_context_usage"),
                  let threshold = (usage["autoCompactThreshold"] as? NSNumber)?.intValue, threshold > 0 else { return }
            windows.set(threshold, for: model.slug)
        }
        return listed.map { $0.with(contextWindow: windows.value(for: $0.slug) ?? $0.contextWindow) }
    }

    private final class Windows: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func set(_ value: Int, for slug: String) { lock.withLock { values[slug] = value } }
        func value(for slug: String) -> Int? { lock.withLock { values[slug] } }
    }

    /// Sends one control request to a Claude Code process that has no tools, settings or MCP servers, and returns its answer.
    static func control(_ executable: URL, model: String? = nil, subtype: String, timeout: TimeInterval = 30) throws -> [String: Any] {
        try controls(executable, model: model, subtypes: [subtype], timeout: timeout)[0]
    }

    /// Sends control requests to one such process in order and returns their answers in the same order.
    static func controls(_ executable: URL, model: String? = nil, subtypes: [String], timeout: TimeInterval = 30,
                         cancellation: ProcessCancellation? = nil) throws -> [[String: Any]] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("switchgpt-claude-models-" + ClaudeBridge.identifier())
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--restricted", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--no-session-persistence", "--tools", "", "--setting-sources", "", "--strict-mcp-config",
                             "--disable-slash-commands", "--no-chrome"] + (model.map { ["--model", $0] } ?? [])
        process.currentDirectoryURL = scratch
        process.environment = ClaudeCLI.environment(executable: executable)
        process.standardError = FileHandle.nullDevice
        var lines = Data()
        for (index, subtype) in subtypes.enumerated() {
            lines.append(ClaudeBridge.encode(["type": "control_request", "request_id": "switchgpt-\(index)", "request": ["subtype": subtype]] as [String: Any]))
            lines.append(0x0a)
        }
        let data = try ControlledProcess.capture(process, input: lines, timeout: timeout, cancellation: cancellation)
        var answers = [[String: Any]?](repeating: nil, count: subtypes.count)
        for line in data.split(separator: 0x0a) {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  event["type"] as? String == "control_response", let response = event["response"] as? [String: Any],
                  let id = response["request_id"] as? String, id.hasPrefix("switchgpt-"),
                  let index = Int(id.dropFirst("switchgpt-".count)), answers.indices.contains(index) else { continue }
            guard response["subtype"] as? String == "success", let answer = response["response"] as? [String: Any] else {
                throw ClaudeFailure(status: 502, message: "Claude Code refused " + subtypes[index] + ": " + (response["error"] as? String ?? "unknown error"))
            }
            answers[index] = answer
        }
        if let missing = answers.firstIndex(where: { $0 == nil }) {
            throw ClaudeFailure(status: 502, message: "Claude Code did not answer " + subtypes[missing])
        }
        return answers.compactMap { $0 }
    }
}

/// The Claude models in the Codex picker: the last answer of Claude Code, kept per Claude Code version.
final class ClaudeModelCatalog: @unchecked Sendable {
    private struct Snapshot: Codable {
        let version: String
        let date: Date
        let models: [ClaudeModel]
    }

    static let maximumAge: TimeInterval = 6 * 3600
    /// How long a model list request waits for Claude Code to be asked again before the previous list is served.
    static let catalogWait: TimeInterval = 10
    private let lock = NSLock()
    private let file: URL?
    private let executable: @Sendable () -> URL?
    private let discover: (@Sendable (URL) throws -> [ClaudeModel])?
    private var snapshot: Snapshot?
    private var refreshing = false
    private var waiters: [@Sendable () -> Void] = []

    /// Without discover the list stays fixed: the given models, or Opus 5.5 alone.
    init(file: URL? = nil, models: [ClaudeModel]? = nil, executable: @escaping @Sendable () -> URL? = { ClaudeCLI.locate() },
         discover: (@Sendable (URL) throws -> [ClaudeModel])? = nil) {
        self.file = file
        self.executable = executable
        self.discover = discover
        if let models { snapshot = Snapshot(version: "", date: .distantFuture, models: models) }
        else if let file, let data = try? Data(contentsOf: file) {
            snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    var models: [ClaudeModel] { lock.withLock { snapshot?.models } ?? [.fallback] }

    func model(for slug: String) -> ClaudeModel? {
        models.first { $0.slug == slug } ?? (slug == ClaudeModel.fallback.slug ? .fallback : nil)
    }

    /// Asks Claude Code again after it was updated, or when the list is older than maximumAge. Never blocks the caller.
    func refresh(completion: (@Sendable () -> Void)? = nil) {
        guard let discover, let executable = executable() else { completion?(); return }
        let version = Self.version(executable)
        enum Action { case current, waiting, start }
        let action: Action = lock.withLock {
            if refreshing { if let completion { waiters.append(completion) }; return .waiting }
            if let snapshot, snapshot.version == version, Date().timeIntervalSince(snapshot.date) < Self.maximumAge { return .current }
            refreshing = true
            if let completion { waiters.append(completion) }
            return .start
        }
        switch action {
        case .current: completion?(); return
        case .waiting: return
        case .start: break
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            // A failed query keeps the previous list; it is retried on the next refresh.
            let models = try? discover(executable)
            let waiting: [@Sendable () -> Void] = lock.withLock {
                if let models { snapshot = Snapshot(version: version, date: Date(), models: models) }
                refreshing = false
                defer { waiters.removeAll() }
                return waiters
            }
            if let models, let file {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(Snapshot(version: version, date: Date(), models: models)).write(to: file, options: .atomic)
            }
            for waiter in waiting { waiter() }
        }
    }

    /// Calls completion once the list is current, or after timeout with the list as it is then.
    func refresh(waitingAtMost timeout: TimeInterval, completion: @escaping @Sendable () -> Void) {
        let once = Once()
        let finish: @Sendable () -> Void = { if once.claim() { completion() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: finish)
        refresh(completion: finish)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    func refreshed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in refresh { continuation.resume() } }
    }

    /// The native installer links claude to a versioned file, so its resolved path and date change with every update.
    static func version(_ executable: URL) -> String {
        let resolved = executable.resolvingSymlinksInPath()
        let date = (try? FileManager.default.attributesOfItem(atPath: resolved.path)[.modificationDate] as? Date) ?? .distantPast
        return resolved.path + "@" + String(Int(date.timeIntervalSince1970))
    }
}
