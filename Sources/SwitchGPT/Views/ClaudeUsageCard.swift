import SwiftUI

/// Limits of the Claude Code account signed in on this Mac, shown below the ChatGPT accounts.
struct ClaudeUsageCard: View {
    var store: AccountStore
    private static let icon = Bundle.module.url(forResource: "ClaudeAppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let icon = Self.icon { Image(nsImage: icon).resizable().scaledToFill() }
                else { Image(systemName: "asterisk.circle.fill").resizable().scaledToFit().foregroundStyle(.orange) }
            }.frame(width: 24, height: 24).clipShape(Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(store.claudeDisplayName).font(.caption.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(store.claudeEmail + " · " + L10n.text("claude_usage_help"))
                    if let plan = store.claudeUsage?.plan { PlanBadge(plan: plan) }
                    Spacer(minLength: 0)
                }
                if let usage = store.claudeUsage {
                    let meters = usage.usage.meters
                    ForEach(Array(meters.enumerated()), id: \.offset) { _, meter in
                        UsageWindowView(label: meter.label, remaining: meter.remaining, resetDate: meter.resetDate)
                    }
                    if meters.isEmpty {
                        Text(L10n.text("no_limits")).font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = store.claudeUsageError {
                    Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L10n.text(store.loadingUsage ? "loading" : "refresh_hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 7).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("claude_usage_help"))
    }
}
