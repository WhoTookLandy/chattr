import SwiftUI
import Core

/// Channel actions under the expanded stream header — chattr's take on
/// Twitch's ♥ / 🔔 / Gift a Sub / Subscribe row.
///
/// Twitch's API no longer lets third-party apps follow, unfollow or toggle
/// go-live notifications, and subscriptions are purchased on Twitch. So:
/// follow state is shown read-only, and Subscribe / Gift hand off to the
/// channel's Twitch subs page (universal link → Twitch app when installed).
struct ChannelActionRow: View {
    let channel: ChannelDescriptor
    let isFollowing: Bool

    @Environment(\.openURL) private var openURL

    private var channelURL: URL? {
        URL(string: "https://www.twitch.tv/\(channel.channelLoginName)")
    }

    private var subsURL: URL? {
        URL(string: "https://www.twitch.tv/subs/\(channel.channelLoginName)")
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(isFollowing ? "Following" : "Not following",
                  systemImage: isFollowing ? "heart.fill" : "heart")
                .labelStyle(.iconOnly)
                .font(.body)
                .foregroundStyle(isFollowing ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 36)
                .glassEffect(.regular, in: Capsule())
                .accessibilityLabel(isFollowing ? "You follow \(channel.channelDisplayName)" : "You don't follow \(channel.channelDisplayName)")

            if let channelURL {
                ShareLink(item: channelURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .frame(width: 40, height: 36)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Share channel")
            }

            Button {
                if let subsURL { openURL(subsURL) }
            } label: {
                Text("Gift a Sub")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)

            Button {
                if let subsURL { openURL(subsURL) }
            } label: {
                Text("Subscribe")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
        .controlSize(.regular)
    }
}
