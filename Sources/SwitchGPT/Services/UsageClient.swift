import Foundation

struct UsageClient {
    func fetch(_ credential: Credential) async throws -> AccountUsage {
        try await AccountUsage.decode(request(credential, path: "usage"))
    }
    func fetchResetCredits(_ credential: Credential) async throws -> ResetCreditDetails {
        try await JSONDecoder().decode(ResetCreditDetails.self, from: request(credential, path: "rate-limit-reset-credits"))
    }
    private func request(_ credential: Credential, path: String) async throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: credential.data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let accountID = tokens["account_id"] as? String else {
            throw SwitchError(message: L10n.text("credential_read"))
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/" + path)!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex", forHTTPHeaderField: "OAI-App-Brand")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SwitchError(message: L10n.text("usage_response")) }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw SwitchError(message: L10n.text("auth_expired"))
            }
            throw SwitchError(message: L10n.format("usage_error", response.statusCode))
        }
        return data
    }
}
