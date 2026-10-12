import Foundation

/// Only the Go key crosses this provider boundary; desktop OAuth credentials never do.
final class OpenCodeGo: @unchecked Sendable {
    static let model = "deepseek-v4.1-flash"
    static let vaultID = "provider:opencode-go"
    private let lock = NSLock()
    private var key: String?
    let baseURL: URL

    init(baseURL: URL = URL(string: "https://opencode.ai/zen/go/v1")!) { self.baseURL = baseURL }

    var apiKey: String? { lock.lock(); defer { lock.unlock() }; return key }
    func setKey(_ key: String?) { lock.lock(); defer { lock.unlock() }; self.key = key }
    static func isModel(_ value: Any?) -> Bool { (value as? String)?.hasPrefix("deepseek-") == true }

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
        guard incoming.modelForEvent == Self.model else {
            throw ClaudeFailure(status: 400, message: "SwitchGPT: unsupported OpenCode Go model.")
        }
        guard var object = try JSONSerialization.jsonObject(with: incoming.body) as? [String: Any] else {
            throw HTTPFailure(status: 400)
        }
        if var reasoning = object["reasoning"] as? [String: Any], let effort = reasoning["effort"] as? String {
            if effort == "ultra" { reasoning["effort"] = "max" }
            object["reasoning"] = reasoning
        }
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
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var models = object["models"] as? [[String: Any]],
              !models.contains(where: { $0["slug"] as? String == model }) else { return nil }
        var item = ClaudeBridge.catalogTemplate()
        item["slug"] = model
        item["display_name"] = "DeepSeek V4.1 Flash"
        item["description"] = L10n.text("go_model_description")
        item["base_instructions"] = "You are DeepSeek, a coding agent in Codex. Complete the user's task using the available tools, follow Codex permissions, and report verification and limitations honestly."
        item["priority"] = (models.compactMap { $0["priority"] as? Int }.max() ?? 0) + 1
        item["context_window"] = 1_000_000
        item["max_context_window"] = 1_000_000
        item["supported_reasoning_levels"] = ["high", "max"].map { ["effort": $0, "description": $0] }
        item["default_reasoning_level"] = "high"
        item["tool_mode"] = "standard"
        item["support_verbosity"] = false
        item["supports_reasoning_summaries"] = false
        models.append(item)
        object["models"] = models
        return ClaudeBridge.encode(object)
    }
}
