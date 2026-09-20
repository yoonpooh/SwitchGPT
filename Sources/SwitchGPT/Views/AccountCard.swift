import SwiftUI

struct AccountAvatar: View {
    var store: AccountStore
    let account: Account
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let photo = store.profileImages[account.id] {
                Image(nsImage: photo).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
    }
}

struct AccountCard: View {
    var store: AccountStore
    let account: Account
    var select: () -> Void
    var useReset: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if store.routingPreferences.automatic {
                summary.contentShape(Rectangle()).draggable(account.id)
            } else {
                Button(action: select) { summary.contentShape(Rectangle()).draggable(account.id) }
                    .buttonStyle(.plain)
            }
            if hasReset {
                if store.resetInProgressID == account.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: useReset) {
                        Label("\(resetCount)", systemImage: "arrow.counterclockwise.circle")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .disabled(!store.canUseReset(account))
                    .help(resetHelp)
                    .accessibilityLabel(L10n.text(store.hasPendingReset(account) ? "reset_retry" : "reset_use"))
                }
            }
        }.padding(.horizontal, 7).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 8) {
            AccountAvatar(store: store, account: account)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(store.displayName(account)).font(.caption.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle).help(store.email(account))
                    if let plan = store.usages[account.id]?.planType { PlanBadge(plan: plan) }
                    Spacer(minLength: 0)
                    if hasReset { Color.clear.frame(width: 24, height: 1) }
                }
                if let usage = store.usages[account.id] {
                    let windows = [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow].compactMap { $0 }
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        UsageWindowView(window: window)
                    }
                    if usage.rateLimit?.primaryWindow == nil && usage.rateLimit?.secondaryWindow == nil {
                        Text(L10n.text("no_limits")).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L10n.text(store.loadingUsage ? "loading" : "refresh_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }

            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resetCount: Int {
        store.usages[account.id]?.rateLimitResetCredits?.availableCount ?? 0
    }

    private var hasReset: Bool { resetCount > 0 || store.hasPendingReset(account) }

    private var resetHelp: String {
        if let expiration = store.resetDetails[account.id]?.availableCredits.first?.expiration {
            return store.resetHelp(account) + " " + L10n.format("expires", L10n.date(expiration))
        }
        return store.resetHelp(account)
    }
}

private struct UsageWindowView: View {
    let window: AccountUsage.Window

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(window.label)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(compactDate(window.resetDate))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(L10n.format("resets_at", L10n.date(window.resetDate)))
            }
            .frame(width: 54, alignment: .leading)
            ProgressView(value: window.remaining, total: 100)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(window.remaining <= 10 ? .orange : .accentColor)
                .padding(.top, 3)
            Text("\(Int(window.remaining.rounded(.up)))%")
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
                .accessibilityLabel(L10n.format("remaining", Int(window.remaining.rounded(.up))))
        }
    }

    private func compactDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "H:mm" : "M/d H:mm"
        return formatter.string(from: date)
    }
}
