import Foundation

struct RoutingPreferences: Codable {
    var automatic = true
    /// Whether Jev may choose the reasoning effort independently of the model.
    /// This is intentionally off for new installations. Older preferences that only
    /// stored `modelAutomatic` inherit that value during decoding below.
    var effortAutomatic = false
    var configuredAt: Date?
    var desktopVerified = false

    private enum CodingKeys: String, CodingKey {
        case automatic
        case effortAutomatic
        // Legacy-only key. It is decoded for migration but never encoded again.
        case modelAutomatic
        case configuredAt
        case desktopVerified
    }

    init(automatic: Bool = true, effortAutomatic: Bool = false,
         configuredAt: Date? = nil, desktopVerified: Bool = false) {
        self.automatic = automatic
        self.effortAutomatic = effortAutomatic
        self.configuredAt = configuredAt
        self.desktopVerified = desktopVerified
    }

    /// Keep preferences written by older SwitchGPT versions readable. Stored
    /// defaults are not used by synthesized Decodable when a key is absent.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
        // Prior versions had one Jev switch controlling both choices. Migrate that
        // value to effort routing while model routing remains permanently disabled.
        let legacyModelAutomatic = try values.decodeIfPresent(Bool.self, forKey: .modelAutomatic) ?? false
        effortAutomatic = try values.decodeIfPresent(Bool.self, forKey: .effortAutomatic) ?? legacyModelAutomatic
        configuredAt = try values.decodeIfPresent(Date.self, forKey: .configuredAt)
        desktopVerified = try values.decodeIfPresent(Bool.self, forKey: .desktopVerified) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(automatic, forKey: .automatic)
        try values.encode(effortAutomatic, forKey: .effortAutomatic)
        try values.encodeIfPresent(configuredAt, forKey: .configuredAt)
        try values.encode(desktopVerified, forKey: .desktopVerified)
    }

    func needsRestart(desktopLaunchedAt: Date?) -> Bool {
        guard !desktopVerified, let configuredAt else { return false }
        guard let desktopLaunchedAt else { return true }
        return desktopLaunchedAt <= configuredAt
    }
}
