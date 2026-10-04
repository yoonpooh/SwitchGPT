import XCTest
@testable import SwitchGPT

final class ReviewRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func credential(_ name: String = "synthetic") throws -> Credential {
        let payload = Data("{\"sub\":\"\(name)\"}".utf8).base64EncodedString()
        return try Credential(data: JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
            "account_id": name, "access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "id_token": "h.\(payload).s"]]))
    }

    func testRoutingDetectsEndpointAfterMultilineInstructionsAndArrays() throws {
        for delimiter in ["\"\"\"", "'''"] {
            let config = "developer_instructions = \(delimiter)\n[Example]\nopenai_base_url = 'an example'\n\(delimiter)\n"
                + "values = [\n'[another example]', # ignored comment\n'last'\n]\n"
                + "'openai_base_url' = 'https://existing.example' # keep\nmodel_catalog_json = 'catalog.json'\n[profile]\nignored = true\n"
            XCTAssertEqual(RoutingConfiguration.topLevelKeys(config), ["developer_instructions", "values", "openai_base_url", "model_catalog_json"])
            XCTAssertThrowsError(try RoutingConfiguration.addRouting(to: config, endpoint: "http://127.0.0.1:19565/backend-api/codex"))
        }
        let quoted = "developer_instructions = \"[example] \\\"quoted\\\" # text\"\nmodel_verbosity = 'HIGH' # comment\n"
        XCTAssertEqual(ClaudeBridge.configuredVerbosity(quoted), "high")
        let managed = try RoutingConfiguration.addRouting(to: "", endpoint: "local")
        XCTAssertThrowsError(try RoutingConfiguration.addRouting(to: managed + "openai_base_url = 'duplicate'\n", endpoint: "local"))
    }

