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
    /// `.full`: heart + share + Gift + Subscribe across the width (compact
    /// card). `.compact`: just Gift / Subscribe, right-aligned — the
    /// watching layout, where share lives on the video.
    var style: Style = .full

    enum Style { case full, compact }

    @Environment(\.openURL) private var openURL

    /// Twitch brand purple (#9146FF) — Subscribe reads as Twitch's action,
    /// not a generic iOS button.
    private static let twitchPurple = Color(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255)
    private static let height: CGFloat = 36

    private var channelURL: URL? {
        Endpoints.TwitchWeb.channel(login: channel.channelLoginName)
    }

    private var subsURL: URL? {
        Endpoints.TwitchWeb.subscribe(login: channel.channelLoginName)
    }

    var body: some View {
        switch style {
        case .full: fullRow
        case .compact: compactRow
        }
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            giftButton(expands: false)
            subscribeButton(expands: false)
        }
    }

    private var fullRow: some View {
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

            giftButton(expands: true)
            subscribeButton(expands: true)
        }
    }

    private func giftButton(expands: Bool) -> some View {
        Button {
            if let subsURL { openURL(subsURL) }
        } label: {
            Text("Gift a Sub")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, expands ? 0 : 16)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: Self.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func subscribeButton(expands: Bool) -> some View {
        Button {
            if let subsURL { openURL(subsURL) }
        } label: {
            Text("Subscribe")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, expands ? 0 : 16)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: Self.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Self.twitchPurple).interactive(), in: Capsule())
    }
}
