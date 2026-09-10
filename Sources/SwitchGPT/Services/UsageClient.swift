import Foundation

struct UsageClient {
    func fetch(_ credential: Credential) async throws -> AccountUsage {
        try await AccountUsage.decode(request(credential, path: "usage"))
    }
    func fetchResetCredits(_ credential: Credential) async throws -> ResetCreditDetails {
        try await JSONDecoder().decode(ResetCreditDetails.self, from: request(credential, path: "rate-limit-reset-credits"))
    }
    func fetchProfileImage(_ credential: Credential) async throws -> Data? {
        struct ProfileResponse: Decodable {
            struct Profile: Decodable { let profile_picture_url: String? }
            let profile: Profile
        }
        let profile = try await JSONDecoder().decode(ProfileResponse.self, from: request(credential, path: "profiles/me"))
        guard let value = profile.profile.profile_picture_url,
              let url = URL(string: value), Self.isTrustedImageURL(url) else { return nil }
        return try await request(credential, url: url)
    }
    static func isTrustedImageURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "chatgpt.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }
    private func request(_ credential: Credential, path: String) async throws -> Data {
        try await request(credential, url: URL(string: "https://chatgpt.com/backend-api/wham/" + path)!)
    }
    private func request(_ credential: Credential, url: URL) async throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: credential.data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let accountID = tokens["account_id"] as? String else {
            throw SwitchError(message: L10n.text("credential_read"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex", forHTTPHeaderField: "OAI-App-Brand")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
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

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
