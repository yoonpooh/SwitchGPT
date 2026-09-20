import SwiftUI

struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan.capitalized)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .fixedSize()
    }
}
