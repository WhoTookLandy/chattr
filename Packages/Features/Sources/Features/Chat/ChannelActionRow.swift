import SwiftUI
import Core

/// Channel actions under the stream header — chattr's take on Twitch's
/// ♥ / share / Gift a Sub / Subscribe row.
///
/// Twitch's API no longer lets third-party apps follow, unfollow or toggle
/// go-live notifications, and subscriptions are purchased on Twitch. So:
/// follow state is shown read-only, and Subscribe / Gift hand off to the
/// channel's Twitch subs page (universal link → Twitch app when installed).
///
/// Everything is one 36pt height: heart and share are matching glass
/// circles, Gift / Subscribe split the remaining width.
struct ChannelActionRow: View {
    let channel: ChannelDescriptor
    let isFollowing: Bool

    @Environment(\.openURL) private var openURL

    /// Twitch brand purple (#9146FF) — Subscribe reads as Twitch's action,
    /// not a generic iOS button.
    private static let twitchPurple = Color(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255)
    private static let height: CGFloat = 36

    private var channelURL: URL? {
        URL(string: "https://www.twitch.tv/\(channel.channelLoginName)")
    }

    private var subsURL: URL? {
        URL(string: "https://www.twitch.tv/subs/\(channel.channelLoginName)")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isFollowing ? "heart.fill" : "heart")
                .font(.body)
                .foregroundStyle(isFollowing ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                .frame(width: Self.height, height: Self.height)
                .glassEffect(.regular, in: Circle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isFollowing ? "You follow \(channel.channelDisplayName)" : "You don't follow \(channel.channelDisplayName)")

            if let channelURL {
                ShareLink(item: channelURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(width: Self.height, height: Self.height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Share channel")
            }

            Button {
                if let subsURL { openURL(subsURL) }
            } label: {
                Text("Gift a Sub")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: Self.height)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())

            Button {
                if let subsURL { openURL(subsURL) }
            } label: {
                Text("Subscribe")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: Self.height)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Self.twitchPurple).interactive(), in: Capsule())
        }
    }
}
