import SwiftUI
import TwitchKit
import NukeUI
import Nuke

/// One row of the Chats list. Was avatar + name + "#login"; now carries the
/// same live context Home does, so the list answers "who's live, with what,
/// and how busy?" without opening each chat:
///
///   (avatar)  soochu                         ●
///    ring     ● 41 · Just Chatting · 2h 50m
///             Twitch con day 4 best ABG POV…
///
/// Offline: "Offline · 2d ago" (or "#login" while status is unknown).
/// Reads the status stores itself so a status refresh redraws rows, not the
/// whole `ChatTabsScreen` (which also owns the pager).
struct OpenChatRow: View {
    let tab: ChatTab
    /// Read for `mentionedTabIds` HERE (not by the list's owner) so a
    /// background ping redraws one row, not `ChatTabsScreen`'s body.
    let chatTabs: ChatTabsModel

    private var hasMention: Bool { chatTabs.mentionedTabIds.contains(tab.id) }

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus

    private var channelId: String? { tab.channels.first?.channelId }

    private var stream: TwitchStream? {
        channelId.flatMap { id in
            ChannelStatusStore.liveStream(for: id, status: channelStatus, follows: followsStore)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                subtitle
            }
            Spacer(minLength: 8)
            if hasMention {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Mentioned you")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var subtitle: some View {
        if let stream {
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text(liveMeta(stream))
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !stream.title.isEmpty {
                Text(stream.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(offlineText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func liveMeta(_ stream: TwitchStream) -> String {
        var parts = [StreamFormatting.viewers(stream.viewerCount)]
        if !stream.gameName.isEmpty { parts.append(stream.gameName) }
        parts.append(StreamFormatting.uptime(since: stream.startedAt))
        return parts.joined(separator: " · ")
    }

    private var offlineText: String {
        let login = tab.channels.first.map { "#\($0.channelLoginName)" } ?? ""
        guard let channelId, let status = channelStatus?.statuses[channelId] else { return login }
        if let lastLive = status.lastLiveAt {
            return "Offline · \(StreamFormatting.lastLiveShort(lastLive))"
        }
        return "Offline"
    }

    private var avatar: some View {
        LazyImage(request: ImageRequest.avatar(url: tab.profileImageURL, side: 44)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .padding(2)
        .overlay {
            // Live ring — the same "this one's on" cue as Twitch's story
            // rail, readable before the subtitle is.
            if stream != nil {
                Circle().strokeBorder(.red, lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}
