import SwiftUI

/// Generic system bubble — charity events, bits-badge-tier upgrades,
/// pay-it-forward notices, etc. Same visual treatment as the typed bubbles
/// but with a neutral icon and accent tint. (Announcements use their own
/// `AnnouncementBubbleRow` so they can render emotes, badges, and accent colors.)
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
