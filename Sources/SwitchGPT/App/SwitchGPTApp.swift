import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AccountStore()
    private let modelsWindow = ProviderModelsWindow()
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        refreshTask = Task { [store] in
            await store.restoreRouting()
            while !Task.isCancelled {
                await store.refreshUsage()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { break }
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        store.shutdown()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        modelsWindow.show(store: store)
        return true
    }
    func showModels() { modelsWindow.show(store: store) }
}

@main
enum Launcher {
    @MainActor static func main() {
        // Claude Code starts this executable as its private Codex tool relay; no UI is created.
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == ClaudeMCPRelay.flag { ClaudeMCPRelay.run(config: arguments[2]) }
        SwitchGPTApp.main()
    }
}

struct SwitchGPTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private static let menuIcon: NSImage = {
        let image = Bundle.main.url(forResource: "SwitchGPTMenu@2x", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "SwitchGPT")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
    var body: some Scene {
        MenuBarExtra {
            AccountPanel(store: delegate.store, showModels: delegate.showModels)
        } label: {
            Image(nsImage: Self.menuIcon)
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityLabel("SwitchGPT")
        }.menuBarExtraStyle(.window)
            .windowResizability(.contentSize)
    }
}
