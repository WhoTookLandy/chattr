#if os(iOS)
import SwiftUI
import Core
import TwitchKit
import NukeUI
import Nuke

/// Unified popover opened by tapping `ChatHeaderBar`'s smart dock.
///
/// Combines two jobs into one crisp glass popover so tapping the dock never
/// has ambiguous hit zones:
///   1. Full stream details for the visible channel (unwrapped title, game
///      chip, live viewers / ticking uptime, tags, Stop Audio when listening,
///      and `ChannelActionRow`).
///   2. Open-chats quick switcher (same rows + Edit Chats footer as before).
struct ChatHeaderPopover: View {
    let chatTabs: ChatTabsModel
    let liveStream: TwitchStream?
    let status: ChannelStatusStore.Status?
    let condensedMode: CondensedStreamMode?
    let onDismiss: () -> Void
    let onStopStream: () -> Void
    var onOpenMixer: () -> Void = {}
    let onEditChats: () -> Void

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.playback) private var playback
    @Environment(\.colorScheme) private var colorScheme

    private var visibleTabId: UUID? {
        chatTabs.activeTabId ?? chatTabs.tabs.first?.id
    }

    private var visibleChannel: ChannelDescriptor? {
        guard let visibleTabId else { return nil }
        return chatTabs.tabs.first(where: { $0.id == visibleTabId })?.channels.first
    }

    private var streamTitle: String? {
        if let liveStream, !liveStream.title.isEmpty { return liveStream.title }
        if let title = status?.channelInfo?.title, !title.isEmpty { return title }
        return nil
    }

    private var gameName: String? {
        if let liveStream, !liveStream.gameName.isEmpty { return liveStream.gameName }
        if let game = status?.channelInfo?.gameName, !game.isEmpty { return game }
        return nil
    }

    private var tags: [String] {
        liveStream?.tags ?? status?.channelInfo?.tags ?? []
    }

    private var isFollowing: Bool {
        guard let channelId = visibleChannel?.channelId else { return false }
        return followsStore?.channels.contains { $0.broadcasterId == channelId } ?? false
    }

    private var gameChipForeground: Color {
        colorScheme == .dark
            ? Color(red: 0xC4 / 255, green: 0xB5 / 255, blue: 0xFD / 255)
            : Color(red: 0x6D / 255, green: 0x28 / 255, blue: 0xD9 / 255)
    }

    private var gameChipBackground: Color {
        colorScheme == .dark
            ? Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255).opacity(0.20)
            : Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255).opacity(0.12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let visibleChannel {
                streamDetailsSection(channel: visibleChannel)
                Divider()
                    .padding(.vertical, 4)
            }
            openChatsSection
            if let playback, !playback.pinnedAudio.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                Button {
                    onOpenMixer()
                } label: {
                    Label("Audio Mixer (\(playback.pinnedAudio.count))", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
                .padding(.vertical, 4)
            Button {
                onEditChats()
            } label: {
                Label("Edit chats", systemImage: "pencil")
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .frame(width: 320, alignment: .leading)
    }

    private func streamDetailsSection(channel: ChannelDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let streamTitle {
                Text(streamTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if let gameName {
                    Text(gameName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(gameChipForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(gameChipBackground, in: Capsule())
                        .lineLimit(1)
                }

                if let liveStream {
                    HStack(spacing: 3) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(StreamFormatting.viewers(liveStream.viewerCount))
                            .monospacedDigit()
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(liveStream.startedAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    Text(offlineText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if let playback, PlayerSettings.isNativePlaybackEnabled,
                   liveStream != nil || condensedMode == .pinnedAudio {
                    PopoverChannelPinPill(
                        channel: channel,
                        liveStream: liveStream,
                        profileImageURL: channel.profileImageURL ?? followsStore?.profileImageURLs[channel.channelId],
                        playback: playback
                    )
                }

                if let condensedMode, condensedMode != .pinnedAudio {
                    Button(role: .destructive, action: onStopStream) {
                        Text(condensedMode == .audioOnly ? "Stop Audio" : "Stop")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.red.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            if !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(tags.prefix(6), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            ChannelActionRow(channel: channel, isFollowing: isFollowing)
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var openChatsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chatTabs.tabs) { tab in
                let channel = tab.channels.first
                let tabStream = channel.flatMap {
                    ChannelStatusStore.liveStream(for: $0.channelId, status: channelStatus, follows: followsStore)
                }
                HStack(spacing: 8) {
                    Button {
                        chatTabs.activeTabId = tab.id
                        onDismiss()
                    } label: {
                        HStack(spacing: 10) {
                            tabAvatar(tab, size: 28)
                            Text(tab.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            ChannelLiveDot(channelId: channel?.channelId)
                            Spacer(minLength: 8)
                            if chatTabs.mentionedTabIds.contains(tab.id) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel("Mentioned you")
                            }
                            if tab.id == visibleTabId {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Sibling button (never nested inside the switch-channel button)
                    // for 1-tap background audio pinning on live channels.
                    if let channel, let playback, PlayerSettings.isNativePlaybackEnabled,
                       tabStream != nil || playback.isPinnedAudio(channel.channelId) {
                        PopoverRowPinButton(
                            channel: channel,
                            stream: tabStream,
                            profileImageURL: tab.profileImageURL ?? followsStore?.profileImageURLs[channel.channelId],
                            isVisibleChannel: tab.id == visibleTabId,
                            playback: playback
                        )
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var offlineText: String {
        guard let status else { return "Checking status…" }
        if let lastLive = status.lastLiveAt {
            return "Offline · \(StreamFormatting.lastLiveShort(lastLive))"
        }
        return "Offline"
    }

    private func tabAvatar(_ tab: ChatTab, size: CGFloat) -> some View {
        LazyImage(request: ImageRequest.avatar(url: tab.profileImageURL, side: size)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Pin / Unpin pill in the visible channel's stream-details header.
private struct PopoverChannelPinPill: View {
    let channel: ChannelDescriptor
    let liveStream: TwitchStream?
    let profileImageURL: URL?
    let playback: PlaybackCenter

    private var isPinned: Bool {
        playback.pinnedAudioFlag(for: channel.channelId).isPinned
    }

    private var canPin: Bool {
        isPinned || playback.pinnedAudio.count < PlaybackCenter.maxPinnedAudioSlots
    }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isPinned {
                    // Collapse `isExpanded` so unpinning the visible channel
                    // doesn't immediately reopen inline video.
                    UserDefaults.standard.set(false, forKey: StreamHeaderView.expandedKey)
                    playback.unpinBackgroundAudio(channelId: channel.channelId)
                } else {
                    _ = playback.pinBackgroundAudio(
                        channel,
                        title: liveStream?.title ?? "",
                        profileImageURL: profileImageURL,
                        stream: liveStream
                    )
                }
            }
        } label: {
            Text(isPinned ? "Unpin Audio" : "Pin Audio")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isPinned ? .red : Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (isPinned ? Color.red : Color.accentColor).opacity(0.14),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!canPin)
        .opacity(canPin ? 1 : 0.45)
        .retainsPinnedAudioFlag(for: channel.channelId, in: playback)
    }
}

/// Trailing sibling button on each live open-chat row in `ChatHeaderPopover`.
private struct PopoverRowPinButton: View {
    let channel: ChannelDescriptor
    let stream: TwitchStream?
    let profileImageURL: URL?
    let isVisibleChannel: Bool
    let playback: PlaybackCenter

    private var isPinned: Bool {
        playback.pinnedAudioFlag(for: channel.channelId).isPinned
    }

    private var isAtCapacity: Bool {
        !isPinned && playback.pinnedAudio.count >= PlaybackCenter.maxPinnedAudioSlots
    }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isPinned {
                    if isVisibleChannel {
                        UserDefaults.standard.set(false, forKey: StreamHeaderView.expandedKey)
                    }
                    playback.unpinBackgroundAudio(channelId: channel.channelId)
                } else {
                    _ = playback.pinBackgroundAudio(
                        channel,
                        title: stream?.title ?? "",
                        profileImageURL: profileImageURL,
                        stream: stream
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "headphones")
                    .font(.caption2.weight(.semibold))
                if isPinned {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .semibold))
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: true)
                } else {
                    Text("Listen")
                        .font(.caption2.weight(.semibold))
                }
            }
            .foregroundStyle(isPinned ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                isPinned ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isPinned ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.12),
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(isAtCapacity)
        .opacity(isAtCapacity ? 0.4 : 1)
        .accessibilityLabel(isPinned ? "Stop background audio for \(channel.channelDisplayName)" : "Listen to \(channel.channelDisplayName) in background")
        .retainsPinnedAudioFlag(for: channel.channelId, in: playback)
    }
}
#endif
