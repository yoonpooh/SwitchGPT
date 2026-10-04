import Foundation

/// Changes only the built-in model endpoint. Desktop/Remote auth stays in auth.json.
struct RoutingConfiguration {
    static let port: UInt16 = 19565
    static let begin = "# BEGIN SwitchGPT model routing"
    static let end = "# END SwitchGPT model routing"
    let home: URL

    var endpoint: String { "http://127.0.0.1:\(Self.port)/backend-api/codex" }

    func install() throws -> Bool {
        let file = home.appendingPathComponent("config.toml")
        let original = try String(contentsOf: file, encoding: .utf8)
        let updated = try Self.addRouting(to: original, endpoint: endpoint)
        guard updated != original else { return false }
        try updated.write(to: file, atomically: true, encoding: .utf8)
        return true
    }

    func removeInstalledBlock() throws {
        let file = home.appendingPathComponent("config.toml")
        let original = try String(contentsOf: file, encoding: .utf8)
        let block = "\(Self.begin)\nopenai_base_url = \"\(endpoint)\"\n\(Self.end)\n"
        guard original.hasPrefix(block) else { throw SwitchError(message: L10n.text("routing_conflict")) }
        try String(original.dropFirst(block.count)).write(to: file, atomically: true, encoding: .utf8)
    }

    static func addRouting(to original: String, endpoint: String) throws -> String {
        let block = "\(begin)\nopenai_base_url = \"\(endpoint)\"\n\(end)\n"
        if original.hasPrefix(block) {
            guard topLevelKeys(original).filter({ $0 == "openai_base_url" }).count == 1 else {
                throw SwitchError(message: L10n.text("routing_conflict"))
            }
            return original
        }
        // Do not silently replace an existing proxy, or rewrite a user-edited managed block.
        guard !original.contains(begin), !original.contains(end) else {
            throw SwitchError(message: L10n.text("routing_conflict"))
        }
        if topLevelKeys(original).contains("openai_base_url") {
            throw SwitchError(message: L10n.text("routing_conflict"))
        }
        return block + original
    }

    /// A model_catalog_json override replaces the model list SwitchGPT adds the Claude models to.
    var overridesCatalog: Bool {
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return false }
        return Self.topLevelKeys(text).contains("model_catalog_json")
    }

    static func topLevelKeys(_ config: String) -> [String] {
        TOMLTopLevel.assignments(in: config).map(\.key)
    }
}
