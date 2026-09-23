import Foundation

struct ModelRoutingDecision: Codable, Sendable, Equatable {
    let originalModel: String
    let originalEffort: String?
    let selectedModel: String
    let selectedEffort: String?
    let reason: String

    var changed: Bool { originalModel != selectedModel || originalEffort != selectedEffort }

    var isMiniMapping: Bool {
        originalModel == "gpt-5.4-mini" && originalEffort == "low"
            && selectedModel == "gpt-6-luna" && selectedEffort == "low"
    }
}

/// Local compatibility mapping. It never sends the request to a classifier.
enum MiniModelRouter {
    static func route(_ request: RelayRequest) -> (request: RelayRequest, decision: ModelRoutingDecision?) {
        guard request.isModelRequest else { return (request, nil) }
        let body: Data
        switch request.headers["content-encoding"]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case nil, "", "identity": body = request.body
        case "zstd":
            guard let decoded = ZstdRequestBody.decode(request.body) else { return (request, nil) }
            body = decoded
        default: return (request, nil)
        }
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["model"] as? String == "gpt-5.4-mini",
              let reasoning = object["reasoning"] as? [String: Any],
              reasoning["effort"] as? String == "low" else { return (request, nil) }

        object["model"] = "gpt-6-luna"
        guard let rewritten = try? JSONSerialization.data(withJSONObject: object) else { return (request, nil) }
        var headers = request.headers
        headers.removeValue(forKey: "content-encoding")
        headers.removeValue(forKey: "content-length")
        let routed = RelayRequest(method: request.method, target: request.target, headers: headers, body: rewritten)
        let decision = ModelRoutingDecision(originalModel: "gpt-5.4-mini", originalEffort: "low",
                                            selectedModel: "gpt-6-luna", selectedEffort: "low", reason: "routed")
        return (routed, decision)
    }
}
