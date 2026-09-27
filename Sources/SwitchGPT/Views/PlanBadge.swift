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

    /// ChatGPT reports lowercase plan types; its two Pro tiers are named like Claude's "Max 20x".
    /// An already formatted name such as "Max 20x" is kept.
    nonisolated static func title(_ plan: String) -> String {
        guard plan == plan.lowercased() else { return plan }
        return ["prolite": "Pro", "pro": "Pro 20x"][plan] ?? plan.capitalized
    }
}
