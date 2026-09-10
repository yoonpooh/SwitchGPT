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
        if original.hasPrefix(block) { return original }
        // Do not silently replace an existing proxy, or rewrite a user-edited managed block.
        guard !original.contains(begin), !original.contains(end) else {
            throw SwitchError(message: L10n.text("routing_conflict"))
        }
        for line in original.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("[") { break }
            if text.hasPrefix("#") { continue }
            let key = text.components(separatedBy: "=")[0].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "openai_base_url" {
                throw SwitchError(message: L10n.text("routing_conflict"))
            }
        }
        return block + original
    }
}
