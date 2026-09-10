import SwiftUI

struct PlanBadge: View {
    let plan: String

    private var tint: Color {
        switch plan.lowercased() {
        case "plus": .blue
        case "pro": .purple
        default: .secondary
        }
    }

    var body: some View {
        Text(plan.capitalized)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay {
                Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
            }
            .fixedSize()
    }
}
