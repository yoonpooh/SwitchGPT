import XCTest
@testable import SwitchGPT

final class ClaudeAuditProbeTests: XCTestCase {
    func testCompletedConversationKillsTerminationResistantChild() throws {
        try probe(parentExits: false)
    }
    func testEarlyCLIExitKillsOrphanHoldingStdout() throws {
        try probe(parentExits: true)
    }
    private func probe(parentExits: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let marker = root.appendingPathComponent("child")
        let executable = root.appendingPathComponent("fake-claude")
        let script = """
        #!/usr/bin/python3
        import os, sys, json, signal, time
        sys.stdin.readline()
        child = os.fork()
        if child == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.close(0)
            os.close(2)
            if \(parentExits ? "False" : "True"): os.close(1)
            open('\(marker.path)', 'w').write(str(os.getpid()))
            time.sleep(20)
            os._exit(0)
        while not os.path.exists('\(marker.path)'): time.sleep(0.01)
        print(json.dumps({'type':'system','subtype':'init','tools':[]}), flush=True)
        if \(parentExits ? "True" : "False"): os._exit(1)
        print(json.dumps({'type':'result','is_error':False,'result':'synthetic answer'}), flush=True)
        sys.stdin.read()
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let executor = ClaudeExecutor(claudeExecutable: { executable }, stallLimit: 0.5, startLimit: 1)
        executor.setEnabled(true)
        defer {
            executor.shutdown()
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = Int32(text) { kill(pid, SIGKILL) }
            usleep(50_000)
            try? FileManager.default.removeItem(at: root)
        }
        let sink = AuditSink()
        let request = RelayRequest(method: "POST", target: "/backend-api/codex/responses", headers: [:],
            body: ClaudeBridge.encode(["model": ClaudeModel.fallback.slug, "prompt_cache_key": "synthetic-audit", "input": "hello"]))
        executor.respond(to: request, sink: sink)
        XCTAssertEqual(sink.finished.wait(timeout: .now() + 4), .success)
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        usleep(5_500_000)
        XCTAssertNotEqual(kill(pid, 0), 0, "Conversation child survived after completed/failed response; pid=\(pid)")
    }
}
private final class AuditSink: ClaudeSink, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    func beginEventStream() {}
    func write(_ data: Data) {}
    func finish() { finished.signal() }
    func respond(status: Int, json: Data) { finished.signal() }
    func observeClose(_ handler: @escaping @Sendable () -> Void) {}
}
