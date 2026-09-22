import SwiftUI
import AppKit

struct AccountPanel: View {
    var store: AccountStore
    @State private var hoveredAccount: String?
    @State private var dropTarget: String?
    @State private var listHeight: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if store.lastCompletedModelRouting != nil
                || (store.selectedAccount != nil && (store.needsRestart || store.selectedExhausted))
                || (store.selectedAccount == nil && !store.accounts.isEmpty) {
                RoutingStatusView(store: store, restart: confirmRestart)
            }
            if store.accounts.isEmpty {
                Text(L10n.text("empty")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(store.accounts) { account in accountButton(account) }
                    }.frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                        .padding(.vertical, listOverflows ? 12 : 0)
                }.frame(height: min(maximumListHeight, max(1, listHeight)))
                    .mask {
                        if listOverflows {
                            VStack(spacing: 0) {
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 8)
                                Rectangle().fill(.black)
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 8)
                            }
                        } else { Rectangle().fill(.black) }
                    }
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
                HStack(spacing: 6) {
                    if let account = store.accounts.first(where: { $0.id == store.desktopID }) {
                        AccountAvatar(store: store, account: account, size: 18)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable().scaledToFit().foregroundStyle(.secondary)
                            .frame(width: 18, height: 18).accessibilityHidden(true)
                    }
                    Text(store.desktopName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
            }.font(.caption).padding(.vertical, 4)
        }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 7)
            .frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .task { await store.refreshUsage() }
            .onDisappear { NSCursor.arrow.set() }
            .onChange(of: store.busy) { _, _ in NSCursor.arrow.set() }
            .onChange(of: store.currentID) { _, _ in NSCursor.arrow.set() }
            .onChange(of: store.routingPreferences.automatic) { _, _ in NSCursor.arrow.set() }
            .onChange(of: store.routingPreferences.effortAutomatic) { _, _ in NSCursor.arrow.set() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("SwitchGPT").font(.system(size: 13, weight: .semibold))
            Text(L10n.text(store.routingPreferences.automatic ? "routing_auto_badge" : "routing_manual_badge"))
                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.primary.opacity(0.045), in: Capsule())
                .fixedSize().help(L10n.text("routing_auto_help"))
            Spacer()
            Button { Task { await store.refreshUsage() } } label: {
                Group {
                    if store.loadingUsage { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 20, height: 20)
            }.buttonStyle(.plain).disabled(store.loadingUsage || store.busy).help(L10n.text("refresh"))
            Button { Task { await store.addAccount(); await store.refreshUsage() } } label: {
                Image(systemName: "plus").frame(width: 20, height: 20)
            }.buttonStyle(.plain).disabled(store.busy).help(L10n.text("add")).accessibilityLabel(L10n.text("add"))
            Menu {
                Toggle(L10n.text("routing_auto_toggle"), isOn: Binding(
                    get: { store.routingPreferences.automatic }, set: { store.setAutomatic($0) }))
                Divider()
                Menu(L10n.text("jev_settings")) {
                    Text(L10n.text("jev_disclosure"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L10n.text("jev_effort_auto_toggle"), isOn: Binding(
                        get: { store.routingPreferences.effortAutomatic }, set: { store.setEffortAutomatic($0) }))
                    Divider()
                    Button(L10n.text(store.hasJevAPIKey ? "jev_replace_key" : "jev_save_key"), action: editJevAPIKey)
                    Button(L10n.text("jev_remove_key"), role: .destructive) {
                        _ = store.removeJevAPIKey()
                    }.disabled(!store.hasJevAPIKey)
                }
                Divider()
                ForEach(store.accounts) { account in
                    Menu(store.displayName(account)) { accountActions(account) }
                }
                Divider()
                Button(L10n.text("quit"), action: quit)
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(store.busy).help(L10n.text("routing_more"))
        }
    }

    private var maximumListHeight: CGFloat {
        min(460, max(130, (NSScreen.main?.visibleFrame.height ?? 800) - (store.needsRestart ? 360 : 290)))
    }

    private var listOverflows: Bool { listHeight > maximumListHeight }

    private func accountButton(_ account: Account) -> some View {
        let selected = account.id == store.currentID
        let tint: Color = selected && store.needsRestart ? .orange : .primary
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return AccountCard(store: store, account: account,
                           select: { Task {
                               guard !store.routingPreferences.automatic else { return }
                               await store.switchTo(account)
                           } },
                           useReset: { confirmReset(account) })
            .disabled(store.busy)
            .padding(.trailing, listOverflows ? 12 : 0)
            .background(selected ? tint.opacity(0.045) : hoveredAccount == account.id ? Color.primary.opacity(0.035) : .clear, in: shape)
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
                case .active: if !store.busy && (store.routingPreferences.automatic || !selected) { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                case .ended: NSCursor.arrow.set()
                }
            }.animation(.easeOut(duration: 0.12), value: hoveredAccount)
    }

    @ViewBuilder private func accountActions(_ account: Account) -> some View {
        Button(L10n.text("edit_name")) { editName(account) }
        Button(L10n.text("delete"), role: .destructive) { confirmDelete(account) }
            .disabled(account.id == store.currentID)
    }

    private func confirmDelete(_ account: Account) {
        guard !store.busy, account.id != store.currentID else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("delete_confirm")
        alert.informativeText = store.displayName(account)
        alert.addButton(withTitle: L10n.text("delete")).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { store.remove(account) }
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

    private func editJevAPIKey() {
        guard !store.busy else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text(store.hasJevAPIKey ? "jev_replace_key" : "jev_save_key")
        alert.informativeText = L10n.text("jev_key_hint") + "\n\n" + L10n.text("jev_key_disclosure")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = L10n.text("jev_key_placeholder")
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.text("save"))
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { _ = store.saveJevAPIKey(field.stringValue) }
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

    private func confirmReset(_ account: Account) {
        guard store.canUseReset(account) else { return }
        let retrying = store.hasPendingReset(account)
        let alert = NSAlert()
        alert.messageText = L10n.text(retrying ? "reset_retry" : "reset_confirm_title")
        alert.informativeText = L10n.format(retrying ? "reset_retry_confirm" : "reset_confirm_detail", store.displayName(account))
        alert.addButton(withTitle: L10n.text(retrying ? "reset_retry" : "reset_use"))
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                guard let result = await store.useResetCredit(account) else { return }
                let completion = NSAlert()
                completion.alertStyle = result.succeeded ? .informational : .warning
                completion.messageText = result.text
                completion.informativeText = store.displayName(account)
                NSApp.activate(ignoringOtherApps: true)
                completion.runModal()
            }
        }
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
