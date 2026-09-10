import Foundation

struct RoutingPreferences: Codable {
    var automatic = true
    var configuredAt: Date?
    var desktopVerified = false

    func needsRestart(desktopLaunchedAt: Date?) -> Bool {
        guard !desktopVerified, let configuredAt else { return false }
        guard let desktopLaunchedAt else { return true }
        return desktopLaunchedAt <= configuredAt
    }
}
