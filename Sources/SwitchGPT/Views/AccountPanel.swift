import SwiftUI
import AppKit

struct AccountPanel: View {
    var store: AccountStore
    @State private var hoveredAccount: String?
    @State private var deleting: Account?
    @State private var dropTarget: String?
    @State private var listHeight: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            RoutingStatusView(store: store, restart: confirmRestart)
            if store.accounts.isEmpty {
                Text(L10n.text("empty")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 9) {
                        ForEach(store.accounts) { account in accountButton(account) }
                    }.frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }.frame(height: min(maximumListHeight, max(1, listHeight)))
            }
            if let account = deleting {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("delete_confirm")).font(.callout)
                    HStack {
                        Button(L10n.text("delete"), role: .destructive) { store.remove(account); deleting = nil }
                        Button(L10n.text("cancel")) { deleting = nil }
                    }
                }.disabled(store.busy)
            }
            if !store.message.isEmpty {
                Label(store.message, systemImage: store.addingAccount ? "person.crop.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.addingAccount { Button(L10n.text("cancel_login")) { store.cancelLogin() } }
            Divider()
            HStack(spacing: 12) {
                Label(L10n.text("routing_desktop_label"), systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary).help(L10n.text("routing_desktop_help"))
                Spacer(minLength: 8)
                Text(store.desktopName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            }.font(.caption).padding(.vertical, 4)
        }.padding(16).frame(width: 400)
            .task { await store.refreshUsage() }
            .onDisappear { NSCursor.arrow.set() }
            .onChange(of: store.busy) { _, _ in NSCursor.arrow.set() }
            .onChange(of: store.currentID) { _, _ in NSCursor.arrow.set() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("SwitchGPT").font(.system(size: 17, weight: .semibold))
            Spacer()
            Button { Task { await store.refreshUsage() } } label: {
                Group {
                    if store.loadingUsage { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 24, height: 24)
            }.buttonStyle(.plain).disabled(store.loadingUsage || store.busy).help(L10n.text("refresh"))
            Button { Task { await store.addAccount(); await store.refreshUsage() } } label: {
                Image(systemName: "plus").frame(width: 24, height: 24)
            }.buttonStyle(.plain).disabled(store.busy).help(L10n.text("add")).accessibilityLabel(L10n.text("add"))
            Menu {
                Toggle(L10n.text("routing_auto_toggle"), isOn: Binding(
                    get: { store.routingPreferences.automatic }, set: { store.setAutomatic($0) }))
                Divider()
                ForEach(store.accounts) { account in
                    Menu(store.displayName(account)) { accountActions(account) }
                }
                Divider()
                Button(L10n.text("quit"), action: quit)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(store.busy).help(L10n.text("routing_more"))
        }
    }

    private var maximumListHeight: CGFloat {
        min(460, max(130, (NSScreen.main?.visibleFrame.height ?? 800) - (store.needsRestart ? 360 : 290)))
    }

    private func accountButton(_ account: Account) -> some View {
        let selected = account.id == store.currentID
        let tint: Color = selected && store.needsRestart ? .orange : .accentColor
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { Task { await store.switchTo(account) } } label: {
            AccountCard(store: store, account: account)
                .contentShape(shape).draggable(account.id)
        }.buttonStyle(.plain).disabled(store.busy)
            .background(selected ? tint.opacity(0.065) : hoveredAccount == account.id ? Color.primary.opacity(0.045) : Color.primary.opacity(0.015), in: shape)
            .overlay { shape.strokeBorder(selected ? tint.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: selected ? 1 : 0.7).allowsHitTesting(false) }
            .overlay(alignment: .top) {
                if dropTarget == account.id { Capsule().fill(Color.accentColor).frame(height: 3).allowsHitTesting(false) }
            }
            .contextMenu { accountActions(account) }
            .accessibilityValue(selected ? L10n.text(store.needsRestart ? "routing_pending" : "routing_next") : L10n.text("saved"))
            .dropDestination(for: String.self) { items, _ in
                guard items.count == 1, let source = items.first else { return false }
                return store.reorder(source, onto: account.id)
            } isTargeted: { targeted in dropTarget = targeted ? account.id : (dropTarget == account.id ? nil : dropTarget) }
            .onHover { hovered in hoveredAccount = hovered ? account.id : (hoveredAccount == account.id ? nil : hoveredAccount) }
            .onContinuousHover { phase in
                switch phase {
                case .active: if !store.busy && !selected { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                case .ended: NSCursor.arrow.set()
                }
            }.animation(.easeOut(duration: 0.12), value: hoveredAccount)
    }

    @ViewBuilder private func accountActions(_ account: Account) -> some View {
        Button(L10n.text("edit_name")) { editName(account) }
        Button(L10n.text("delete"), role: .destructive) { deleting = account }
            .disabled(account.id == store.currentID)
    }

    private func editName(_ account: Account) {
        guard !store.busy else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("edit_name")
        alert.informativeText = L10n.text("edit_name_hint")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = account.nickname ?? ""
        field.placeholderString = store.email(account)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("save"))
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.rename(account, to: field.stringValue) }
    }

    private func confirmRestart() {
        let alert = NSAlert()
        alert.messageText = L10n.text("routing_restart_confirm")
        alert.informativeText = L10n.text("routing_restart_warning")
        alert.addButton(withTitle: L10n.text("routing_restart_action"))
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { Task { await store.restartDesktop() } }
    }

    private func quit() {
        guard store.routingActive else { NSApp.terminate(nil); return }
        let alert = NSAlert()
        alert.messageText = L10n.text("routing_quit_title")
        alert.informativeText = L10n.text("routing_quit_detail")
        alert.addButton(withTitle: L10n.text("quit"))
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }
}
