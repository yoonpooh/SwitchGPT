import XCTest
@testable import SwitchGPT

final class ClaudeUsageTests: XCTestCase {
    // Trimmed from a real api/oauth/usage response.
    let usageBody = """
    {"five_hour":{"utilization":8.0,"resets_at":"2026-09-27T18:09:59.991290+00:00"},"seven_day":null,
     "limits":[
      {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-09-30T22:00:00+00:00",
       "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false},
      {"kind":"session","group":"session","percent":8,"severity":"normal","resets_at":"2026-09-27T18:09:59.991290+00:00","scope":null,"is_active":false},
      {"kind":"future_kind","group":"weekly","percent":50,"severity":"normal","resets_at":null,"scope":null,"is_active":false},
      {"kind":"weekly_all","group":"weekly","percent":25,"severity":"normal","resets_at":"2026-09-30T21:59:59.991313+00:00","scope":null,"is_active":true},
      {"kind":"weekly_scoped","group":"weekly","percent":10,"severity":"normal","resets_at":null,"scope":null,"is_active":false}
     ]}
    """

    func testMetersFollowSessionWeeklyAndModelOrder() throws {
        let meters = try ClaudeUsage.decode(Data(usageBody.utf8)).meters
        XCTAssertEqual(meters.map(\.label), [L10n.format("hours", 5), L10n.text("weekly"), L10n.format("claude_scoped_weekly", "Fable")])
        XCTAssertEqual(meters.map(\.remaining), [92, 75, 100])
        XCTAssertEqual(meters[0].resetDate?.timeIntervalSince1970, 1790532599)
        XCTAssertEqual(meters[2].resetDate?.timeIntervalSince1970, 1790805600)
    }

    func testDateParsingAcceptsFractionsAndRejectsGarbage() {
        XCTAssertEqual(ClaudeUsage.date("2026-09-30T21:59:59.991313+00:00")?.timeIntervalSince1970, 1790805599)
        XCTAssertEqual(ClaudeUsage.date("2026-09-30T22:00:00Z")?.timeIntervalSince1970, 1790805600)
        XCTAssertNil(ClaudeUsage.date("soon"))
    }

    func testCredentialRequiresClaudeOAuthLogin() throws {
        let stored = #"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":1790532599000,"subscriptionType":"max"}}"#
        let credential = try ClaudeCredential(data: Data((stored + "\n").utf8))
        XCTAssertEqual(credential.accessToken, "token")
        XCTAssertEqual(credential.expiresAt?.timeIntervalSince1970, 1790532599)
        XCTAssertEqual(credential.subscriptionType, "max")
        XCTAssertEqual(credential.plan, "max")
        let tiered = #"{"claudeAiOauth":{"accessToken":"t","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        XCTAssertEqual(try ClaudeCredential(data: Data(tiered.utf8)).plan, "Max 20x")
        XCTAssertEqual(PlanBadge.title("Max 20x"), "Max 20x")
        XCTAssertEqual(PlanBadge.title("prolite"), "Pro")
        XCTAssertEqual(PlanBadge.title("pro"), "Pro 20x")
        XCTAssertEqual(PlanBadge.title("plus"), "Plus")
        XCTAssertEqual(PlanBadge.title("max"), "Max")
        XCTAssertThrowsError(try ClaudeCredential(data: Data("{}".utf8)))
        XCTAssertThrowsError(try ClaudeCredential(data: Data()))
    }

    func testFetchSendsOAuthHeadersAndReadsProfile() async throws {
        let backend = ClaudeBackend(responses: [(200, usageBody), (200, #"{"account":{"email":"me@example.com"}}"#)])
        let client = ClaudeUsageClient(credential: { try Self.credential(expiresAt: 2_000_000_000_000) },
                                       send: { try await backend.send($0) })
        let result = try await client.fetch(now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(result.email, "me@example.com")
        XCTAssertEqual(result.plan, "max")
        XCTAssertEqual(result.usage.meters.count, 3)
        let requests = await backend.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, ["https://api.anthropic.com/api/oauth/usage", "https://api.anthropic.com/api/oauth/profile"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func testProfileFailureStillShowsUsage() async throws {
        let backend = ClaudeBackend(responses: [(200, usageBody), (500, "{}")])
        let client = ClaudeUsageClient(credential: { try Self.credential(expiresAt: nil) }, send: { try await backend.send($0) })
        let result = try await client.fetch()
        XCTAssertNil(result.email)
        XCTAssertEqual(result.usage.meters.count, 3)
    }

    func testExpiredTokenIsNeverSentOrRenewed() async throws {
        let backend = ClaudeBackend(responses: [])
        let client = ClaudeUsageClient(credential: { try Self.credential(expiresAt: 1_000) }, send: { try await backend.send($0) })
        let result = await client.load(now: Date(timeIntervalSince1970: 1_790_000_000))
        guard case .failure(let error) = result else { return XCTFail("Expected failure") }
        XCTAssertEqual(error.localizedDescription, L10n.text("claude_token_expired"))
        let requests = await backend.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTPErrorsAreReported() async throws {
        for (status, message) in [(401, L10n.text("claude_token_expired")), (429, L10n.format("usage_error", 429))] {
            let backend = ClaudeBackend(responses: [(status, "{}")])
            let client = ClaudeUsageClient(credential: { try Self.credential(expiresAt: nil) }, send: { try await backend.send($0) })
            do { _ = try await client.fetch(); XCTFail("Expected error") }
            catch { XCTAssertEqual(error.localizedDescription, message) }
            let requests = await backend.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    @MainActor func testClaudeNicknamePersistsAndEmptyNameRestoresEmail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("accounts.json")
        let store = AccountStore(index: index)
        store.claudeUsage = ClaudeAccountUsage(usage: ClaudeUsage(limits: []), plan: "max", email: "me@example.com")
        XCTAssertEqual(store.claudeDisplayName, "me@example.com")
        XCTAssertTrue(store.renameClaude(to: "  Work  "))
        XCTAssertEqual(store.claudeDisplayName, "Work")
        XCTAssertEqual(AccountStore(index: index).claudeNickname, "Work")
        XCTAssertTrue(store.renameClaude(to: " \n "))
        XCTAssertEqual(store.claudeDisplayName, "me@example.com")
        XCTAssertNil(AccountStore(index: index).claudeNickname)
        store.busy = true
        XCTAssertFalse(store.renameClaude(to: "Blocked"))
    }

    static func credential(expiresAt: Double?) throws -> ClaudeCredential {
        var oauth: [String: Any] = ["accessToken": "token", "subscriptionType": "max"]
        oauth["expiresAt"] = expiresAt
        return try ClaudeCredential(data: JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]))
    }
}

actor ClaudeBackend {
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    init(responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
