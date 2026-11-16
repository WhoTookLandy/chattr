import SwiftUI

/// Generic system bubble — announcements, charity events, bits-badge-tier
/// upgrades, etc. Same visual treatment as the typed bubbles but with a
/// neutral icon and accent tint.
struct SystemBubbleRow: View {
    let text: String

    var body: some View {
        SystemEventBubble(icon: "info.circle.fill", iconWeight: .regular, tint: .secondary, fillOpacity: 0.1) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
        }
    }
}
