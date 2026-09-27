import XCTest
@testable import SwitchGPT

final class ClaudeUsageTests: XCTestCase {
    // Trimmed from the rate_limits of a real get_usage answer.
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

    func testPlanBadgeNamesClaudeAndChatGPTPlans() {
        XCTAssertEqual(PlanBadge.title("Max 20x"), "Max 20x")
        XCTAssertEqual(PlanBadge.title("prolite"), "Pro")
        XCTAssertEqual(PlanBadge.title("pro"), "Pro 20x")
        XCTAssertEqual(PlanBadge.title("plus"), "Plus")
        XCTAssertEqual(PlanBadge.title("max"), "Max")
    }

    func testUsageComesFromClaudeCodeAnswers() throws {
        let account = #"{"account":{"email":"me@example.com","subscriptionType":"Claude Max","organization":"Org"},"models":[]}"#
        let usage = #"{"subscription_type":"max","rate_limits_available":true,"rate_limits":"# + usageBody + "}"
        let result = try ClaudeUsageClient(answers: { (Data(account.utf8), Data(usage.utf8)) }).fetch()
        XCTAssertEqual(result.email, "me@example.com")
        XCTAssertEqual(result.plan, "max")
        XCTAssertEqual(result.usage.meters.map(\.remaining), [92, 75, 100])
    }

    func testAPIKeyLoginHasNoLimitsAndFailuresAreReported() async throws {
        let apiKey = ClaudeUsageClient(answers: { (Data(#"{"account":{"email":"me@example.com"}}"#.utf8),
                                                    Data(#"{"rate_limits_available":false,"rate_limits":null}"#.utf8)) })
        let result = try apiKey.fetch()
        XCTAssertNil(result.plan)
        XCTAssertTrue(result.usage.meters.isEmpty)
        let signedOut = ClaudeUsageClient(answers: { (Data(#"{"account":{}}"#.utf8), Data("{}".utf8)) })
        guard case .failure(let error) = await signedOut.load() else { return XCTFail("Expected failure") }
        XCTAssertEqual(error.localizedDescription, L10n.text("claude_signed_out"))
        let refused = ClaudeUsageClient(answers: { throw SwitchError(message: "Claude Code refused get_usage") })
        guard case .failure(let failure) = await refused.load() else { return XCTFail("Expected failure") }
        XCTAssertEqual(failure.localizedDescription, "Claude Code refused get_usage")
    }

    func testControlRequestsShareOneProcessAndKeepTheirOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("claude")
        // Answers arrive in reverse order.
        let script = """
        #!/usr/bin/python3
        import json, sys
        requests = [json.loads(line) for line in sys.stdin if line.strip()]
        for request in reversed(requests):
            answer = {'subtype': request['request']['subtype']}
            print(json.dumps({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': request['request_id'], 'response': answer}}))
        """
        FileManager.default.createFile(atPath: executable.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let answers = try ClaudeModelDiscovery.controls(executable, subtypes: ["initialize", "get_usage"])
        XCTAssertEqual(answers.map { $0["subtype"] as? String }, ["initialize", "get_usage"])
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
}
