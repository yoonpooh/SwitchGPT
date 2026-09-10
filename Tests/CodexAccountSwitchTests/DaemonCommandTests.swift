import XCTest
@testable import CodexAccountSwitch

final class DaemonCommandTests: XCTestCase {
    @MainActor func testPreservesFailureAndExplicitHome() async throws {
        let result = try await DaemonCommand.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "test \"$CODEX_HOME\" = /tmp/codex-fixture || exit 9; echo 'test stop failure' >&2; exit 7"], home: URL(fileURLWithPath: "/tmp/codex-fixture"))
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.output.contains("test stop failure"))
    }
    @MainActor func testManagedExecutableAndRedaction() {
        XCTAssertEqual(DaemonCommand.managedExecutable(from: #"{"managedCodexPath":"/bin/sh"}"#)?.path, "/bin/sh")
        XCTAssertNil(DaemonCommand.managedExecutable(from: "not JSON"))
        XCTAssertEqual(DaemonCommand.safeError("Bearer secret sk-fake https://example.com/token"), Array(repeating: L10n.text("redacted"), count: 3).joined(separator: " "))
    }
}
