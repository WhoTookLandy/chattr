import SwiftUI

// System event rows (sub / raid / generic notice) share one visual
// foundation — a tinted rounded background, a leading SF Symbol, and the
// Twitch-formatted system message — and diverge in tint and icon so the
// user can tell at a glance which kind of event happened.
//
// Design intent (HIG — see docs/conventions.md):
//   - Semantic colors that adapt to light/dark mode automatically.
//   - Hierarchical symbol rendering for depth without explicit shadowing.
//   - Subtle tinted backgrounds (`opacity(0.15)` on accent colors) — not
//     opaque, not loud. The row is information, not an alert.

/// The shared shell behind every system bubble: a leading 20pt hierarchical
/// symbol and a tinted background, with the event-specific content slotted
/// in. Tint drives both the icon colour and the background fill
/// (`tint.opacity(fillOpacity)`), so a bubble reads as one coherent accent.
struct SystemEventBubble<Content: View>: View {
    let icon: String
    var iconWeight: Font.Weight = .semibold
    let tint: Color
    var fillOpacity: Double = 0.15
    var alignment: VerticalAlignment = .top
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: alignment, spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(iconWeight))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 20)
                // Decorative once the bubble reads as one combined element.
                .accessibilityHidden(true)

            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tint.opacity(fillOpacity))
        )
        // One VoiceOver stop per event bubble (sub/raid/announcement),
        // matching ChatRow's message grouping.
        .accessibilityElement(children: .combine)
    }
}
