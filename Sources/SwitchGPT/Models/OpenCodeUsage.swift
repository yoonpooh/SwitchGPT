import Foundation

struct OpenCodeModel: Codable, Identifiable, Sendable {
    let id: String
    var isPickerModel: Bool { !id.hasPrefix("gpt-") && !id.hasPrefix("claude-") }
    // The Go API's created timestamp is catalog generation time, not a model release date.
    // shortcut: models.dev release dates are bundled as of 2026-10-13; refresh the snapshot when new models appear.
    private static let releaseDates: [String: String] = {
        guard let file = Bundle.module.url(forResource: "GoModelReleaseDates", withExtension: "json"),
              let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()
    static func newestFirst(_ models: [OpenCodeModel]) -> [OpenCodeModel] {
        models.sorted {
            let first = releaseDates[$0.id] ?? ""
            let second = releaseDates[$1.id] ?? ""
            if first != second { return first > second }
            return $0.id.compare($1.id, options: .numeric) == .orderedDescending
        }
    }
    var slug: String { id.hasPrefix("deepseek-") ? id : OpenCodeGo.prefix + id }
    var name: String {
        let brands = ["deepseek": "DeepSeek", "mimo": "MiMo", "glm": "GLM", "gpt": "GPT", "minimax": "MiniMax",
                      "qwen": "Qwen", "hy": "Hy", "longcat": "LongCat"]
        let versioned = id.replacingOccurrences(of: #"(?<=[0-9])-(?=[0-9])"#, with: ".", options: .regularExpression)
        return versioned.split(separator: "-").map { part in
            let word = String(part)
            if let brand = brands[word] { return brand }
            for (prefix, brand) in brands where word.hasPrefix(prefix) && word.dropFirst(prefix.count).first?.isNumber == true {
                return brand + word.dropFirst(prefix.count)
            }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    init(id: String) { self.id = id }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let value = try values.decode(String.self, forKey: .id)
        guard !value.isEmpty, value.count <= 128,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) }) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "Invalid Go model ID")
        }
        id = value
    }
    private enum CodingKeys: String, CodingKey { case id }
}

struct OpenCodeUsage: Decodable, Sendable {
    let usage: Windows
    struct Windows: Decodable, Sendable {
        let rolling: Window?
        let weekly: Window?
        let monthly: Window?
    }
    struct Window: Decodable, Sendable {
        let percent: Double
        let resetsAt: String?
        var remaining: Double { min(100, max(0, 100 - percent)) }
        var resetDate: Date? {
            guard let resetsAt else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
        }
    }
}
