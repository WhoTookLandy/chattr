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
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            @unknown default:
                Color.clear
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    /// Compact "LIVE • 12.3K" pill. The red dot is an SF Symbol so it can
    /// pulse via `.symbolEffect(.pulse, options: .repeating)` — communicates
    /// "live, right now" more clearly than a static circle. The system
    /// down-modulates the effect under Reduce Motion automatically.
    @ViewBuilder
    private func liveBadge(viewerCount: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            Text(viewerCount.formatted(.number.notation(.compactName)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        // Liquid Glass capsule — same visual family as `ChatTabStrip`'s
        // tab pills (small chrome indicator, capsule shape, sits over
        // varying content). Regular variant, not Clear: ChannelRow is a
        // standard list row, not media-rich content, so the Clear
        // variant's three-condition requirement (media + dimming +
        // bold/bright content) doesn't apply. Regular gives automatic
        // legibility over whatever's behind, which is what we want here.
        .glassEffect(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live, \(viewerCount.formatted(.number.notation(.compactName))) viewers")
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
