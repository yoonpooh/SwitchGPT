import Foundation

/// Uses the same OAuth client and JSON refresh grant as openai/codex login/auth/manager.rs.
struct TokenRefreshClient: Sendable {
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    init(send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self.sendRequest) {
        self.send = send
    }

    func refresh(_ credential: Credential) async throws -> Credential {
        var object = try JSONSerialization.jsonObject(with: credential.data) as! [String: Any]
        var tokens = object["tokens"] as! [String: Any]
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "refresh_token": tokens["refresh_token"] as! String
        ])
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else {
            throw SwitchError(message: L10n.text("usage_response"))
        }
        guard response.statusCode == 200 else {
            // Do not expose provider response bodies, which can contain credentials.
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = body?["error"]
            let code = (error as? String) ?? (error as? [String: Any])?["code"] as? String
            if response.statusCode == 401 || ["invalid_grant", "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"].contains(code ?? "") {
                throw RefreshFailure.reauthenticationRequired
            }
            throw SwitchError(message: L10n.format("usage_error", response.statusCode))
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = result["access_token"] as? String, !access.isEmpty else {
            throw SwitchError(message: L10n.text("usage_response"))
        }
        tokens["access_token"] = access
        for key in ["refresh_token", "id_token"] {
            if let value = result[key] as? String {
                guard !value.isEmpty else { throw SwitchError(message: L10n.text("usage_response")) }
                tokens[key] = value
            }
        }
        object["tokens"] = tokens
        object["last_refresh"] = ISO8601DateFormatter().string(from: .now)
        let refreshed = try Credential(data: JSONSerialization.data(withJSONObject: object))
        guard refreshed.id == credential.id else { throw SwitchError(message: L10n.text("account_mismatch")) }
        return refreshed
    }

    private static func sendRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

enum RefreshFailure: LocalizedError {
    case reauthenticationRequired
    var errorDescription: String? { L10n.text("auth_expired") }
}

extension Credential {
    var accessTokenExpiresSoon: Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String else { return false }
        let parts = access.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let expiry = claims["exp"] as? Double else { return false }
        return expiry <= Date.now.addingTimeInterval(120).timeIntervalSince1970
    }
}
