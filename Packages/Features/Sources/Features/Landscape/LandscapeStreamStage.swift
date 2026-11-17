import SwiftUI
import TwitchKit
import Core
import Nuke
import NukeUI

/// The video half of a landscape chat page: the stream (or its poster on
/// pages that aren't the visible one) letterboxed on black, with a
/// tap-revealed overlay of the controls the portrait header carries.
///
/// Shown by `LandscapeStageLayout` only while the stream header would be
/// playing video; the header stays mounted (hidden) underneath and keeps
/// driving playback (`StreamHeaderView.syncPlayback`), so this view only
/// displays the shared engine and wires its tap / swipe callbacks.
struct LandscapeStreamStage: View {
    let channel: ChannelDescriptor
    let tabId: UUID?
    let chatSide: LandscapeChatSide
    let layoutMode: LandscapeLayoutMode

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false

    @State private var chromeVisible = false
    /// Bumped on every interaction so the auto-hide timer restarts.
    @State private var chromeInteraction = 0

    /// Same derivation as `StreamHeaderView.isActive`: only the visible
    /// pager page shows the live engine; neighbours show the poster.
    private var isActive: Bool {
        guard let tabId else { return true }
        return chatTabs?.activeTabId == tabId
    }

    /// Same derivation as `StreamHeaderView.stream`, including a stream
    /// still playing through a single offline reading.
    private var stream: TwitchStream? {
        let live = ChannelStatusStore.liveStream(for: channel.channelId, status: channelStatus, follows: followsStore)
        #if os(iOS)
        return playback?.stream(for: channel.channelId, live: live) ?? live
        #else
        return live
        #endif
    }

    private var channelURL: URL? {
        Endpoints.TwitchWeb.channel(login: channel.channelLoginName)
    }

    /// In the "over video" layout the chat covers one side, so the picture
    /// slides to the other instead of centering under the chat.
    private var videoAlignment: Alignment {
        guard layoutMode == .overlay else { return .center }
        return chatSide == .right ? .leading : .trailing
    }

    var body: some View {
        ZStack {
            // Taps on the letterbox bars toggle the chrome. Attached to
            // this backdrop and to the poster — siblings BELOW the engine,
            // never an ancestor of it — so a tap on the live video reaches
            // only the engine (which reports it via `onTap`) and can't
            // toggle the chrome twice.
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }

            if let stream {
                ZStack {
                    poster(stream)
                    playerEngine
                    #if os(iOS)
                    // The native player is waiting on the network.
                    if isActive, let player, player.isBuffering {
                        ProgressView()
                            .tint(.white)
                            .allowsHitTesting(false)
                    }
                    #endif
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: videoAlignment)

                if chromeVisible {
                    chrome(stream)
                        .transition(.opacity)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: chromeVisible)
        .task(id: chromeInteraction) {
            guard chromeVisible else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !isPlayerPaused else { return }
            chromeVisible = false
        }
        #if os(iOS)
        .onAppear { if isActive { wirePlayerCallbacks() } }
        #endif
        .onChange(of: isActive) { _, active in
            if active {
                #if os(iOS)
                wirePlayerCallbacks()
                #endif
            } else {
                chromeVisible = false
            }
        }
    }

    // MARK: - Player

    /// The shared engine's video — only on the visible page, and only
    /// while it's this channel that's playing. Mounting this `PlayerHost`
    /// claims the engine view from the (hidden) header's host; the engine
    /// itself is not rebuilt.
    @ViewBuilder
    private var playerEngine: some View {
        #if os(iOS)
        if isActive, let playback, playback.isPlaying(channel.channelId) {
            PlayerHost(center: playback)
        }
        #endif
    }

    #if os(iOS)
    private var player: StreamPlayerController? { playback?.controller }

    /// The stage owns the callbacks while it's shown — the hidden header's
    /// `wirePlayerCallbacks` stands down whenever `landscapeStage.isActive`,
    /// and takes them back when the stage goes away.
    private func wirePlayerCallbacks() {
        guard let player else { return }
        player.onTap = { toggleChrome() }
        // Swipe down on the video → picture in picture, or hide the video
        // when PiP isn't available — same as portrait.
        // Weak: the player stores this closure, so holding the player in
        // it would keep the controller (and its `PlaybackCenter`) alive
        // past sign-out.
        player.onSwipeDown = { [weak player] in
            guard let player else { return }
            if player.canPictureInPicture {
                chromeVisible = false
                player.togglePictureInPicture()
            } else {
                hideVideo()
            }
        }
    }
    #endif

    private var isPlayerPaused: Bool {
        #if os(iOS)
        player?.isPaused ?? false
        #else
        false
        #endif
    }

    private func toggleChrome() {
        chromeVisible.toggle()
        chromeInteraction += 1
    }

    private func touchChrome() {
        chromeInteraction += 1
    }

    private func hideVideo() {
        chromeVisible = false
        withAnimation(.snappy(duration: 0.25)) { isExpanded = false }
    }

    private func poster(_ stream: TwitchStream) -> some View {
        LazyImage(request: StreamFormatting.thumbnailRequest(stream.thumbnailUrl, width: 1280, height: 720)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { toggleChrome() }
        .accessibilityLabel("\(channel.channelDisplayName) stream")
    }

    // MARK: - Chrome

    private func chrome(_ stream: TwitchStream) -> some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.6), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.6), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    glyphButton("chevron.left", label: "Back") { dismiss() }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(channel.channelDisplayName)
                                .font(.subheadline.weight(.bold))
                            if !stream.gameName.isEmpty {
                                Text("· \(stream.gameName)")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .lineLimit(1)
                        if !stream.title.isEmpty {
                            Text(stream.title)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .padding(.top, 6)
                    Spacer(minLength: 8)
                    if let channelURL {
                        ShareLink(item: channelURL) { glyph("square.and.arrow.up") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Share channel")
                    }
                    glyphButton("rectangle.slash", label: "Hide video") { hideVideo() }
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    chip {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(stream.startedAt, style: .timer)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live for \(StreamFormatting.uptime(since: stream.startedAt))")
                    chip {
                        Image(systemName: "person.fill")
                        Text(StreamFormatting.viewers(stream.viewerCount))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(stream.viewerCount) viewers")
                    Spacer(minLength: 0)
                    #if os(iOS)
                    if let player {
                        glyphButton(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    label: player.isMuted ? "Unmute" : "Mute") {
                            player.toggleMute()
                            touchChrome()
                        }
                        if player.canPictureInPicture {
                            glyphButton("pip.enter", label: "Picture in Picture") {
                                player.togglePictureInPicture()
                                touchChrome()
                            }
                        }
                        glyphButton("arrow.up.left.and.arrow.down.right", label: "Full screen") {
                            player.enterFullscreen()
                            touchChrome()
                        }
                    }
                    #endif
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            #if os(iOS)
            if isActive, let player {
                Button {
                    player.togglePlay()
                    touchChrome()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .frame(width: 72, height: 72)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            }
            #endif
        }
    }

    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 3)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }

    private func glyphButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(systemImage) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4, content: content)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
