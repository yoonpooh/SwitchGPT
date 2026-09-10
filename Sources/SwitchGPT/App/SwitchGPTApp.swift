import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct SwitchGPTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var store = AccountStore()
    private static let menuIcon: NSImage = {
        let image = Bundle.main.url(forResource: "SwitchGPTMenu@2x", withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "SwitchGPT")!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
    var body: some Scene {
        MenuBarExtra {
            AccountPanel(store: store)
        } label: {
            Image(nsImage: Self.menuIcon)
                .resizable()
                .frame(width: 18, height: 18)
                .accessibilityLabel("SwitchGPT")
        }.menuBarExtraStyle(.window)
    }
}
