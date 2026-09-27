import Foundation

/// The account and plan limits of the Claude Code CLI signed in on this Mac, as Claude Code itself reports them.
/// SwitchGPT reads no Anthropic credentials and calls no Anthropic endpoint, and asking makes no model call.
struct ClaudeUsageClient: Sendable {
    /// Claude Code's answers to its initialize and get_usage control requests, as JSON.
    private let answers: @Sendable () throws -> (account: Data, usage: Data)

    init(answers: @escaping @Sendable () throws -> (account: Data, usage: Data) = Self.ask) {
        self.answers = answers
    }

    func load() async -> Result<ClaudeAccountUsage, any Error> {
        // Claude Code takes a second or two to answer, so it is never asked on the calling thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: Result { try fetch() }) }
        }
    }

    func fetch() throws -> ClaudeAccountUsage {
        let (account, usage) = try answers()
        struct Initialized: Decodable {
            struct Account: Decodable { let email: String?; let subscriptionType: String? }
            let account: Account?
        }
        struct Reported: Decodable { let subscriptionType: String?; let rateLimits: ClaudeUsage? }
        guard let signedIn = try JSONDecoder().decode(Initialized.self, from: account).account,
              signedIn.email != nil || signedIn.subscriptionType != nil else {
            throw SwitchError(message: L10n.text("claude_signed_out"))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reported = try decoder.decode(Reported.self, from: usage)
        // A login with an API key has no plan limits. initialize names the plan for display ("Claude Max"); get_usage gives its id.
        return ClaudeAccountUsage(usage: reported.rateLimits ?? ClaudeUsage(limits: []),
                                  plan: reported.subscriptionType ?? signedIn.subscriptionType, email: signedIn.email)
    }

    static func ask() throws -> (account: Data, usage: Data) {
        guard let executable = ClaudeCLI.locate() else { throw SwitchError(message: L10n.text("claude_signed_out")) }
        do {
            let answers = try ClaudeModelDiscovery.controls(executable, subtypes: ["initialize", "get_usage"])
            return (ClaudeBridge.encode(answers[0]), ClaudeBridge.encode(answers[1]))
        } catch let failure as ClaudeFailure {
            throw SwitchError(message: failure.message)
        }
    }
}
