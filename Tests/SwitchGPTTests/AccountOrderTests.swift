import XCTest
@testable import SwitchGPT

final class AccountOrderTests: XCTestCase {
    @MainActor func testNicknamePersistsAndEmptyNameRestoresEmail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("accounts.json")
        let original = Account(id: "example", name: "user@example.com", savedAt: .now)
        let store = AccountStore(index: index)
        store.accounts = [original]
        XCTAssertEqual(store.displayName(original), "user@example.com")
        XCTAssertTrue(store.rename(original, to: "  Work  "))
        let loaded = AccountStore(index: index)
        XCTAssertEqual(loaded.displayName(loaded.accounts[0]), "Work")
        XCTAssertEqual(loaded.email(loaded.accounts[0]), "user@example.com")
        XCTAssertEqual(loaded.accounts[0].id, original.id)
        XCTAssertTrue(loaded.rename(loaded.accounts[0], to: " \n "))
        XCTAssertEqual(AccountStore(index: index).accounts[0].nickname, nil)
        loaded.busy = true
        XCTAssertFalse(loaded.rename(original, to: "Blocked"))
    }

    @MainActor func testRenamePreservesLegacyIndexAndNeverOverwritesNewIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = directory.appendingPathComponent("CodexAccountSwitch/accounts.json")
        let destination = directory.appendingPathComponent("SwitchGPT/accounts.json")
        try FileManager.default.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode([Account(id: "saved", name: "Example", savedAt: .now)])
        try original.write(to: previous)
        try AccountStore.migrateAccountIndex(in: directory)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try Data(contentsOf: previous), original)
        let updated = Data("[]".utf8)
        try updated.write(to: destination)
        try AccountStore.migrateAccountIndex(in: directory)
        XCTAssertEqual(try Data(contentsOf: destination), updated)
    }

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
