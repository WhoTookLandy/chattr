import SwiftUI
import TwitchKit

/// Single row in the followed-channels list. Shows the broadcaster's avatar,
/// display name, login, and — if the channel is currently live — a "LIVE"
/// indicator plus viewer count and game name.
///
/// Stays presentational: all data is passed in. The parent screen owns the
/// dictionaries of live streams + user profiles and looks up the row's slice
/// each render.
struct ChannelRow: View {
    let channel: FollowedChannel
    /// Non-nil if the channel is currently live.
    let stream: TwitchStream?
    /// Profile image URL once `fetchUsers` has populated it. While nil we show a
    /// placeholder so layout doesn't reflow when the image lands.
    let profileImageURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(channel.broadcasterName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let stream {
                        liveBadge(viewerCount: stream.viewerCount)
                    }
                }
                subtitle
            }
        }
        .padding(.vertical, 2)
    }

    /// Two-line layout uses the second line for either game/title (live) or
    /// the login handle (offline). Live channels still surface the login via
    /// the display name being distinct from broadcasterLogin on Twitch.
    @ViewBuilder
    private var subtitle: some View {
        if let stream, !stream.gameName.isEmpty {
            Text("@\(channel.broadcasterLogin) • \(stream.gameName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("@\(channel.broadcasterLogin)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 40pt circle avatar. `AsyncImage` shows a person glyph until the URL
    /// is populated (we don't pre-fetch — first paint shows placeholder, then
    /// the image appears once the enrichment fetch lands).
    @ViewBuilder
    private var avatar: some View {
        AsyncImage(url: profileImageURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty, .failure:
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.5))
            @unknown default:
                Color.clear
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    /// Compact "LIVE • 12.3K" pill. Uses regularMaterial so it adapts to light/dark.
    /// `contentTransition(.numericText())` morphs viewer-count digits smoothly when
    /// the next /streams/followed poll updates the value.
    @ViewBuilder
    private func liveBadge(viewerCount: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
            Text(viewerCount.formatted(.number.notation(.compactName)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
    }
}
