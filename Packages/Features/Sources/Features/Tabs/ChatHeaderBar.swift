#if os(iOS)
import SwiftUI
import Core
import TwitchKit

/// The 44pt floating Liquid Glass top bar for Audio-Only, PiP, and Chat-Only
/// modes.
///
/// Replaces both the cramped 3-island system nav bar and the ~60pt stacked
/// `compactCard` with a single 44pt row:
///
///   `[ < ]`  `[ hello_kiko · ● 2.2K ⌄  |  [waveform ⏸ | 🎥] ]`
///            `  Just Chatting · cozy late night chatting…`
///
/// Hides automatically while inline video is playing (portrait or landscape),
/// where the video overlay carries its own back button and switcher.
///
/// Extracted as its own view so live-viewer polls, playback state, and
/// background mention dots invalidate ONLY this bar — never `ChatPagerScreen`
/// or the mounted `ChatScreen` pages.
struct ChatHeaderBar: View {
    let chatTabs: ChatTabsModel
    /// False in the split-view detail column (iPad / unfolded foldable), where
    /// the open-chats sidebar sits beside the chat and there is no back stack.
    let showsBackButton: Bool
    @Binding var showPopover: Bool
    let onBack: () -> Void
    let onEditChats: () -> Void

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.playback) private var playback
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false

    private var visibleTab: ChatTab? {
        guard let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id else { return nil }
        return chatTabs.tabs.first(where: { $0.id == visibleId })
    }

    private var visibleChannel: ChannelDescriptor? {
        visibleTab?.channels.first
    }

    /// Live stream for the visible tab: the polled stream, or the lingering
    /// stream still playing through a single poll that left it out.
    private var liveStream: TwitchStream? {
        guard let channelId = visibleChannel?.channelId else { return nil }
        let polled = ChannelStatusStore.liveStream(for: channelId, status: channelStatus, follows: followsStore)
        return playback?.stream(for: channelId, live: polled) ?? polled
    }

    private var status: ChannelStatusStore.Status? {
        guard let channelId = visibleChannel?.channelId else { return nil }
        return channelStatus?.statuses[channelId]
    }

    private var condensedMode: CondensedStreamMode? {
        CondensedStreamMode.resolve(
            channelId: visibleChannel?.channelId,
            isLive: liveStream != nil,
            isExpanded: isExpanded,
            audioOnly: audioOnly,
            playback: playback
        )
    }

    /// True while inline video is visible on screen — the video player's own
    /// overlay takes over back / switcher controls, so this bar collapses to 0pt.
    private var hidesForInlineVideo: Bool {
        Self.shouldHideForInlineVideo(
            isLive: liveStream != nil,
            isExpanded: isExpanded,
            condensedMode: condensedMode
        )
    }

    static func shouldHideForInlineVideo(
        isLive: Bool,
        isExpanded: Bool,
        condensedMode: CondensedStreamMode?
    ) -> Bool {
        isLive && isExpanded && condensedMode == nil
    }

    private var hasBackgroundMention: Bool {
        let activeId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id
        return !chatTabs.mentionedTabIds.subtracting([activeId].compactMap { $0 }).isEmpty
    }

    private var gameAccent: Color {
        colorScheme == .dark
            ? Color(red: 0xC4 / 255, green: 0xB5 / 255, blue: 0xFD / 255)
            : Color(red: 0x6D / 255, green: 0x28 / 255, blue: 0xD9 / 255)
    }

    var body: some View {
        Group {
            if !hidesForInlineVideo {
                barContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: hidesForInlineVideo)
        .animation(.snappy(duration: 0.25), value: condensedMode)
    }

    private var barContent: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if showsBackButton {
                    backButton
                }
                dockCapsule
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Back")
    }

    private var dockCapsule: some View {
        HStack(spacing: 6) {
            infoButton
            if liveStream != nil {
                transportPill
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, liveStream != nil ? 4 : 14)
        .frame(minHeight: 42)
        .glassEffect(.regular, in: Capsule())
        // Pull down on the dock to expand straight into video, matching the
        // muscle memory of the old compact stream card.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                guard value.translation.height > 40, liveStream != nil else { return }
                if condensedMode == .pictureInPicture {
                    playback?.controller.togglePictureInPicture()
                } else {
                    startVideo()
                }
            }
        )
    }

    private var infoButton: some View {
        Button { showPopover = true } label: {
            VStack(alignment: .leading, spacing: 1) {
                topLine
                subLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(chatTabs.tabs.isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dockAccessibilityLabel)
        .accessibilityHint("Shows stream details and switches channels")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            ChatHeaderPopover(
                chatTabs: chatTabs,
                liveStream: liveStream,
                status: status,
                condensedMode: condensedMode,
                onDismiss: { showPopover = false },
                onStopStream: {
                    showPopover = false
                    stopStream()
                },
                onEditChats: onEditChats
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var topLine: some View {
        HStack(spacing: 5) {
            Text(visibleTab?.displayName ?? "Chat")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let liveStream {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text(StreamFormatting.viewers(liveStream.viewerCount))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .fixedSize()
                .layoutPriority(1)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .layoutPriority(1)

            if hasBackgroundMention {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .layoutPriority(1)
            }

            pageDots
        }
    }

    @ViewBuilder
    private var subLine: some View {
        if let liveStream {
            let game = liveStream.gameName
            let title = liveStream.title
            if !game.isEmpty || !title.isEmpty {
                HStack(spacing: 4) {
                    if !game.isEmpty {
                        Text(game)
                            .fontWeight(.semibold)
                            .foregroundStyle(gameAccent)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if !game.isEmpty && !title.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    if !title.isEmpty {
                        Text(title)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
            }
        } else if visibleChannel != nil {
            Text(offlineSublineText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var offlineSublineText: String {
        guard let status else { return "Checking status…" }
        var parts = ["Offline"]
        if let lastLive = status.lastLiveAt {
            parts.append(StreamFormatting.lastLiveShort(lastLive))
        }
        if let game = status.channelInfo?.gameName, !game.isEmpty {
            parts.append(game)
        }
        return parts.joined(separator: " · ")
    }

    /// Miniature page dots — one per open tab when 2+ tabs are open.
    @ViewBuilder
    private var pageDots: some View {
        if chatTabs.tabs.count > 1 {
            let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id
            HStack(spacing: 3) {
                ForEach(chatTabs.tabs.prefix(7)) { tab in
                    Circle()
                        .fill(chatTabs.mentionedTabIds.contains(tab.id)
                            ? AnyShapeStyle(.red)
                            : tab.id == visibleId
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.secondary.opacity(0.35)))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.leading, 2)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Embedded transport sub-pill

    @ViewBuilder
    private var transportPill: some View {
        if let condensedMode, let player = playback?.controller {
            activeTransportPill(condensedMode, player: player)
        } else {
            chatOnlyTransportPill
        }
    }

    private func activeTransportPill(_ mode: CondensedStreamMode, player: StreamPlayerController) -> some View {
        let isActivePlaying = mode == .pictureInPicture || !player.isPaused
        return HStack(spacing: 0) {
            switch mode {
            case .audioOnly:
                Button { player.togglePlay() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isActivePlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isActivePlaying)
                        Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPaused ? "Play audio" : "Pause audio")

                subPillDivider

                Button(action: startVideo) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show video")

            case .pictureInPicture:
                Button { player.togglePictureInPicture() } label: {
                    Image(systemName: "pip.exit")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show video here")
            }
        }
        .background(
            isActivePlaying ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.09),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    isActivePlaying ? Color.accentColor.opacity(0.36) : Color.primary.opacity(0.14),
                    lineWidth: 0.5
                )
        }
        .contextMenu {
            switch mode {
            case .audioOnly:
                Button(player.isPaused ? "Play" : "Pause",
                       systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                    player.togglePlay()
                }
                Button("Show Video", systemImage: "video.fill") { startVideo() }
                Divider()
                Button("Stop Audio", systemImage: "xmark", role: .destructive) { stopStream() }
            case .pictureInPicture:
                Button("Show Video Here", systemImage: "pip.exit") {
                    player.togglePictureInPicture()
                }
                Divider()
                Button("Stop Stream", systemImage: "xmark", role: .destructive) { stopStream() }
            }
        }
    }

    private var chatOnlyTransportPill: some View {
        HStack(spacing: 0) {
            if PlayerSettings.isNativePlaybackEnabled {
                Button(action: startAudioOnly) {
                    Image(systemName: "headphones")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Listen audio only")

                subPillDivider
            }

            Button(action: startVideo) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Watch video")
        }
        .background(Color.primary.opacity(0.08), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }

    private var subPillDivider: some View {
        Rectangle()
            .fill(.secondary.opacity(0.3))
            .frame(width: 0.5, height: 15)
    }

    // MARK: - Playback actions

    private func startAudioOnly() {
        withAnimation(.snappy(duration: 0.25)) {
            audioOnly = true
            isExpanded = true
        }
    }

    private func startVideo() {
        withAnimation(.snappy(duration: 0.25)) {
            audioOnly = false
            isExpanded = true
        }
    }

    private func stopStream() {
        withAnimation(.snappy(duration: 0.25)) {
            isExpanded = false
            audioOnly = false
        }
        playback?.stop()
    }

    private var dockAccessibilityLabel: String {
        let name = visibleTab?.displayName ?? "Chat"
        if let liveStream {
            var parts = [name, "Live", "\(liveStream.viewerCount) viewers"]
            if !liveStream.gameName.isEmpty { parts.append(liveStream.gameName) }
            if !liveStream.title.isEmpty { parts.append(liveStream.title) }
            if condensedMode == .audioOnly { parts.append("Audio only") }
            if condensedMode == .pictureInPicture { parts.append("Picture in picture") }
            if hasBackgroundMention { parts.append("Unread mention in another chat") }
            return parts.joined(separator: ", ")
        }
        return "\(name), \(offlineSublineText)"
    }
}
#endif
