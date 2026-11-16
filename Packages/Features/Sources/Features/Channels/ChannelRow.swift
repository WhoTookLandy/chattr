import SwiftUI
import TwitchKit
import Nuke
import NukeUI

/// Single row in the followed-channels list. Shows the broadcaster's avatar,
/// display name, login, and — if the channel is currently live — a "LIVE"
/// indicator plus viewer count and game name.
///
/// Pure presentational struct: takes plain identity fields rather than a
/// `FollowedChannel` or `TwitchStream`, with convenience inits for either
/// source. The Live view uses the `TwitchStream` init; the All view uses the
/// `FollowedChannel` init. Both share this single row.
struct ChannelRow: View {
    let displayName: String
    let loginName: String
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
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let stream {
                        LiveBadge(viewerCount: stream.viewerCount, style: .listRow)
                    }
                }
                subtitle
            }
        }
        .padding(.vertical, 2)
    }

    // The "LIVE • 12.3K" pill lives in the shared `LiveBadge` (style `.listRow`).

    /// Two-line layout uses the second line for either game/title (live) or
    /// the login handle (offline).
    @ViewBuilder
    private var subtitle: some View {
        if let stream, !stream.gameName.isEmpty {
            Text("@\(loginName) • \(stream.gameName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("@\(loginName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 40pt circle avatar.
    @ViewBuilder
    private var avatar: some View {
        LazyImage(request: ImageRequest.avatar(url: profileImageURL, side: 40)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

}

// MARK: - Convenience inits

extension ChannelRow {
    /// Initialize from a `FollowedChannel` (the All view's data source).
    ///
    /// There used to be a `TwitchStream`-source overload here too, but the
    /// Live tab moved to `LiveStreamRow` (with thumbnail + game + tags) so
    /// this row is now All-tab-only. If we ever bring a compact stream view
    /// back, restore the TwitchStream convenience init.
    init(channel: FollowedChannel, stream: TwitchStream?, profileImageURL: URL?) {
        self.init(
            displayName: channel.broadcasterName,
            loginName: channel.broadcasterLogin,
            stream: stream,
            profileImageURL: profileImageURL
        )
    }
}
