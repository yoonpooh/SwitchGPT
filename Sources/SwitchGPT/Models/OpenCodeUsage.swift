import Foundation

struct OpenCodeModel: Codable, Identifiable, Sendable {
    let id: String
    var slug: String { id.hasPrefix("deepseek-") ? id : OpenCodeGo.prefix + id }
    var name: String { id == OpenCodeGo.model ? "DeepSeek V4.1 Flash" : id }

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
