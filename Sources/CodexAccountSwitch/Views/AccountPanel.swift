import SwiftUI
import AppKit

struct AccountPanel: View {
    var store: AccountStore
    @State private var hoveredAccount: String?
    @State private var deleting: Account?
    @State private var dropTarget: String?
    @State private var listHeight: CGFloat = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("accounts")).font(.headline)
                Spacer()
                Button { Task { await store.refreshUsage() } } label: {
                    if store.loadingUsage { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.plain).disabled(store.loadingUsage || store.busy).help(L10n.text("refresh"))
            }
            if store.accounts.isEmpty {
                Text(L10n.text("empty")).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.accounts) { account in
                            cardButton(account)
                            .overlay(alignment: .topTrailing) {
                                Button { deleting = account } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).disabled(store.busy).help(L10n.text("delete_help"))
                                    .padding(12)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(account.id == store.currentID ? Color.accentColor : Color.clear, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                            .overlay(alignment: .top) {
                                if dropTarget == account.id {
                                    Capsule().fill(Color.accentColor).frame(height: 3).allowsHitTesting(false)
                                }
                            }
                            .accessibilityValue(account.id == store.currentID ? L10n.text("current") : L10n.text("saved"))
                            .draggable(account.id)
                            .dropDestination(for: String.self) { items, _ in
                                guard items.count == 1, let source = items.first else { return false }
                                return store.reorder(source, onto: account.id)
                            } isTargeted: { targeted in
                                dropTarget = targeted ? account.id : (dropTarget == account.id ? nil : dropTarget)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        listHeight = height
                    }
                }.frame(height: min(400, max(1, listHeight)))
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
                Text(store.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if store.addingAccount { Button(L10n.text("cancel_login")) { store.cancelLogin() } }
            Divider()
            HStack {
                Button(L10n.text("add")) { Task { await store.addAccount() } }
                    .disabled(store.busy).buttonStyle(.borderedProminent)
                Spacer()
                Button(L10n.text("quit")) { NSApp.terminate(nil) }.buttonStyle(.plain).disabled(store.busy)
            }
        }.padding(16).frame(width: 400)
        .task { await store.refreshUsage() }
        .onDisappear { NSCursor.arrow.set() }
        .onChange(of: store.busy) { _, _ in NSCursor.arrow.set() }
        .onChange(of: store.currentID) { _, _ in NSCursor.arrow.set() }
    }
    private func cardButton(_ account: Account) -> some View {
        let button = Button { confirmSwitch(account) } label: {
                                cardContent(account)
                            }.buttonStyle(.plain).disabled(store.busy)

        return button
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(hoveredAccount == account.id && account.id != store.currentID && !store.busy ? Color.accentColor.opacity(0.14) : Color.clear)
                            }
                            .onHover { hovered in
                                hoveredAccount = hovered ? account.id : (hoveredAccount == account.id ? nil : hoveredAccount)
                            }
                            .onContinuousHover { phase in
                                switch phase {
                                case .active:
                                    if !store.busy && account.id != store.currentID {
                                        NSCursor.pointingHand.set()
                                    } else { NSCursor.arrow.set() }
                                case .ended:
                                    NSCursor.arrow.set()
                                }
                            }
                            .animation(.easeOut(duration: 0.12), value: hoveredAccount)
    }
    private func cardContent(_ account: Account) -> some View {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    if let plan = store.usages[account.id]?.planType {
                                        Text(plan.uppercased())
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                            .fixedSize()
                                    }
                                    Text(store.displayName(account))
                                        .fontWeight(.semibold)
                                        .lineLimit(1).truncationMode(.tail)
                                        .help(store.displayName(account))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(.trailing, 26)
                                if let usage = store.usages[account.id] {
                                    if let window = usage.rateLimit?.primaryWindow { UsageWindowView(window: window) }
                                    if let window = usage.rateLimit?.secondaryWindow { UsageWindowView(window: window) }
                                    if usage.rateLimit?.primaryWindow == nil && usage.rateLimit?.secondaryWindow == nil {
                                        Text(L10n.text("no_limits")).font(.caption).foregroundStyle(.secondary)
                                    }
                                } else if store.usageErrors[account.id] == nil {
                                    Text(store.loadingUsage ? L10n.text("loading") : L10n.text("refresh_hint")).font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = store.usageErrors[account.id] {
                                    Text(error).font(.caption).foregroundStyle(.orange)
                                }
                                if let credits = store.usages[account.id]?.rateLimitResetCredits, credits.availableCount > 0 {
                                    let available = store.resetDetails[account.id]?.availableCredits ?? []
                                    HStack(spacing: 8) {
                                        Label(L10n.format("resets", credits.availableCount), systemImage: "arrow.counterclockwise.circle")
                                        Spacer(minLength: 0)
                                        if let expiration = available.first?.expiration {
                                            Text(L10n.format("expires", L10n.date(expiration, includeTime: false)))
                                                .foregroundStyle(.secondary)
                                                .help(L10n.format("expires", L10n.date(expiration)))
                                        } else {
                                            Text(L10n.text("expiry_unknown")).foregroundStyle(.secondary)
                                        }
                                    }.font(.caption).lineLimit(1)
                                }
                            }.padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    private func confirmSwitch(_ account: Account) {
        guard !store.busy, account.id != store.currentID else { return }
        NSCursor.arrow.set()
        let alert = NSAlert()
        alert.messageText = L10n.text("switch_confirm")
        alert.informativeText = L10n.format("switch_detail", store.displayName(account))
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.text("switch"))
        alert.addButton(withTitle: L10n.text("cancel")).keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await store.switchTo(account) }
        }
    }

}

private struct UsageWindowView: View {
    let window: AccountUsage.Window
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.label).font(.caption)
                Spacer()
                Text(L10n.format("remaining", Int(window.remaining))).font(.caption.bold()).monospacedDigit()
            }
            ProgressView(value: window.remaining, total: 100)
                .tint(window.remaining <= 10 ? .orange : .accentColor)
            Text(L10n.format("resets_at", L10n.date(window.resetDate)))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
