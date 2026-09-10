import Foundation
import CryptoKit

struct RelayCredentials: Sendable {
    let accessToken: String
    let accountID: String
    let fingerprint: String

    init(_ credential: Credential) throws {
        guard let object = try JSONSerialization.jsonObject(with: credential.data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              let accountID = tokens["account_id"] as? String,
              !accessToken.contains("\r"), !accessToken.contains("\n"),
              !accountID.contains("\r"), !accountID.contains("\n") else {
            throw SwitchError(message: L10n.text("credential_read"))
        }
        self.accessToken = accessToken
        self.accountID = accountID
        fingerprint = Self.fingerprint(credential.id)
    }

    static func fingerprint(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
