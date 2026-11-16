import SwiftUI
import ChatModel

/// Sub/resub/gift/Prime bubble. Tier drives the leading symbol's tint
/// (Tier 1 / Prime → blue, Tier 2 → purple, Tier 3 → gold).
struct SubBubbleRow: View {
    let bubble: ChatLine.SubBubble

    var body: some View {
        SystemEventBubble(icon: bubble.isGift ? "gift.fill" : "star.fill", tint: tierColor) {
            VStack(alignment: .leading, spacing: 4) {
                // Twitch-formatted system message — the authoritative text.
                // We don't rebuild it because Twitch's localization is
                // already correct for the user's selected language.
                Text(bubble.systemMessage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)

                // If the resub included a user message, render it dimmed
                // below — matches the Twitch web layout.
                if let userMessage = bubble.userMessage, !userMessage.isEmpty {
                    Text(userMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Tier-driven accent color. Maps to Twitch's conventional tier tints
    /// (T1 = blue / T2 = purple / T3 = gold / Prime = blue).
    private var tierColor: Color {
        switch bubble.tier {
        case .prime, .t1: return .blue
        case .t2:         return .purple
        case .t3:         return .yellow
        }
    }
}
