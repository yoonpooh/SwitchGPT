import Foundation

struct RoutingPreferences: Codable {
    var automatic = true
    /// Whether model requests may use the Jev intelligent model router.
    /// This is intentionally separate from account-order routing and defaults off.
    var modelAutomatic = false
    /// Whether Jev may choose the reasoning effort independently of the model.
    /// This is intentionally off for new installations. Older preferences that only
    /// stored `modelAutomatic` inherit that value during decoding below.
    var effortAutomatic = false
    var configuredAt: Date?
    var desktopVerified = false

    private enum CodingKeys: String, CodingKey {
        case automatic
        case modelAutomatic
        case effortAutomatic
        case configuredAt
        case desktopVerified
    }

    init(automatic: Bool = true, modelAutomatic: Bool = false, effortAutomatic: Bool = false,
         configuredAt: Date? = nil, desktopVerified: Bool = false) {
        self.automatic = automatic
        self.modelAutomatic = modelAutomatic
        self.effortAutomatic = effortAutomatic
        self.configuredAt = configuredAt
        self.desktopVerified = desktopVerified
    }

    /// Keep preferences written by older SwitchGPT versions readable. Stored
    /// defaults are not used by synthesized Decodable when a key is absent.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? true
        modelAutomatic = try values.decodeIfPresent(Bool.self, forKey: .modelAutomatic) ?? false
        // Prior versions had one Jev switch controlling both choices. Preserve that
        // behavior when reading their files, while keeping effort routing opt-in for
        // newly created preferences.
        effortAutomatic = try values.decodeIfPresent(Bool.self, forKey: .effortAutomatic) ?? modelAutomatic
        configuredAt = try values.decodeIfPresent(Date.self, forKey: .configuredAt)
        desktopVerified = try values.decodeIfPresent(Bool.self, forKey: .desktopVerified) ?? false
    }

    func needsRestart(desktopLaunchedAt: Date?) -> Bool {
        guard !desktopVerified, let configuredAt else { return false }
        guard let desktopLaunchedAt else { return true }
        return desktopLaunchedAt <= configuredAt
    }
}
