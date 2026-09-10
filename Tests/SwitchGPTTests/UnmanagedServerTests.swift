import XCTest
@testable import SwitchGPT

final class UnmanagedServerTests: XCTestCase {
    @MainActor func testSelectsOnlyExactSocketOwner() {
        let output = "p12\nf30\nn/tmp/other.sock\np34\nf31\nn/tmp/control.sock\np56\nf32\nn/tmp/control.sock-extra\n"
        XCTAssertEqual(UnmanagedServer.socketOwners(output, path: "/tmp/control.sock"), [34])
        XCTAssertEqual(UnmanagedServer.socketOwners("", path: "/tmp/control.sock"), [])
    }
    @MainActor func testRejectsOtherProcessesAndProxy() {
        XCTAssertTrue(UnmanagedServer.isExpectedServer(command: "/bin/codex", arguments: "/bin/codex app-server --listen unix://", socket: "/tmp/control.sock"))
        XCTAssertFalse(UnmanagedServer.isExpectedServer(command: "/bin/codex", arguments: "/bin/codex app-server proxy", socket: "/tmp/control.sock"))
        XCTAssertFalse(UnmanagedServer.isExpectedServer(command: "/bin/codex", arguments: "/bin/codex app-server --listen unix:///tmp/other.sock", socket: "/tmp/control.sock"))
        XCTAssertFalse(UnmanagedServer.isExpectedServer(command: "/bin/other", arguments: "/bin/other app-server --listen unix://", socket: "/tmp/control.sock"))
    }
}
