import XCTest
import AppKit
@testable import SwitchGPT

@MainActor final class ProviderModelsWindowTests: XCTestCase {
    func testModelsWindowOpensReusesAndReopensAfterClose() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(index: root.appendingPathComponent("accounts.json"), session: CodexSession(home: root))
        let presenter = ProviderModelsWindow()
        presenter.show(store: store)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == L10n.text("models_manage") && $0.isVisible })
        XCTAssertNotNil(window.contentView)
        presenter.show(store: store)
        XCTAssertEqual(NSApp.windows.filter { $0.title == window.title && $0.isVisible }.count, 1)
        window.close()
        XCTAssertFalse(window.isVisible)
        presenter.show(store: store)
        XCTAssertTrue(window.isVisible)
        window.close()
    }
}
