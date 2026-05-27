import SwiftUI
import TwitchKit

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
                        liveBadge(viewerCount: stream.viewerCount)
                    }
                }
                subtitle
            }
        }
        .padding(.vertical, 2)
    }

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

    /// Compact "LIVE • 12.3K" pill.
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

// MARK: - Convenience inits

extension ChannelRow {
    /// Initialize from a `FollowedChannel` (the All view's data source).
    init(channel: FollowedChannel, stream: TwitchStream?, profileImageURL: URL?) {
        self.init(
            displayName: channel.broadcasterName,
            loginName: channel.broadcasterLogin,
            stream: stream,
            profileImageURL: profileImageURL
        )
    }

    /// Initialize from a `TwitchStream` (the Live view's data source).
    /// `stream` is non-nil here because by definition the source is a live
    /// stream — the LIVE badge always shows.
    init(stream: TwitchStream, profileImageURL: URL?) {
        self.init(
            displayName: stream.userName,
            loginName: stream.userLogin,
            stream: stream,
            profileImageURL: profileImageURL
        )
    }
}
