import Foundation

struct UsageClient: Sendable {
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self.sendRequest) {
        self.send = send
    }

    func fetch(_ credential: Credential) async throws -> AccountUsage {
        try await AccountUsage.decode(request(credential, path: "usage"))
    }
    @MainActor
    func fetchWithRefresh(_ initial: Credential, proactively: Bool,
                          renew: (Credential) async throws -> Credential) async throws -> (Credential, AccountUsage) {
        var credential = initial
        var renewed = false
        if proactively && credential.accessTokenExpiresSoon {
            credential = try await renew(credential)
            renewed = true
        }
        do { return (credential, try await fetch(credential)) }
        catch is UsageAuthenticationError where !renewed {
            credential = try await renew(credential)
            return (credential, try await fetch(credential))
        }
    }
    func fetchResetCredits(_ credential: Credential) async throws -> ResetCreditDetails {
        try await JSONDecoder().decode(ResetCreditDetails.self, from: request(credential, path: "rate-limit-reset-credits"))
    }
    func consumeResetCredit(_ credential: Credential, requestID: String) async throws -> ResetCreditResult {
        guard UUID(uuidString: requestID) != nil else { throw SwitchError(message: L10n.text("reset_storage_error")) }
        // Matches codex rust-v0.153.3 backend-client/src/client/rate_limit_resets.rs.
        let body = try JSONEncoder().encode(["redeem_request_id": requestID])
        let data = try await request(credential, path: "rate-limit-reset-credits/consume", method: "POST", body: body)
        return try JSONDecoder().decode(ResetCreditResult.self, from: data)
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
    private func request(_ credential: Credential, path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        try await request(credential, url: URL(string: "https://chatgpt.com/backend-api/wham/" + path)!, method: method, body: body)
    }
    private func request(_ credential: Credential, url: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        let credentials = try RelayCredentials(credential)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.timeoutInterval = 15
        request.setValue("Bearer " + credentials.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex", forHTTPHeaderField: "OAI-App-Brand")
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw SwitchError(message: L10n.text("usage_response")) }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 { throw UsageAuthenticationError() }
            if response.statusCode == 403 {
                throw SwitchError(message: L10n.text("auth_expired"))
            }
            throw SwitchError(message: L10n.format("usage_error", response.statusCode))
        }
        return data
    }

    private static func sendRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct UsageAuthenticationError: LocalizedError {
    var errorDescription: String? { L10n.text("auth_expired") }
}
