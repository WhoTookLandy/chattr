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
/// **Watching** (expanded + live) — the stream plays in-app, flush under the
/// status bar (the pager hides the nav bar; see `ChatNavBarAutoHider`):
///
///   ┌────────── video ──────────┐   tap → controls, ‹ back, ⌄ hide video,
///   └───────────────────────────┘          tags + action row (auto-hide 4s)
///   [avatar] Title, max two lines…
///            Just Chatting · ● 44K · 4:17:41
///
/// **Compact** (collapsed, or offline) — the one-row glass card:
///
///   [avatar] Stream title text…                       ⌄
///            Just Chatting · ● 41 · 2:50:19
///
/// Offline channels expand to tags + actions only (nothing to play).
///
/// Reads `FollowsStore` + `ChannelStatusStore` itself (not via ChatScreen)
/// so status refreshes re-render only this header, never the chat screen.
/// Refresh polling lives in `HomeScreen`, batched across open tabs.
struct StreamHeaderView: View {
    let channel: ChannelDescriptor
    /// Only the page centered in the pager mounts the player — neighbours
    /// stay as posters so swiping never plays two streams at once.
    let isActive: Bool

    /// Shared across every chat page — "I like watching while I chat" is a
    /// user preference, not a per-channel one.
    static let expandedKey = "chattr.chat.streamHeaderExpanded"

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @AppStorage(Self.expandedKey) private var isExpanded = false

    /// Player overlay + tags + action row. Hidden by default so chat keeps
    /// the room; any tap on the video or info row toggles it.
    @State private var chromeVisible = false
    /// Bumped on every interaction so the auto-hide timer restarts.
    @State private var chromeInteraction = 0

    #if os(iOS)
    @State private var player = StreamPlayerController()
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

    var body: some View {
        Group {
            if isExpanded, let stream {
                watchingLayout(stream)
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
    }

    private var isPlayerPaused: Bool {
        #if os(iOS)
        player.isPaused
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

            Button(action: toggleChrome) {
                HStack(alignment: .top, spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 3) {
                        Text(titleText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        metaLine
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, chromeVisible ? 8 : 10)
            .accessibilityHint(chromeVisible ? "Hides stream controls" : "Shows stream controls")

            if chromeVisible {
                VStack(alignment: .leading, spacing: 10) {
                    if !tags.isEmpty { tagRow }
                    ChannelActionRow(channel: channel, isFollowing: isFollowing)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .simultaneousGesture(TapGesture().onEnded { touchChrome() })
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
        }
        .background(Color.chatSurface)
        .clipped()
    }

    /// 16:9 video (or poster), full-width, with the tap-revealed overlay.
    private func playerSurface(_ stream: TwitchStream) -> some View {
        ZStack {
            poster(stream)

            #if os(iOS)
            if isActive {
                StreamPlayerView(channelLogin: channel.channelLoginName, controller: player)
                    .onAppear { player.onTap = { toggleChrome() } }
            }
            #endif

            if chromeVisible {
                playerOverlay(stream)
                    .transition(.opacity)
            } else {
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.red, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
        .clipped()
    }

    /// Stream thumbnail: what neighbouring pages show, and what sits under
    /// the player until the page paints its first frame.
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
            if let url = URL(string: "https://www.twitch.tv/\(channel.channelLoginName)") { openURL(url) }
            #endif
        }
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
                    .init(color: .black.opacity(0.65), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack {
                HStack(spacing: 8) {
                    overlayButton("chevron.left", label: "Back") { dismiss() }
                    overlayButton("chevron.down", label: "Hide video") { setExpanded(false) }
                    Spacer()
                    pageIndicator
                }
                Spacer()
                HStack(spacing: 8) {
                    LiveBadge(viewerCount: stream.viewerCount, style: .overlay)
                    #if os(iOS)
                    overlayButton(player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                  label: player.isMuted ? "Unmute" : "Mute") {
                        player.toggleMute()
                        touchChrome()
                    }
                    #endif
                    Spacer()
                    #if os(iOS)
                    if player.canPictureInPicture {
                        overlayButton("pip.enter", label: "Picture in Picture") {
                            player.togglePictureInPicture()
                            touchChrome()
                        }
                    }
                    overlayButton("arrow.up.left.and.arrow.down.right", label: "Full screen") {
                        player.enterFullscreen()
                        touchChrome()
                    }
                    #endif
                }
            }
            .padding(10)

            #if os(iOS)
            if isActive {
                Button {
                    player.togglePlay()
                    touchChrome()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.45), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPaused ? "Play" : "Pause")
            }
            #endif
        }
    }

    private func overlayButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// "1 / 3" — stands in for the nav pill's page dots while the bar is
    /// hidden. Only with two or more open chats.
    @ViewBuilder
    private var pageIndicator: some View {
        if let chatTabs, chatTabs.tabs.count > 1,
           let index = chatTabs.tabs.firstIndex(where: { $0.channels.first?.channelId == channel.channelId }) {
            Text("\(index + 1) / \(chatTabs.tabs.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .accessibilityLabel("Chat \(index + 1) of \(chatTabs.tabs.count)")
        }
    }

    // MARK: - Compact card

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() }
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
    }

    private var compactHint: String {
        if stream != nil { return "Plays the stream" }
        return isExpanded ? "Collapses stream info" : "Expands stream info"
    }

    private var compactRow: some View {
        HStack(alignment: .center, spacing: 10) {
            avatar
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

    private var hidesBar: Bool {
        guard isExpanded,
              let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id,
              let channelId = chatTabs.tabs.first(where: { $0.id == visibleId })?.channels.first?.channelId
        else { return false }
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
