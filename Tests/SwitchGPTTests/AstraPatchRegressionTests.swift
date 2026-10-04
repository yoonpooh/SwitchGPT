import XCTest
@testable import SwitchGPT

final class AstraPatchRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astra-patch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @MainActor func testCredentialStoreReadsOnlyRealTopLevelAssignments() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = CodexSession(home: root)
        for key in ["cli_auth_credentials_store", "'cli_auth_credentials_store'", #""cli_auth_credentials_store""#,
                    #""cli_auth_credentials\U0000005fstore""#] {
            try "\(key) = 'keyring' # unsupported\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try session.validateStore(), key)
            try "\(key) = \"file\" # supported\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try session.validateStore(), key)
        }
        for delimiter in ["'''", "\"\"\""] {
            let config = "developer_instructions = \(delimiter)\ncli_auth_credentials_store = 'keyring'\n\(delimiter)\n"
                + "cli_auth_credentials_store = 'file'\n[example]\ncli_auth_credentials_store = 'keyring'\n"
            try config.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try session.validateStore())
        }
        for value in ["'''file'''", "\"\"\"file\"\"\"", "\"\"\"\nfile\"\"\"", "\"\"\"fi\\\n  le\"\"\"", #""\u0066ile""#] {
            try "cli_auth_credentials_store = \(value)\n".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            XCTAssertNoThrow(try session.validateStore(), value)
        }
        XCTAssertNotEqual(TOMLTopLevel.valueString("\"\"\"file\\\\\n\"\"\""), "file")
    }

    @MainActor func testCancelledDaemonCommandTerminatesItsProcess() async throws {
        let root = try directory()
        let marker = root.appendingPathComponent("pid")
        defer {
            if let pid = try? markerPID(marker) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        let task = Task { @MainActor in
            try await DaemonCommand.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo $$ > '\(marker.path)'; exec /bin/sleep 20"], home: root)
        }
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try markerPID(marker)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "Cancelled command survived")
    }

    private func markerPID(_ marker: URL) throws -> pid_t {
        try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @MainActor func testTimedOutDaemonCommandTerminatesItsGroupWithoutTouchingOtherProcesses() async throws {
        let root = try directory()
        let marker = root.appendingPathComponent("pid")
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sleep")
        outside.arguments = ["20"]
        try outside.run()
        defer {
            if outside.isRunning { outside.terminate() }
            outside.waitUntilExit()
            if let pid = try? markerPID(marker) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        let began = ContinuousClock.now
        do {
            _ = try await DaemonCommand.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo $$ > '\(marker.path)'; exec /bin/sleep 20"], home: root, timeout: 1)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error.localizedDescription, L10n.text("server_timeout")) }
        XCTAssertLessThan(began.duration(to: .now), .seconds(3))
        XCTAssertNotEqual(kill(try markerPID(marker), 0), 0)
        XCTAssertTrue(outside.isRunning)
    }

    @MainActor func testStartupRestoresLatestSuccessfulEventAcrossMalformedAndFailedLines() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = RelayEvent(date: Date(timeIntervalSince1970: 100), accountFingerprint: "old", path: "/backend-api/codex/responses", status: 200, completed: true)
        let latest = RelayEvent(date: Date(timeIntervalSince1970: 200), accountFingerprint: "new", path: "/backend-api/codex/responses", status: 200, completed: true)
        let failure = RelayEvent(date: Date(timeIntervalSince1970: 300), accountFingerprint: "bad", path: "/backend-api/codex/responses", status: 500, completed: false)
        let file = root.appendingPathComponent("relay-events.jsonl")
        let text = try [older, latest, failure].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n") + "\nnot JSON\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(AccountStore(index: root.appendingPathComponent("accounts.json"), session: CodexSession(home: root)).lastRequest?.accountFingerprint, "new")
        try "not JSON\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(AccountStore(index: root.appendingPathComponent("accounts.json"), session: CodexSession(home: root)).lastRequest)
    }
}
