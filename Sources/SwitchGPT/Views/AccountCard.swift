import SwiftUI

struct AccountAvatar: View {
    var store: AccountStore
    let account: Account
    var size: CGFloat = 28

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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AccountAvatar(store: store, account: account)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(store.displayName(account)).font(.callout.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle).help(store.email(account))
                    if let plan = store.usages[account.id]?.planType { PlanBadge(plan: plan) }
                    Spacer(minLength: 0)
                }
                if let usage = store.usages[account.id] {
                    if let window = usage.rateLimit?.primaryWindow { UsageWindowView(window: window) }
                    if let window = usage.rateLimit?.secondaryWindow { UsageWindowView(window: window) }
                    if usage.rateLimit?.primaryWindow == nil && usage.rateLimit?.secondaryWindow == nil {
                        Text(L10n.text("no_limits")).font(.caption).foregroundStyle(.secondary)
                    }
                } else if store.usageErrors[account.id] == nil {
                    Text(L10n.text(store.loadingUsage ? "loading" : "refresh_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.usageErrors[account.id] {
                    Label(L10n.text("routing_usage_unavailable"), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).help(error)
                }
                if let credits = store.usages[account.id]?.rateLimitResetCredits, credits.availableCount > 0 {
                    HStack(spacing: 6) {
                        Label(L10n.format("resets", credits.availableCount), systemImage: "arrow.counterclockwise.circle")
                        Spacer(minLength: 0)
                        if let expiration = store.resetDetails[account.id]?.availableCredits.first?.expiration {
                            Text(L10n.format("expires", L10n.date(expiration, includeTime: false)))
                                .help(L10n.format("expires", L10n.date(expiration)))
                        }
                    }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageWindowView: View {
    let window: AccountUsage.Window

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(window.label).font(.caption2).frame(width: 52, alignment: .leading)
                ProgressView(value: window.remaining, total: 100)
                    .tint(window.remaining <= 10 ? .orange : .accentColor)
                Text(L10n.format("remaining", Int(window.remaining.rounded(.up))))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            Text(L10n.format("resets_at", compactResetDate)).font(.system(size: 10)).foregroundStyle(.tertiary)
                .help(L10n.format("resets_at", L10n.date(window.resetDate)))
        }
    }

    private var compactResetDate: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(window.resetDate) ? "Hm" : "MdHm")
        return formatter.string(from: window.resetDate)
    }
}
