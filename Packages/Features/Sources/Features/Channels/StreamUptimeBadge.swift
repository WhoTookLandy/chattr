import SwiftUI

/// "2h 50m" on a stream thumbnail — the companion to `LiveBadge`'s viewer
/// count. Same solid black backdrop as `LiveBadge(style: .overlay)` (glass
/// doesn't hold contrast over arbitrary video frames). Static text, not a
/// ticking timer: list surfaces shouldn't re-render every second.
struct StreamUptimeBadge: View {
    let startedAt: Date

    var body: some View {
        let uptime = StreamFormatting.uptime(since: startedAt)
        Text(uptime)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.black.opacity(0.65), in: Capsule())
            .accessibilityLabel("Live for \(uptime)")
    }
}
