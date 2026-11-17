import SwiftUI
import TwitchKit
import Core
import DesignSystem
import NukeUI
import Nuke

/// Stream context above a channel's chat.
///
/// Two layouts, driven by the shared "expanded" preference:
///
/// **Watching** (expanded + live) — the stream plays in-app, flush under a
/// black status-bar strip (the pager hides the nav bar; see
/// `ChatNavBarAutoHider`):
///
///   ┌────────── video ──────────┐   tap → controls, ‹ back, ⌄ hide video,
///   └───────────────────────────┘          tags + Gift / Subscribe (4s)
///   [avatar] HasanAbi · Just Chatting · ● 44K       swipe down → hide video
///            Title, one line…
///
/// **Compact** (collapsed, or offline) — the one-row glass card:
///
///   [avatar] Stream title text…                       ▶
///            Just Chatting · ● 41 · 2:50:19
///
/// Offline channels expand to tags + actions only (nothing to play). Live
/// ones open the video on tap or pull-down.
///
/// Reads `FollowsStore` + `ChannelStatusStore` itself (not via ChatScreen)
/// so status refreshes re-render only this header, never the chat screen.
/// Refresh polling lives in `HomeScreen`, batched across open tabs.
struct StreamHeaderView: View {
    let channel: ChannelDescriptor
    /// The pager tab this header belongs to; nil outside the pager.
    let tabId: UUID?
    /// Tap on the viewer count → the viewer list (mods only; the sheet
    /// explains otherwise).
    var onShowViewers: () -> Void = {}

    /// Shared across every chat page — "I like watching while I chat" is a
    /// user preference, not a per-channel one.
    static let expandedKey = "chattr.chat.streamHeaderExpanded"

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    /// Landscape: the video is on `LandscapeStreamStage`, not here.
    @Environment(\.landscapeStage) private var landscapeStage

    @AppStorage(Self.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.nativePlayerKey) private var useNativePlayer = false
    @AppStorage(PlayerSettings.maxQualityKey) private var maxQuality: PlayerQuality = .auto
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false

    /// Player overlay + tags + action row. Hidden by default so chat keeps
    /// the room; any tap on the video or info row toggles it.
    @State private var chromeVisible = false
    /// Bumped on every interaction so the auto-hide timer restarts.
    @State private var chromeInteraction = 0

    /// Only the page centered in the pager mounts the player — neighbours
    /// stay as posters so swiping never plays two streams at once. Derived
    /// here (not passed in by `ChatScreen`) so a swipe re-runs this header,
    /// not the whole chat page; see `ChatScreen.tabId`.
    private var isActive: Bool {
        guard let tabId else { return true }
        return chatTabs?.activeTabId == tabId
    }

    #if os(iOS)
    /// App-wide player (survives leaving the chat → mini player).
    @Environment(\.playback) private var playback

    /// Stand-in so overlay bindings have something to read in previews /
    /// before the center is injected. Shared and static: as `@State` its
    /// initial value was constructed (and thrown away) on every init of this
    /// struct, i.e. every time a parent body re-ran.
    @MainActor private static let fallbackPlayer = StreamPlayerController()

    private var player: StreamPlayerController {
        playback?.controller ?? Self.fallbackPlayer
    }
    #endif

    private var stream: TwitchStream? {
        ChannelStatusStore.liveStream(for: channel.channelId, status: channelStatus, follows: followsStore)
    }

    private var status: ChannelStatusStore.Status? {
        channelStatus?.statuses[channel.channelId]
    }

    private var profileImageURL: URL? {
        channel.profileImageURL ?? followsStore?.profileImageURLs[channel.channelId]
    }

    private var tags: [String] {
        stream?.tags ?? status?.channelInfo?.tags ?? []
    }

    private var channelURL: URL? {
        URL(string: "https://www.twitch.tv/\(channel.channelLoginName)")
    }

