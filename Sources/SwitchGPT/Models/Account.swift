import Foundation

struct SwitchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Account: Codable, Identifiable {
    let id: String
    var name: String
    var savedAt: Date
    var nickname: String?
}

struct Credential {
    let email: String?
    let data: Data
    let id: String
    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["auth_mode"] as? String == "chatgpt",
              let tokens = object["tokens"] as? [String: Any],
              let id = tokens["account_id"] as? String, !id.isEmpty,
              ["access_token", "refresh_token", "id_token"].allSatisfy({ !(tokens[$0] as? String ?? "").isEmpty }) else {
            throw SwitchError(message: L10n.text("credential_missing"))
        }
        self.data = data
        guard let token = tokens["id_token"] as? String,
              token.split(separator: ".").count == 3 else {
            throw SwitchError(message: L10n.text("identity_read"))
        }
        var payload = String(token.split(separator: ".")[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload),
              let claims = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw SwitchError(message: L10n.text("identity_read"))
        }
        self.email = claims["email"] as? String
        self.id = id + "|" + subject
    }
}
