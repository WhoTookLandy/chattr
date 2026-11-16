import SwiftUI

/// A small red dot (with viewer count) shown when `channelId` is live —
/// for dense rows like the chat quick switcher. Renders nothing offline.
/// Reads the status stores itself so only the dot redraws on refresh.
struct ChannelLiveDot: View {
    let channelId: String?

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus

    var body: some View {
        if let channelId,
           let stream = ChannelStatusStore.liveStream(for: channelId, status: channelStatus, follows: followsStore) {
            HStack(spacing: 3) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(StreamFormatting.viewers(stream.viewerCount))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Live, \(stream.viewerCount) viewers")
        }
    }
}
