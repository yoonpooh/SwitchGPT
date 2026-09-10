import XCTest
@testable import CodexAccountSwitch

final class AccountOrderTests: XCTestCase {
    @MainActor func testReorderingPersistsAndRejectsUnknownDrag() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("accounts.json")
        let store = AccountStore(index: index)
        store.accounts = ["a", "b", "c"].map { Account(id: $0, name: $0, savedAt: .now) }
        XCTAssertTrue(store.reorder("a", onto: "c"))
        XCTAssertEqual(store.accounts.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(AccountStore(index: index).accounts.map(\.id), ["b", "c", "a"])
        XCTAssertTrue(store.reorder("a", onto: "b"))
        XCTAssertEqual(store.accounts.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(store.reorder("unrelated text", onto: "b"))
        store.busy = true
        XCTAssertFalse(store.reorder("a", onto: "c"))
    }
}
