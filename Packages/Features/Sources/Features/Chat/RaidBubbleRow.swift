import SwiftUI
import ChatModel

/// "Someone raided you with N viewers" bubble.
struct RaidBubbleRow: View {
    let bubble: ChatLine.RaidBubble

    var body: some View {
        SystemEventBubble(icon: "person.3.fill", tint: .pink, alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(bubble.fromBroadcasterDisplayName) raided!")
                    .font(.callout.weight(.semibold))
                Text("^[\(bubble.viewers) viewer](inflect: true)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
