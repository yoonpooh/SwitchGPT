import Foundation

/// The OAuth login Claude Code keeps in the keychain. SwitchGPT only reads it: Claude Code owns its refresh.
struct ClaudeCredential: Sendable {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?

    init(data: Data) throws {
        struct Stored: Decodable {
            struct OAuth: Decodable { let accessToken: String; let expiresAt: Double?; let subscriptionType: String?; let rateLimitTier: String? }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = try? JSONDecoder().decode(Stored.self, from: data).claudeAiOauth, !oauth.accessToken.isEmpty else {
            throw SwitchError(message: L10n.text("claude_signed_out"))
        }
        accessToken = oauth.accessToken
        expiresAt = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        subscriptionType = oauth.subscriptionType
        rateLimitTier = oauth.rateLimitTier
    }

    /// "max" with tier "default_claude_max_20x" is "Max 20x"; any other plan is shown as Claude Code names it.
    var plan: String? {
        if let tier = rateLimitTier, let range = tier.range(of: #"max_[0-9]+x$"#, options: .regularExpression) {
            return "Max " + tier[range].dropFirst("max_".count)
        }
        return subscriptionType
    }

    static func read() throws -> ClaudeCredential {
        // Reading through /usr/bin/security, as Claude Code does, avoids a keychain prompt after every SwitchGPT rebuild.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SwitchError(message: L10n.text("claude_signed_out")) }
        return try ClaudeCredential(data: data)
    }
}

struct ClaudeUsageClient: Sendable {
    private let credential: @Sendable () throws -> ClaudeCredential
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(credential: @escaping @Sendable () throws -> ClaudeCredential = ClaudeCredential.read,
         send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self.sendRequest) {
        self.credential = credential
        self.send = send
    }

    func load(now: Date = .now) async -> Result<ClaudeAccountUsage, any Error> {
        do { return .success(try await fetch(now: now)) } catch { return .failure(error) }
    }

    func fetch(now: Date = .now) async throws -> ClaudeAccountUsage {
        let credential = try credential()
        // Never renew here: rotating the refresh token would sign Claude Code out. It renews on its next run.
        if let expiry = credential.expiresAt, expiry <= now { throw SwitchError(message: L10n.text("claude_token_expired")) }
        let usage = try ClaudeUsage.decode(await request(credential, path: "usage"))
        struct Profile: Decodable {
            struct Account: Decodable { let email: String? }
            let account: Account?
        }
        let email = try? JSONDecoder().decode(Profile.self, from: await request(credential, path: "profile")).account?.email
        return ClaudeAccountUsage(usage: usage, plan: credential.plan, email: email)
    }

    private func request(_ credential: ClaudeCredential, path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/" + path)!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw SwitchError(message: L10n.text("usage_response")) }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 { throw SwitchError(message: L10n.text("claude_token_expired")) }
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
