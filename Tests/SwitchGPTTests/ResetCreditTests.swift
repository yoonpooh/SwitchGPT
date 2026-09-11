import XCTest
@testable import SwitchGPT

@MainActor
final class ResetCreditTests: XCTestCase {
    func testConsumeUsesSelectedCredentialsAndBackendWireContract() async throws {
        let backend = ResetBackend(replies: [.json("{\"code\":\"reset\",\"windows_reset\":2}")])
        let client = client(backend)
        let requestID = UUID().uuidString
        let result = try await client.consumeResetCredit(credential("selected"), requestID: requestID)
        XCTAssertEqual(result.code, .reset)
        let requests = await backend.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer selected-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "selected-account")
        XCTAssertEqual(try requestBody(request), ["redeem_request_id": requestID])
    }

    func testSuccessfulRedemptionReadsBackQuotaAndClearsPendingAttempt() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ResetBackend(replies: [.json(usage()), .json("{\"code\":\"reset\"}"), .json(usage(available: 0, applicable: 0, used: 0))])
        let ledger = ResetCreditLedger(file: root.appendingPathComponent("attempts.json"))
        let credential = try credential("first")
        let receipt = try await ResetCreditService(client: client(backend), ledger: ledger).redeem(credential)
        XCTAssertEqual(receipt.result.code, .reset)
        XCTAssertTrue(receipt.reconciled)
        XCTAssertEqual(receipt.usage?.rateLimit?.primaryWindow?.remaining, 100)
        XCTAssertEqual(receipt.usage?.rateLimit?.secondaryWindow?.remaining, 100)
        XCTAssertEqual(receipt.usage?.rateLimitResetCredits?.availableCount, 0)
        XCTAssertNotNil(receipt.observedAt)
        XCTAssertFalse(ledger.hasPending(credential.id))
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
    }

    func testTimeoutAndRestartReuseRequestEvenWhenCreditWasAlreadyConsumed() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("attempts.json")
        let backend = ResetBackend(replies: [.json(usage()), .failure(.timedOut),
                                             .json("{\"code\":\"already_redeemed\"}"), .json(usage(available: 0, applicable: 0, used: 0))])
        let credential = try credential("first")
        let firstLedger = ResetCreditLedger(file: file)
        do {
            _ = try await ResetCreditService(client: client(backend), ledger: firstLedger).redeem(credential)
            XCTFail("Expected uncertain result")
        } catch { XCTAssertTrue(firstLedger.hasPending(credential.id)) }
        let restartedLedger = ResetCreditLedger(file: file)
        XCTAssertTrue(restartedLedger.hasPending(credential.id))
        let receipt = try await ResetCreditService(client: client(backend), ledger: restartedLedger).redeem(credential)
        XCTAssertEqual(receipt.result.code, .alreadyRedeemed)
        XCTAssertTrue(receipt.reconciled)
        XCTAssertFalse(restartedLedger.hasPending(credential.id))
        let requests = await backend.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "POST", "GET"])
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts[0].httpBody, posts[1].httpBody)
    }

    func testSuccessfulResetWithFailedReadBackKeepsSameRequestForReconciliation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ResetBackend(replies: [.json(usage()), .json("{\"code\":\"reset\"}"), .failure(.networkConnectionLost),
                                             .json("{\"code\":\"already_redeemed\"}"), .json(usage(available: 0, applicable: 0, used: 0))])
        let file = root.appendingPathComponent("attempts.json")
        let ledger = ResetCreditLedger(file: file)
        let credential = try credential("first")
        let first = try await ResetCreditService(client: client(backend), ledger: ledger).redeem(credential)
        XCTAssertEqual(first.result.code, .reset)
        XCTAssertFalse(first.reconciled)
        XCTAssertNil(first.usage)
        XCTAssertTrue(ledger.hasPending(credential.id))
        let second = try await ResetCreditService(client: client(backend), ledger: ResetCreditLedger(file: file)).redeem(credential)
        XCTAssertTrue(second.reconciled)
        let posts = await backend.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].httpBody, posts[1].httpBody)
    }

    func testIneligibleOrMissingCreditsNeverSendConsumeRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (offset, value) in [usage(available: 0, applicable: 0), usage(available: 1, applicable: 0), "{}"].enumerated() {
            let backend = ResetBackend(replies: [.json(value)])
            let ledger = ResetCreditLedger(file: root.appendingPathComponent("\(offset).json"))
            let credential = try credential("first")
            do {
                let receipt = try await ResetCreditService(client: client(backend), ledger: ledger).redeem(credential)
                XCTAssertEqual(receipt.result.code, offset == 0 ? .noCredit : .nothingToReset)
            } catch { XCTAssertEqual(offset, 2) }
            let requests = await backend.requests
            XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
            XCTAssertFalse(ledger.hasPending(credential.id))
        }
        XCTAssertTrue(try AccountUsage.decode(Data(usage(applicable: nil).utf8)).rateLimitResetCredits?.canUse == true)
    }

    func testHTTPAndUnknownResponseFailuresKeepAttemptWithoutRetryingAutomatically() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failures: [ResetBackend.Reply] = [.status(401), .status(429), .status(500), .json("not json"), .json("{\"code\":\"unknown\"}")]
        for (offset, failure) in failures.enumerated() {
            let backend = ResetBackend(replies: [.json(usage()), failure])
            let ledger = ResetCreditLedger(file: root.appendingPathComponent("\(offset).json"))
            let credential = try credential("first")
            do {
                _ = try await ResetCreditService(client: client(backend), ledger: ledger).redeem(credential)
                XCTFail("Expected failure")
            } catch { XCTAssertTrue(ledger.hasPending(credential.id)) }
            let requests = await backend.requests
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        }
    }

    func testLedgerPersistsOneKeyPerAccountAndPreservesOtherPendingAccounts() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("attempts.json")
        let first = ResetCreditLedger(file: file), second = ResetCreditLedger(file: file)
        let requestID = try first.begin("first-account")
        XCTAssertEqual(try second.begin("first-account"), requestID)
        let otherID = try second.begin("other-account")
        XCTAssertNotEqual(otherID, requestID)
        XCTAssertThrowsError(try first.finish("first-account", requestID: UUID().uuidString))
        try first.finish("first-account", requestID: requestID)
        let loaded = ResetCreditLedger(file: file)
        XCTAssertFalse(loaded.hasPending("first-account"))
        XCTAssertEqual(try loaded.pending("other-account"), otherID)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("other-account"))
    }

    func testCorruptOrUnwritableLedgerNeverSendsConsumeRequest() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("invalid ledger".utf8).write(to: corrupt)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        for file in [corrupt, blocker.appendingPathComponent("attempts.json")] {
            let backend = ResetBackend(replies: [.json(usage())])
            do {
                _ = try await ResetCreditService(client: client(backend), ledger: ResetCreditLedger(file: file)).redeem(credential("first"))
                XCTFail("Expected storage failure")
            } catch {
                let requests = await backend.requests
                XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
            }
        }
        XCTAssertEqual(try String(contentsOf: corrupt, encoding: .utf8), "invalid ledger")
    }

    func testAllBackendOutcomeCodesDecodeAndUnknownCodesFail() throws {
        for code in ["reset", "already_redeemed", "nothing_to_reset", "no_credit"] {
            let result = try JSONDecoder().decode(ResetCreditResult.self, from: Data("{\"code\":\"\(code)\"}".utf8))
            XCTAssertEqual(result.code.rawValue, code)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ResetCreditResult.self, from: Data("{\"outcome\":\"reset\"}".utf8)))
    }

    func testStoreWaitsForExistingRefreshRejectsDuplicateClickAndPreservesDesktopAuth() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try credential("first")
        let auth = root.appendingPathComponent("auth.json")
        try credential.data.write(to: auth)
        let backend = ResetBackend(replies: [.json(usage()), .json("{\"code\":\"reset\"}"), .json(usage(available: 0, applicable: 0, used: 0))])
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), usageClient: client(backend), session: CodexSession(home: root))
        let account = Account(id: credential.id, name: "Example", savedAt: .now)
        store.accounts = [account]
        store.currentID = "another-model-account"
        store.usages[account.id] = try AccountUsage.decode(Data(usage().utf8))
        store.usageUpdatedAt[account.id] = .now
        XCTAssertTrue(store.canUseReset(account))
        store.loadingUsage = true
        let first = Task { await store.useResetCredit(account) }
        await Task.yield()
        XCTAssertTrue(store.busy)
        XCTAssertEqual(store.resetInProgressID, account.id)
        await store.useResetCredit(account)
        let beforeRefreshFinished = await backend.requests
        XCTAssertTrue(beforeRefreshFinished.isEmpty)
        store.loadingUsage = false
        await first.value
        let requests = await backend.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertEqual(store.usages[account.id]?.rateLimit?.primaryWindow?.remaining, 100)
        XCTAssertEqual(store.resetMessages[account.id]?.succeeded, true)
        XCTAssertFalse(store.hasPendingReset(account))
        XCTAssertFalse(store.canUseReset(account))
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.resetInProgressID)
        XCTAssertEqual(try Data(contentsOf: auth), credential.data)
        XCTAssertEqual(store.currentID, "another-model-account")
    }

    func testPendingAttemptCanBeCheckedWithZeroCreditsAndStaleUsage() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let credential = try credential("first")
        let account = Account(id: credential.id, name: "Example", savedAt: .now)
        let ledger = ResetCreditLedger(file: root.appendingPathComponent("reset-credit-attempts.json"))
        _ = try ledger.begin(account.id)
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), session: CodexSession(home: root))
        store.accounts = [account]
        store.usages[account.id] = try AccountUsage.decode(Data(usage(available: 0, applicable: 0).utf8))
        store.usageUpdatedAt[account.id] = .distantPast
        XCTAssertTrue(store.hasPendingReset(account))
        XCTAssertTrue(store.canUseReset(account))
        store.loadingUsage = true
        XCTAssertFalse(store.canUseReset(account))
    }

    private func client(_ backend: ResetBackend) -> UsageClient {
        UsageClient { request in try await backend.send(request) }
    }

    private func requestBody(_ request: URLRequest) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
    }

    private func usage(available: Int = 1, applicable: Int? = 1, used: Int = 100) -> String {
        let applicableField = applicable.map { ",\"applicable_available_count\":\($0)" } ?? ""
        return "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(used),\"limit_window_seconds\":18000,\"reset_at\":2000000100},\"secondary_window\":{\"used_percent\":\(used),\"limit_window_seconds\":604800,\"reset_at\":2000000100}},\"rate_limit_reset_credits\":{\"available_count\":\(available)\(applicableField)}}"
    }

    private func credential(_ name: String) throws -> Credential {
        let claims = Data("{\"sub\":\"\(name)-subject\"}".utf8).base64EncodedString()
        return try Credential(data: Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"\(name)-account\",\"access_token\":\"\(name)-token\",\"refresh_token\":\"fake\",\"id_token\":\"header.\(claims).signature\"}}".utf8))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchGPT-reset-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private actor ResetBackend {
    enum Reply: Sendable {
        case json(String)
        case status(Int)
        case failure(URLError.Code)
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let status: Int, body: String
        switch replies.removeFirst() {
        case .json(let value): status = 200; body = value
        case .status(let value): status = value; body = "{\"error\":\"test failure\"}"
        case .failure(let code): throw URLError(code)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
