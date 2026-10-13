import Foundation

/// Only the Go key crosses this provider boundary; desktop OAuth credentials never do.
final class OpenCodeGo: @unchecked Sendable {
    static let model = "deepseek-v4.1-flash"
    static let prefix = "opencode-go/"
    static let vaultID = "provider:opencode-go"
    private let lock = NSLock()
    private var key: String?
    private var catalog = [OpenCodeModel(id: OpenCodeGo.model)]
    private var selection: Set<String> = [OpenCodeGo.model]
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let baseURL: URL

    init(baseURL: URL = URL(string: "https://opencode.ai/zen/go/v1")!,
         send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await OpenCodeGo.session.data(for: $0) }) {
        self.baseURL = baseURL
        self.send = send
    }
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    var models: [OpenCodeModel] { lock.withLock { catalog } }
    var selectedModelIDs: Set<String> { lock.withLock { selection } }
    func setModels(_ models: [OpenCodeModel]) { lock.withLock { catalog = OpenCodeModel.newestFirst(models) } }
    func setSelection(_ ids: [String]?) {
        lock.withLock { selection = Set((ids ?? [Self.model]).filter { OpenCodeModel(id: $0).isPickerModel }) }
    }

    func fetchUsage() async throws -> OpenCodeUsage {
        try JSONDecoder().decode(OpenCodeUsage.self, from: await get("usage"))
    }
    func fetchModels() async throws -> [OpenCodeModel] {
        struct Catalog: Decodable { let data: [OpenCodeModel] }
        return try JSONDecoder().decode(Catalog.self, from: await get("models")).data
    }
    private func get(_ path: String) async throws -> Data {
        guard let key = apiKey else { throw SwitchError(message: L10n.text("go_missing_key")) }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("SwitchGPT/1.0 Codex", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SwitchError(message: L10n.format("usage_error", (response as? HTTPURLResponse)?.statusCode ?? 0))
        }
        return data
    }

    var apiKey: String? { lock.lock(); defer { lock.unlock() }; return key }
    func setKey(_ key: String?) { lock.lock(); defer { lock.unlock() }; self.key = key }
    static func isModel(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.hasPrefix("deepseek-") || value.hasPrefix(prefix)
    }

    static func validatedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw SwitchError(message: L10n.text("go_invalid_key"))
        }
        return key
    }

    func request(_ incoming: RelayRequest) throws -> URLRequest {
        guard let key = apiKey else { throw ClaudeFailure(status: 503, message: L10n.text("go_missing_key")) }
        let slug = incoming.modelForEvent ?? ""
        let modelID = slug.hasPrefix(Self.prefix) ? String(slug.dropFirst(Self.prefix.count)) : slug
        guard models.contains(where: { $0.id == modelID }) else {
            throw ClaudeFailure(status: 400, message: "SwitchGPT: unsupported OpenCode Go model.")
        }
        guard var object = try JSONSerialization.jsonObject(with: incoming.body) as? [String: Any] else {
            throw HTTPFailure(status: 400)
        }
        object["model"] = modelID
        if var reasoning = object["reasoning"] as? [String: Any], let effort = reasoning["effort"] as? String {
            if effort == "ultra" { reasoning["effort"] = "max" }
            object["reasoning"] = reasoning
        }
        if modelID != Self.model { object["reasoning"] = nil }
        // Service tiers belong to the selected provider, not the previous GPT model.
        object["service_tier"] = nil
        object["store"] = false
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("SwitchGPT/1.0 Codex", forHTTPHeaderField: "User-Agent")
        // Preserve one session across tool rounds; never invent a shared or per-request cache identity.
        let metadata = incoming.headers["x-codex-turn-metadata"]
            .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let candidates = [metadata?["thread_id"] as? String, incoming.headers["thread-id"],
                          object["prompt_cache_key"] as? String, incoming.headers["session-id"],
                          incoming.headers["session_id"], metadata?["session_id"] as? String,
                          incoming.headers["x-opencode-session"], incoming.headers["x-codex-session-id"]]
        guard let session = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw ClaudeFailure(status: 400, message: "SwitchGPT: OpenCode Go requires a Codex session ID. Start a new chat with a current Codex client.")
        }
        request.setValue(session, forHTTPHeaderField: "x-opencode-session")
        return request
    }

    static func addingCatalogItem(to body: Data) -> Data? {
        addingCatalogItems(to: body, models: [OpenCodeModel(id: model)], selected: [model])
    }

    static func addingCatalogItems(to body: Data, models available: [OpenCodeModel], selected: Set<String>) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var models = object["models"] as? [[String: Any]] else { return nil }
        let existing = Set(models.compactMap { $0["slug"] as? String })
        let added = available.filter { !existing.contains($0.slug) }
        guard !added.isEmpty else { return nil }
        let priority = (models.compactMap { $0["priority"] as? Int }.max() ?? 0) + 1
        for (offset, model) in added.enumerated() {
            var item = ClaudeBridge.catalogTemplate()
            item["slug"] = model.slug
            item["display_name"] = model.name
            item["visibility"] = model.isPickerModel && selected.contains(model.id) ? "list" : "hide"
            item["description"] = L10n.text("go_model_description")
            item["base_instructions"] = "You are a coding agent in Codex. Complete the user's task using the available tools, follow Codex permissions, and report verification and limitations honestly."
            item["priority"] = priority + offset
            // shortcut: Go discovery returns IDs only; use text, 128K and default reasoning until capability metadata is available.
            item["input_modalities"] = ["text"]
            item["context_window"] = model.id == Self.model ? 1_000_000 : 128_000
            item["max_context_window"] = item["context_window"]
            let efforts = model.id == Self.model ? ["low", "high", "max"] : ["high"]
            item["supported_reasoning_levels"] = efforts.map { ["effort": $0, "description": $0] }
            item["default_reasoning_level"] = "high"
            item["tool_mode"] = "standard"
            item["support_verbosity"] = false
            item["supports_reasoning_summaries"] = false
            models.append(item)
        }
        object["models"] = models
        return ClaudeBridge.encode(object)
    }
}