    var body: some View {
        Group {
            if isExpanded, let stream {
                if isAudioOnlyActive {
                    audioBar(stream)
                } else if isPictureInPictureActive {
                    pictureInPictureBar(stream)
                } else {
                    watchingLayout(stream)
                }
            } else {
                compactCard
            }
        }
        .animation(.snappy(duration: 0.25), value: chromeVisible)
        .task(id: chromeInteraction) {
            guard chromeVisible else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !isPlayerPaused else { return }
            chromeVisible = false
        }
        .onChange(of: isActive) { _, active in
            if !active { chromeVisible = false }
        }
        #if os(iOS)
        // The visible chat decides what plays. Re-evaluated whenever
        // anything that shapes playback changes.
        .task(id: playbackKey) { syncPlayback() }
        .onAppear { if isActive { wirePlayerCallbacks() } }
        .onChange(of: isActive) { _, active in
            if active { wirePlayerCallbacks() }
        }
        // Callback ownership follows `landscapeStage.isActive`: while the
        // stage shows, it alone wires them (see `wirePlayerCallbacks`);
        // when it goes (portrait, PiP, video hidden) the header takes them
        // back.
        .onChange(of: landscapeStage.isActive) { _, staged in
            if !staged, isActive { wirePlayerCallbacks() }
        }
        #endif
    }

    #if os(iOS)
    private var playbackKey: String {
        "\(isActive)|\(isExpanded)|\(stream != nil)|\(status != nil)|\(audioOnly)|\(useNativePlayer)|\(maxQuality.rawValue)"
    }

    /// Only the active page acts (pages leaving — swiped away or popped —
    /// do nothing, so a popped chat's stream carries on into the mini
    /// player).
    private func syncPlayback() {
        guard isActive, let playback else { return }
        if isExpanded, let stream {
            playback.play(
                channel,
                title: stream.title,
                profileImageURL: profileImageURL,
                // Audio-only needs the native engine (see isAudioOnlyActive).
                native: useNativePlayer || audioOnly,
                audioOnly: audioOnly,
                quality: maxQuality
            )
        } else if status != nil, playback.isPlaying {
            // Video hidden here, or this channel is offline: whatever was
            // playing (this stream, or another chat's) stops. Waits for
            // `status` so a not-yet-loaded status doesn't kill the stream
            // the mini player handed back.
            playback.stop()
        }
    }

    /// Single owner: while the landscape stage shows, the stage owns the
    /// player's tap / swipe callbacks and this (hidden) header must not
    /// overwrite them — e.g. opening a chat already in landscape, or a
    /// pre-mounted neighbour becoming the visible page, fires this header's
    /// `onAppear` / `onChange(isActive)` alongside the stage's.
    private func wirePlayerCallbacks() {
        guard !landscapeStage.isActive else { return }
        player.onTap = { toggleChrome() }
        // Swipe down on the video → picture in picture (keeps watching
        // while you scroll chat or leave the app). Without PiP support,
        // it hides the video instead.
        player.onSwipeDown = {
            if player.canPictureInPicture {
                chromeVisible = false
                player.togglePictureInPicture()
            } else {
                setExpanded(false)
            }
        }
    }
    #endif

    private var isPlayerPaused: Bool {
        #if os(iOS)
        player.isPaused
        #else
        false
        #endif
    }

    /// Audio-only needs the native engine (Twitch's audio-only rendition);
    /// the web player can't play hidden — it needs a visible, full-size
    /// surface to autoplay and to show its "Start Watching" gate. So if the
    /// native engine fails, audio-only falls back to the normal video
    /// layout. Not available off iOS (no player there).
    private var isAudioOnlyActive: Bool {
        #if os(iOS)
        audioOnly && !player.nativeFailed
        #else
        false
        #endif
    }

    /// The native engine is selected and hasn't failed over to the web one.
    private var isNativeEngine: Bool {
        #if os(iOS)
        useNativePlayer && !player.nativeFailed
        #else
        false
        #endif
    }

