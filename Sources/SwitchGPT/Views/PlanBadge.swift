import SwiftUI

struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(Self.title(plan))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .fixedSize()
    }

    /// Keep the three ChatGPT Pro tiers distinct; preserve already formatted labels.
    nonisolated static func title(_ plan: String) -> String {
        guard plan == plan.lowercased() else { return plan }
        return ["prolite": "Pro 100", "pro": "Pro 200", "promax": "Pro 500"][plan] ?? plan.capitalized
    }
}
