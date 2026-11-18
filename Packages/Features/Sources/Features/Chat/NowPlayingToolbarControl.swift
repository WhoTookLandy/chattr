import SwiftUI
import Core

extension ChatTabsModel {
    /// Channel of the page the pager shows: `activeTabId`, falling back to
    /// the first tab before scene restoration runs (matching the pager).
    var visibleChannelId: String? {
        guard let visibleId = activeTabId ?? tabs.first?.id else { return nil }
        return tabs.first(where: { $0.id == visibleId })?.channels.first?.channelId
    }
}

#if os(iOS)

/// The visible chat's stream is playing without its inline video: listen-only
/// (`audioOnly`) or moved into the system PiP window. In both, the chat
/// header collapses to nothing and the stream's controls live in the
/// navigation bar instead (`NowPlayingToolbarControl`), with a glyph in the
/// channel pill naming the mode.
///
/// These used to be a glass bar under the pill that repeated the pill's name,
/// live dot and viewer count (TestFlight build 27: "would the bar with the
/// pause, video be better suited on the tab instead of the name again?").
enum CondensedStreamMode: Equatable {
    case audioOnly
    case pictureInPicture

    var systemImage: String {
        switch self {
        case .audioOnly: "headphones"
        case .pictureInPicture: "pip"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .audioOnly: "Audio only"
        case .pictureInPicture: "Playing in picture in picture"
        }
    }

    /// Mirrors `StreamHeaderView.body`'s choice for the visible page: the
    /// header is expanded and the channel is live, then audio-only wins over
    /// PiP. Audio-only needs the native engine — after a fallback to web, or
    /// with the native path switched off, the header shows the video, so
    /// there's nothing condensed.
    @MainActor
    static func resolve(
        channelId: String?,
        isLive: Bool,
        isExpanded: Bool,
        audioOnly: Bool,
        playback: PlaybackCenter?
    ) -> Self? {
        guard let channelId, isExpanded, isLive, let playback else { return nil }
        if audioOnly, PlayerSettings.isNativePlaybackEnabled, !playback.controller.nativeFailed {
            return .audioOnly
        }
        if playback.controller.isPictureInPictureActive, playback.isPlaying(channelId) {
            return .pictureInPicture
        }
        return nil
    }
}

/// Trailing navigation-bar control for a condensed stream: play/pause and
/// "show video" in audio-only, "show video here" in PiP. Long-press adds
/// Stop. Renders nothing otherwise — the toolbar item hosting it is always
/// present (inserting/removing items rebuilds the bar and flickers), only
/// its content changes.
///
/// Its own view so the status / playback reads invalidate only this, never
/// the pager body.
struct NowPlayingToolbarControl: View {
    let chatTabs: ChatTabsModel

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.playback) private var playback
    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false

    private var mode: CondensedStreamMode? {
        let channelId = chatTabs.visibleChannelId
        // Same source as the header: the polled stream, or the one still
        // playing through a single poll that left it out.
        let isLive = channelId.map { id in
            let live = ChannelStatusStore.liveStream(for: id, status: channelStatus, follows: followsStore)
            return (playback?.stream(for: id, live: live) ?? live) != nil
        } ?? false
        return CondensedStreamMode.resolve(
            channelId: channelId,
            isLive: isLive,
            isExpanded: isExpanded,
            audioOnly: audioOnly,
            playback: playback
        )
    }

    var body: some View {
        Group {
            if let mode, let player = playback?.controller {
                controls(mode, player: player)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.snappy(duration: 0.25), value: mode)
    }

    private func controls(_ mode: CondensedStreamMode, player: StreamPlayerController) -> some View {
        HStack(spacing: 0) {
            switch mode {
            case .audioOnly:
                glyphButton(player.isPaused ? "play.fill" : "pause.fill",
                            label: player.isPaused ? "Play" : "Pause") {
                    player.togglePlay()
                }
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 0.5, height: 18)
                glyphButton("video.fill", label: "Show video") { showVideo() }
            case .pictureInPicture:
                glyphButton("pip.exit", label: "Show video here") {
                    player.togglePictureInPicture()
                }
            }
        }
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contextMenu {
            switch mode {
            case .audioOnly:
                Button(player.isPaused ? "Play" : "Pause",
                       systemImage: player.isPaused ? "play.fill" : "pause.fill") {
                    player.togglePlay()
                }
                Button("Show Video", systemImage: "video.fill") { showVideo() }
                Divider()
                Button("Stop Listening", systemImage: "xmark", role: .destructive) { stop() }
            case .pictureInPicture:
                Button("Show Video Here", systemImage: "pip.exit") {
                    player.togglePictureInPicture()
                }
                Divider()
                Button("Stop Stream", systemImage: "xmark", role: .destructive) { stop() }
            }
        }
    }

    private func glyphButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func showVideo() {
        withAnimation(.snappy(duration: 0.25)) { audioOnly = false }
    }

    /// Hides the stream like the header does, and stops it here too: the
    /// header's `syncPlayback` only stops once the channel has a status entry,
    /// and this control can show on a live stream known only from follows.
    /// With `isExpanded` off, nothing restarts it.
    private func stop() {
        withAnimation(.snappy(duration: 0.25)) { isExpanded = false }
        playback?.stop()
    }
}

#endif