    private func toggleChrome() {
        chromeVisible.toggle()
        chromeInteraction += 1
    }

    /// A control was used — keep the chrome up a while longer.
    private func touchChrome() {
        chromeInteraction += 1
    }

    private func setExpanded(_ expanded: Bool) {
        chromeVisible = false
        withAnimation(.snappy(duration: 0.25)) { isExpanded = expanded }
    }

    // MARK: - Watching layout

    private func watchingLayout(_ stream: TwitchStream) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            playerSurface(stream)

            // At rest it's just the video and chat. A tap on the video brings
            // in name · category · viewers, the title, tags and actions.
            if chromeVisible {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Button(action: toggleChrome) {
                            infoRow(stream)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Hides stream controls")
                        subscribeButton
                    }
                    if !tags.isEmpty {
                        // Indented to the text column, under the title.
                        tagRow.padding(.leading, 42)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .simultaneousGesture(TapGesture().onEnded { touchChrome() })
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
        .background(Color.chatSurface)
        .clipped()
    }

    /// Name · category · ● viewers, then the title. The one live signal in
    /// this layout is the red viewer dot.
    private func infoRow(_ stream: TwitchStream) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(ring: false)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(channel.channelDisplayName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !stream.gameName.isEmpty {
                        Text("· \(stream.gameName)")
                            .lineLimit(1)
                    }
                    Text("·")
                    HStack(spacing: 3) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(StreamFormatting.viewers(stream.viewerCount))
                            .contentTransition(.numericText())
                    }
                    .layoutPriority(1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live, \(stream.viewerCount) viewers")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Title only with the chrome up — the resting row stays one
                // line so chat keeps the room.
                if chromeVisible, !stream.title.isEmpty {
                    Text(stream.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// 16:9 video (or poster), full-width, with the tap-revealed overlay.
    private func playerSurface(_ stream: TwitchStream) -> some View {
        ZStack {
            poster(stream)

            playerEngine(audioOnly: false)

            if chromeVisible {
                playerOverlay(stream)
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
        .clipped()
        // Black status-bar strip, so the video reads as starting at the
        // top of the screen (like Twitch) instead of under a grey band.
        .background { Color.black.ignoresSafeArea(edges: .top) }
    }

    /// Where the shared player's video shows — only on the active page,
    /// and only while it's this channel that's playing.
    @ViewBuilder
    private func playerEngine(audioOnly: Bool) -> some View {
        #if os(iOS)
        // Not while the landscape stage shows it — the stage's host owns
        // the (same, re-parented) engine view then.
        if isActive, !landscapeStage.isActive, let playback, playback.isPlaying(channel.channelId) {
            PlayerHost(center: playback)
        }
        #endif
    }

    // MARK: - Audio-only bar

    /// Listen-only mode: the video is gone and chat gets the whole screen;
    /// a slim glass bar keeps the stream identity, play/pause and a way
    /// back to video. The player stays mounted but invisible (the native
    /// engine switches to Twitch's audio-only rendition to save data).
    private func audioBar(_ stream: TwitchStream) -> some View {
        HStack(spacing: 10) {
            avatar(ring: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.channelDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "headphones")
                    Text("Audio only")
                    Text("·")
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(StreamFormatting.viewers(stream.viewerCount))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            #if os(iOS)
            barButton(player.isPaused ? "play.fill" : "pause.fill",
                      label: player.isPaused ? "Play" : "Pause") {
                player.togglePlay()
            }
            #endif
            barButton("video.fill", label: "Show video") {
                withAnimation(.snappy(duration: 0.25)) { audioOnly = false }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .background(alignment: .topLeading) {
            playerEngine(audioOnly: true)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Picture-in-picture bar

    /// The stream is in the system PiP window, so the inline video area
    /// would only show a "playing in picture in picture" placeholder. Give
    /// that space to chat: a slim bar with the stream identity and a way to
    /// bring the video back here.
    private func pictureInPictureBar(_ stream: TwitchStream) -> some View {
        HStack(spacing: 10) {
            avatar(ring: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.channelDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "pip")
                    Text("Picture in picture")
                    Text("·")
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(StreamFormatting.viewers(stream.viewerCount))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            #if os(iOS)
            barButton("pip.exit", label: "Show video here") {
                player.togglePictureInPicture()
            }
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 4)
        // The engine stays mounted (PiP is driven from its layer / video
        // element), just out of sight.
        .background(alignment: .topLeading) {
            playerEngine(audioOnly: false)
                .frame(width: 2, height: 2)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// This page's stream is the one in the PiP window.
    private var isPictureInPictureActive: Bool {
        #if os(iOS)
        player.isPictureInPictureActive && (playback?.isPlaying(channel.channelId) ?? false)
        #else
        false
        #endif
    }

    private func barButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }

    /// Stream thumbnail: what neighbouring pages show, and what sits under
    /// the player until it paints its first frame.
    private func poster(_ stream: TwitchStream) -> some View {
        LazyImage(url: StreamFormatting.thumbnailURL(stream.thumbnailUrl, width: 640, height: 360)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(iOS)
            toggleChrome()
            #else
            if let channelURL { openURL(channelURL) }
            #endif
        }
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 50 { setExpanded(false) }
            }
        )
        .accessibilityLabel("\(channel.channelDisplayName) stream")
    }

    private func playerOverlay(_ stream: TwitchStream) -> some View {
        ZStack {
            // Scrims keep the white glyphs legible on bright frames. Not
            // hit-testable: taps fall through to the video, which toggles
            // the chrome back off.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: .clear, location: 0.6),
                    .init(color: .black.opacity(0.6), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    glyphButton("chevron.left", label: "Back") { dismiss() }
                    Spacer()
                    pageIndicator
                    #if os(iOS)
                    glyphButton("headphones", label: "Audio only") {
                        chromeVisible = false
                        withAnimation(.snappy(duration: 0.25)) { audioOnly = true }
                    }
                    #endif
                    if let channelURL {
                        ShareLink(item: channelURL) { glyph("square.and.arrow.up") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Share channel")
                    }
                    #if os(iOS)
                    if isNativeEngine {
                        Menu {
                            Picker("Quality", selection: $maxQuality) {
                                ForEach(PlayerQuality.allCases) { quality in
                                    Text(quality.label).tag(quality)
                                }
                            }
                        } label: {
                            glyph("gearshape.fill")
                        }
                        .accessibilityLabel("Video quality")
                    }
                    #endif
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    overlayChip {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(stream.startedAt, style: .timer)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live for \(StreamFormatting.uptime(since: stream.startedAt))")
                    Button {
                        onShowViewers()
                    } label: {
                        overlayChip {
                            Image(systemName: "person.fill")
                            Text(StreamFormatting.viewers(stream.viewerCount))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(stream.viewerCount) viewers")
                    .accessibilityHint("Shows who's in chat")
                    Spacer(minLength: 0)
                    #if os(iOS)
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
                    #endif
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            #if os(iOS)
            if isActive {
                Button {
                    player.togglePlay()
                    touchChrome()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            }
            #endif
        }
    }

    /// Bare white glyph with a soft shadow (no circle) — legible on any
    /// frame thanks to the scrims.
    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 3)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    /// Compact Subscribe beside the stream info; the chevron menu holds
    /// Gift a Sub. Both hand off to Twitch (subs are bought there).
    private var subscribeButton: some View {
        Menu {
            Button {
                openSubs()
            } label: {
                Label("Gift a Sub", systemImage: "gift")
            }
        } label: {
            HStack(spacing: 4) {
                Text("Subscribe")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255), in: Capsule())
        } primaryAction: {
            openSubs()
        }
        .accessibilityLabel("Subscribe")
        .accessibilityHint("Opens Twitch. Hold for Gift a Sub.")
    }

    private var subsURL: URL? {
        URL(string: "https://www.twitch.tv/subs/\(channel.channelLoginName)")
    }

    private func openSubs() {
        touchChrome()
        if let subsURL { openURL(subsURL) }
    }

    private func glyphButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(systemImage) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }

    private func overlayChip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4, content: content)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// "1 / 3" — stands in for the nav pill's page dots while the bar is
    /// hidden, and is itself the quick switcher: tap → menu of open chats.
    /// Only with two or more open chats.
    @ViewBuilder
    private var pageIndicator: some View {
        if let chatTabs, chatTabs.tabs.count > 1,
           let index = chatTabs.tabs.firstIndex(where: { $0.channels.first?.channelId == channel.channelId }) {
            Menu {
                ForEach(chatTabs.tabs) { tab in
                    Button {
                        chatTabs.activeTabId = tab.id
                    } label: {
                        if tab.channels.first?.channelId == channel.channelId {
                            Label(tab.displayName, systemImage: "checkmark")
                        } else {
                            Text(tab.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(index + 1) / \(chatTabs.tabs.count)")
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .accessibilityLabel("Chat \(index + 1) of \(chatTabs.tabs.count). Switch chat")
        }
    }

    // MARK: - Compact card

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if stream != nil {
                    setExpanded(true)
                } else {
                    withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
                }
            } label: {
                compactRow
            }
            .buttonStyle(.plain)
            .accessibilityHint(compactHint)

            // Offline (or still-loading) channels: the expanded card is just
            // tags + actions — there's no stream to play.
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if !tags.isEmpty { tagRow }
                    ChannelActionRow(channel: channel, isFollowing: isFollowing)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 4)
        // Pull down on the card to bring the video back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 40, stream != nil { setExpanded(true) }
            }
        )
    }

    private var compactHint: String {
        if stream != nil { return "Plays the stream" }
        return isExpanded ? "Collapses stream info" : "Expands stream info"
    }

    private var compactRow: some View {
        HStack(alignment: .center, spacing: 10) {
            avatar(ring: stream != nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(isExpanded ? 2 : 1)
                metaLine
            }
            Spacer(minLength: 4)
            Image(systemName: stream != nil ? "play.rectangle" : "chevron.down")
                .font(stream != nil ? .body : .caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(stream == nil && isExpanded ? 180 : 0))
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Shared pieces

    private var isFollowing: Bool {
        followsStore?.channels.contains { $0.broadcasterId == channel.channelId } ?? false
    }

    private var tagRow: some View {
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

    private func avatar(ring: Bool) -> some View {
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
            if ring {
                Circle().strokeBorder(.red, lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Hides the chat pager's navigation bar while the visible chat is playing
/// its stream — the header's video overlay carries ‹ back and ⌄ instead,
/// and the edge swipe still goes back (`SwipeBackEnabler`).
///
/// A zero-size view of its own so the live-status reads it needs invalidate
/// only this, never the pager body. Same derivation as `StreamHeaderView`'s
/// watching layout: expanded preference + visible channel is live.
struct ChatNavBarAutoHider: View {
    let chatTabs: ChatTabsModel

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    private var hidesBar: Bool {
        guard isExpanded, !audioOnly,
              let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id,
              let channelId = chatTabs.tabs.first(where: { $0.id == visibleId })?.channels.first?.channelId
        else { return false }
        #if os(iOS)
        // In PiP the header is a slim bar, not a video — keep the nav bar.
        if playback?.controller.isPictureInPictureActive == true,
           playback?.isPlaying(channelId) == true {
            return false
        }
        #endif
        return ChannelStatusStore.liveStream(for: channelId, status: channelStatus, follows: followsStore) != nil
    }

    var body: some View {
        #if os(iOS)
        SwipeBackEnabler()
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .toolbar(hidesBar ? .hidden : .automatic, for: .navigationBar)
            .animation(.snappy(duration: 0.25), value: hidesBar)
        #else
        Color.clear.frame(width: 0, height: 0)
        #endif
    }
}
