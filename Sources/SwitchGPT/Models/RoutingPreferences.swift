import Foundation

struct RoutingPreferences: Codable {
    var automatic = true
    var configuredAt: Date?
    var desktopVerified = false

    private enum CodingKeys: String, CodingKey {
        case automatic
        case configuredAt
        case desktopVerified
    }

    init(automatic: Bool = true, configuredAt: Date? = nil, desktopVerified: Bool = false) {
        self.automatic = automatic
        self.configuredAt = configuredAt
        self.desktopVerified = desktopVerified
    }

    /// Keep preferences written by older SwitchGPT versions readable. Stored
    /// defaults are not used by synthesized Decodable when a key is absent.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
        configuredAt = try values.decodeIfPresent(Date.self, forKey: .configuredAt)
        desktopVerified = try values.decodeIfPresent(Bool.self, forKey: .desktopVerified) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(automatic, forKey: .automatic)
        try values.encodeIfPresent(configuredAt, forKey: .configuredAt)
        try values.encode(desktopVerified, forKey: .desktopVerified)
    }

    func needsRestart(desktopLaunchedAt: Date?) -> Bool {
        guard !desktopVerified, let configuredAt else { return false }
        guard let desktopLaunchedAt else { return true }
        return desktopLaunchedAt <= configuredAt
    }
}