    func testTOMLUnicodeEscapedKeysStillDetectExistingEndpoints() throws {
        for key in [#""openai\U0000005fbase_url""#, #""\U0000006fpenai_base_url""#] {
            let config = key + " = 'https://existing.example'\n"
            XCTAssertEqual(RoutingConfiguration.topLevelKeys(config), ["openai_base_url"])
            XCTAssertThrowsError(try RoutingConfiguration.addRouting(to: config, endpoint: "local"))
            let managed = try RoutingConfiguration.addRouting(to: "", endpoint: "local")
            XCTAssertThrowsError(try RoutingConfiguration.addRouting(to: managed + config, endpoint: "local"))
        }
        XCTAssertEqual(TOMLTopLevel.string(#""\b\t\n\f\r\"\\\u0041\U0001F600""#), "\u{8}\t\n\u{c}\r\"\\A😀")
        for invalid in [#""\U00110000""#, #""\uD800""#, #""\U0000005""#, #""\q""#] {
            XCTAssertNil(TOMLTopLevel.string(invalid))
        }
    }

    func testControlDeadlineKillsChildAfterParentImmediatelyExits() throws {
        let root = try directory()
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
        outside.arguments = ["20"]
        try outside.run()
        defer {
            if outside.isRunning { outside.terminate() }
            outside.waitUntilExit()
            for attempt in 0..<3 {
                if let text = try? String(contentsOf: root.appendingPathComponent("child-\(attempt)"), encoding: .utf8),
                   let pid = Int32(text) { kill(pid, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        for attempt in 0..<3 {
            let executable = root.appendingPathComponent("fake-claude-\(attempt)")
            let marker = root.appendingPathComponent("child-\(attempt)")
            let script = "#!/usr/bin/python3\nimport os, signal, time\ntime.sleep(0.025)\npid = os.fork()\nif pid == 0:\n signal.signal(signal.SIGTERM, signal.SIG_IGN)\n open('\(marker.path)', 'w').write(str(os.getpid()))\n time.sleep(20)\nelse:\n os._exit(0)\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let began = ContinuousClock.now
            XCTAssertThrowsError(try ClaudeModelDiscovery.controls(executable, subtypes: ["initialize"], timeout: 1)) { error in
                XCTAssertEqual((error as? ClaudeFailure)?.status, 504)
            }
            XCTAssertLessThan(began.duration(to: .now), .seconds(3))
            let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
            for _ in 0..<100 { if kill(pid, 0) != 0 { break }; usleep(10_000) }
            XCTAssertNotEqual(kill(pid, 0), 0, "Orphan from attempt \(attempt) survived")
            XCTAssertTrue(outside.isRunning, "Cleanup must not signal another process group")
        }
    }

    func testControlNormalLaunchPreservesEnvironmentDirectoryAndInput() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("probe")
        try "#!/bin/sh\nIFS= read -r input\nprintf '%s|%s|%s|%s' \"$REVIEW_PROBE_ENV\" \"$PWD\" \"$1\" \"$input\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["argument with spaces"]
        process.environment = ["REVIEW_PROBE_ENV": "synthetic"]
        process.currentDirectoryURL = root
        process.standardError = FileHandle.nullDevice
        let output = try ControlledProcess.capture(process, input: Data("payload\n".utf8), timeout: 2)
        let fields = String(decoding: output, as: UTF8.self).components(separatedBy: "|")
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields.first, "synthetic")
        if fields.count == 4 {
            XCTAssertEqual(URL(fileURLWithPath: fields[1]).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
            XCTAssertEqual(fields[2], "argument with spaces")
            XCTAssertEqual(fields[3], "payload")
        }
    }

    func testControlDeadlineKillsProcessThatIgnoresTermination() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-claude")
        let marker = root.appendingPathComponent("pid")
        let script = "#!/usr/bin/python3\nimport os, signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nopen('\(marker.path)', 'w').write(str(os.getpid()))\ntime.sleep(10)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let began = ContinuousClock.now
        XCTAssertThrowsError(try ClaudeModelDiscovery.controls(executable, subtypes: ["initialize"], timeout: 1)) { error in
            XCTAssertEqual((error as? ClaudeFailure)?.status, 504)
        }
        XCTAssertLessThan(began.duration(to: .now), .seconds(3))
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        for _ in 0..<100 { if kill(pid, 0) != 0 { break }; usleep(10_000) }
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testControlDeadlineClosesPipeInheritedByAChild() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-claude")
        let marker = root.appendingPathComponent("child")
        let script = "#!/usr/bin/python3\nimport os, signal, time\npid = os.fork()\nif pid == 0:\n signal.signal(signal.SIGTERM, signal.SIG_IGN)\n time.sleep(10)\nelse:\n open('\(marker.path)', 'w').write(str(pid))\n time.sleep(0.3)\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let began = ContinuousClock.now
        XCTAssertThrowsError(try ClaudeModelDiscovery.controls(executable, subtypes: ["initialize"], timeout: 1)) { error in
            XCTAssertEqual((error as? ClaudeFailure)?.status, 504)
        }
        XCTAssertLessThan(began.duration(to: .now), .seconds(3))
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        for _ in 0..<100 { if kill(pid, 0) != 0 { break }; usleep(10_000) }
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testControlCancellationIsBounded() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let cancellation = ProcessCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
        let began = ContinuousClock.now
        XCTAssertThrowsError(try ControlledProcess.capture(process, input: Data(), timeout: 10, cancellation: cancellation)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertLessThan(began.duration(to: .now), .seconds(2))
    }

    @MainActor func testFailedIndexWritePreservesAccountAndCredential() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try credential()
        let account = Account(id: saved.id, name: "Synthetic", savedAt: .now)
        let index = root.appendingPathComponent("accounts.json")
        try JSONEncoder().encode([account]).write(to: index)
        let vault = ReviewMemoryVault([saved.id: saved.data])
        let store = AccountStore(index: index, session: CodexSession(home: root), vault: vault)
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        store.remove(account)
        XCTAssertFalse(store.message.isEmpty)
        XCTAssertEqual(vault.data[saved.id], saved.data)
        XCTAssertEqual(store.accounts.map(\.id), [account.id])
        XCTAssertEqual(vault.removals, 0)
    }

    @MainActor func testFailedVaultDeletionRestoresSavedIndex() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try credential()
        let account = Account(id: saved.id, name: "Synthetic", savedAt: .now)
        let index = root.appendingPathComponent("accounts.json")
        let original = try JSONEncoder().encode([account])
        try original.write(to: index)
        let vault = ReviewMemoryVault([saved.id: saved.data])
        vault.rejectDeletion = true
        let store = AccountStore(index: index, session: CodexSession(home: root), vault: vault)
        store.remove(account)
        XCTAssertFalse(store.message.isEmpty)
        XCTAssertEqual(vault.data[saved.id], saved.data)
        XCTAssertEqual(store.accounts.map(\.id), [account.id])
        XCTAssertEqual(try JSONDecoder().decode([Account].self, from: Data(contentsOf: index)).map(\.id), [account.id])
        // After the storage failure clears, a normal deletion still updates both stores.
        vault.rejectDeletion = false
        store.remove(account)
        XCTAssertTrue(store.message.isEmpty)
        XCTAssertNil(vault.data[saved.id])
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode([Account].self, from: Data(contentsOf: index)).isEmpty)
    }

    @MainActor func testUsageFailureIsVisibleAndPreservesLastGoodReading() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = try credential()
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"),
            usageClient: UsageClient(send: { request in
                (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            }), claudeUsageClient: ClaudeUsageClient(answers: { throw SwitchError(message: "synthetic") }),
            session: CodexSession(home: root), vault: ReviewMemoryVault([saved.id: saved.data]))
        let account = Account(id: saved.id, name: "Synthetic", savedAt: .now)
        store.accounts = [account]
        let now = Date()
        store.usages[saved.id] = try AccountUsage.decode(Data(#"{"rate_limit":{"allowed":true,"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":9999999999}}}"#.utf8))
        store.usageUpdatedAt[saved.id] = now
        XCTAssertNil(store.usageErrors[saved.id])
        await store.refreshUsage()
        XCTAssertEqual(store.usages[saved.id]?.rateLimit?.primaryWindow?.remaining, 90)
        XCTAssertEqual(store.usageUpdatedAt[saved.id], now)
        XCTAssertNotNil(store.usageErrors[saved.id])
    }

    func testOversizedImagesAreSkippedAndOriginalNumbersRemainExplicit() throws {
        let small = "data:image/png;base64,AAAA"
        let large = "data:image/png;base64," + String(repeating: "A", count: ClaudeBridge.promptImageBytes + 4)
        let content = ClaudeBridge.promptContent(["input": [["role": "user", "content": [
            ["type": "input_image", "image_url": small], ["type": "input_image", "image_url": large],
            ["type": "input_image", "image_url": small]]]]], compacting: false)
        let images = content.filter { $0["type"] as? String == "image" }
        XCTAssertEqual(images.count, 2)
        let labels = content.compactMap { $0["text"] as? String }
        XCTAssertTrue(labels.contains("Attached image 1:"))
        XCTAssertTrue(labels.contains("Attached image 3:"))
        XCTAssertTrue(labels.contains { $0.contains("Attached images 1, 3 of 3 follow") })
        XCTAssertEqual(ClaudeBridge.latestImages([["data": "small"], ["data": String(repeating: "A", count: ClaudeBridge.promptImageBytes + 1)]], count: 20).count, 1)
    }

    func testDeletionExcludesFutureSelectionsAndCannotRemoveTheActiveAccount() throws {
        let first = try RelayCredentials(credential("first"))
        let second = try RelayCredentials(credential("second"))
        let router = AccountRouter()
        router.select(second)
        let candidates = [first, second].map { RoutingCandidate(credentials: $0, availability: .available, observedAt: .now) }
        router.update(candidates, automatic: true)
        XCTAssertTrue(router.beginRemoving(first.fingerprint))
        XCTAssertEqual(router.resolve()?.fingerprint, second.fingerprint)
        XCTAssertFalse(router.beginRemoving(second.fingerprint))
        // A failed store transaction restores the original list of candidates.
        router.update(candidates, automatic: true)
        XCTAssertEqual(router.resolve()?.fingerprint, first.fingerprint)
    }
}

@MainActor private final class ReviewMemoryVault: CredentialVault {
    var data: [String: Data]
    var rejectDeletion = false
    var removals = 0
    init(_ data: [String: Data]) { self.data = data }
    func save(_ data: Data, id: String) throws { self.data[id] = data }
    func read(_ id: String) throws -> Data {
        guard let data = data[id] else { throw SwitchError(message: "Synthetic credential absent") }
        return data
    }
    func remove(_ id: String) throws {
        removals += 1
        if rejectDeletion { throw SwitchError(message: "Synthetic keychain failure") }
        data[id] = nil
    }
}
