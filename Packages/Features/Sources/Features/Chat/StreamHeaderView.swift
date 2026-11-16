import SwiftUI
import TwitchKit
import Core
import NukeUI
import Nuke

/// Stream context above a channel's chat — the "what am I watching chat
/// for?" answer Twitch's stream screen gives and our chat screen didn't.
///
/// Collapsed (default) it's one compact row:
///
///   [avatar] Stream title text…                       ⌄
///            Just Chatting · ● 41 · 2:50:19
///
/// Expanded (tap) it adds a 16:9 preview thumbnail (tap → watch on Twitch;
/// the stand-in until in-app playback ships), the full title, tags and the
/// channel action row. Offline channels show their current title/category
/// plus "Offline · Streamed 2 days ago".
///
/// Reads `FollowsStore` + `ChannelStatusStore` itself (not via ChatScreen)
/// so status refreshes re-render only this header, never the chat screen.
/// Refresh polling lives in `HomeScreen`, batched across open tabs.
struct StreamHeaderView: View {
    let channel: ChannelDescriptor

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.openURL) private var openURL

    /// Shared across every chat page — "I like the big header" is a user
    /// preference, not a per-channel one.
    @AppStorage("chattr.chat.streamHeaderExpanded") private var isExpanded = false

    private var stream: TwitchStream? {
        ChannelStatusStore.liveStream(for: channel.channelId, status: channelStatus, follows: followsStore)
    }

    private var status: ChannelStatusStore.Status? {
        channelStatus?.statuses[channel.channelId]
    }

    private var profileImageURL: URL? {
        channel.profileImageURL ?? followsStore?.profileImageURLs[channel.channelId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                compactRow
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapses stream info" : "Expands stream info")

            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Compact row

    private var compactRow: some View {
        HStack(alignment: .center, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? 3 : 1)
                metaLine
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    /// Category · live dot + viewers · ticking uptime — or the offline line.
    @ViewBuilder
    private var metaLine: some View {
        if let stream {
            HStack(spacing: 6) {
                if !stream.gameName.isEmpty {
                    Text(stream.gameName)
                        .lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                }
                HStack(spacing: 3) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(StreamFormatting.viewers(stream.viewerCount))
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Live, \(stream.viewerCount) viewers")
                Text("·").foregroundStyle(.tertiary)
                // Counts up from the stream start (h:mm:ss), like Twitch's
                // player overlay. Only this Text re-renders per tick.
                Text(stream.startedAt, style: .timer)
                    .monospacedDigit()
                    .accessibilityLabel("Live for \(StreamFormatting.uptime(since: stream.startedAt))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                if let game = status?.channelInfo?.gameName, !game.isEmpty {
                    Text(game).lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(offlineText)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var titleText: String {
        if let stream, !stream.title.isEmpty { return stream.title }
        if let title = status?.channelInfo?.title, !title.isEmpty { return title }
        return channel.channelDisplayName
    }

    private var offlineText: String {
        guard status != nil else { return "Checking status…" }
        if let lastLive = status?.lastLiveAt {
            return "Offline · \(StreamFormatting.lastLive(lastLive))"
        }
        return "Offline"
    }

    private var avatar: some View {
        LazyImage(request: ImageRequest.avatar(url: profileImageURL, side: 32)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .overlay {
            if stream != nil {
                Circle().strokeBorder(.red, lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expandedContent: some View {
        if let stream {
            thumbnail(for: stream)
        }
        if let tags = (stream?.tags ?? status?.channelInfo?.tags), !tags.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tags.prefix(6), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        ChannelActionRow(
            channel: channel,
            isFollowing: followsStore?.channels.contains { $0.broadcasterId == channel.channelId } ?? false
        )
    }

    /// Preview frame — the seam where in-app playback will slot in. Tapping
    /// opens the stream on Twitch (the universal link hands off to the
    /// Twitch app when installed).
    private func thumbnail(for stream: TwitchStream) -> some View {
        Button {
            if let url = URL(string: "https://www.twitch.tv/\(channel.channelLoginName)") {
                openURL(url)
            }
        } label: {
            LazyImage(url: StreamFormatting.thumbnailURL(stream.thumbnailUrl, width: 640, height: 360)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                Image(systemName: "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .overlay(alignment: .bottomLeading) {
                LiveBadge(viewerCount: stream.viewerCount, style: .overlay)
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Watch \(channel.channelDisplayName) on Twitch")
    }
}
