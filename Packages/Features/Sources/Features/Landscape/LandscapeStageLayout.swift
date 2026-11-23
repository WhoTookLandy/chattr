import SwiftUI
import Core
import TwitchKit

extension View {
    /// Lays a chat page out for landscape watching: when the screen is
    /// wider than tall and the channel's stream is showing, the video moves
    /// to a stage beside (or under) the chat column. See
    /// `LandscapeStageLayout`.
    func landscapeStageLayout(channel: ChannelDescriptor, tabId: UUID?) -> some View {
        modifier(LandscapeStageLayout(channel: channel, tabId: tabId))
    }
}

/// Landscape layout for one chat page.
///
/// ```
///  Chat beside video (chat on the right)     Chat over video
///  ┌───────────────────────┬┬──────────┐     ┌─────────────────┬──────────┐
///  │                       ││ chat     │     │                 │░chat░░░░░│
///  │        video          ││          │     │      video      │░░░░░░░░░░│
///  │                       ││ compose  │     │                 │░compose░░│
///  └───────────────────────┴┴──────────┘     └─────────────────┴──────────┘
///                    divider ┘
/// ```
///
/// ## Identity — why rotating remounts nothing
///
/// `content` (the whole `ChatScreen` chain: transcript, compose bar, sheets,
/// session tasks) sits at the SAME structural position in portrait and
/// landscape; only its frame width and an environment value change. The
/// stage and the divider are optional siblings around it, so adding or
/// removing them never changes the transcript's identity: the
/// `UICollectionView` and the chat model survive rotation untouched.
///
/// The video itself is owned by `PlaybackCenter` (`StreamEngine.view` holds
/// the `AVPlayerLayer` / `WKWebView`). Rotating moves that one engine view
/// from the stream header's `PlayerHost` to the stage's — the player is
/// re-parented, never rebuilt, so playback doesn't restart or rebuffer.
///
/// ## Invalidation
///
/// As a `ViewModifier`, this body re-runs without re-running `ChatScreen`'s
/// body (`content` is a placeholder). The live-status reads that decide
/// whether the stage shows are skipped entirely in portrait (`isLandscape`
/// short-circuits first), so portrait pages register no extra dependencies.
/// Dragging the divider re-renders only `LandscapeDividerHandle`; the chat
/// width is committed once, on release.
struct LandscapeStageLayout: ViewModifier {
    let channel: ChannelDescriptor
    let tabId: UUID?

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false
    @AppStorage(LandscapeSettings.chatSideKey) private var chatSide: LandscapeChatSide = .right
    @AppStorage(LandscapeSettings.layoutKey) private var layoutMode: LandscapeLayoutMode = .beside
    @AppStorage(LandscapeSettings.chatWidthKey) private var storedChatWidth = LandscapeSettings.defaultChatWidth
    @AppStorage(LandscapeSettings.overlayOpacityKey) private var overlayOpacity = LandscapeSettings.defaultOverlayOpacity

    /// The page's size class for this layout, measured BEFORE keyboard
    /// avoidance (see `body`) so a tall keyboard in portrait can't make
    /// the page look "wider than tall". One Equatable value, written only
    /// when it actually changes — rotation or a window resize, never a
    /// keyboard, safe-area or per-frame layout pass.
    @State private var geometry = LandscapePageGeometry.zero

    private var isLandscape: Bool { geometry.isLandscape }
    private var containerWidth: CGFloat { geometry.width }

    /// The stage shows when the header would otherwise be playing video:
    /// "show video" on, the channel live, not listening audio-only, and
    /// not in picture in picture.
    private var stageActive: Bool {
        guard isLandscape, isExpanded, !isAudioOnlyActive, !isPictureInPictureActive else { return false }
        let live = ChannelStatusStore.liveStream(
            for: channel.channelId,
            status: channelStatus,
            follows: followsStore
        )
        #if os(iOS)
        // Same stream the header shows, including one playing on through
        // a single offline reading (`PlaybackCenter.stream(for:live:)`).
        if let playback { return playback.stream(for: channel.channelId, live: live) != nil }
        #endif
        return live != nil
    }

    /// Mirrors `StreamHeaderView.isAudioOnlyActive`: audio-only needs the
    /// native engine; if it failed or is switched off, the video layout
    /// comes back.
    private var isAudioOnlyActive: Bool {
        #if os(iOS)
        StreamPlaybackPolicy.audioOnlyInEffect(
            audioOnly: audioOnly,
            nativePlaybackEnabled: PlayerSettings.isNativePlaybackEnabled,
            nativeFailed: playback?.controller.nativeFailed ?? false
        )
        #else
        false
        #endif
    }

    /// This channel's stream is in the system PiP window. The stage would
    /// only show a placeholder, so it gives way: chat goes full width and
    /// the header shows #40's compact PiP bar, which keeps the engine in
    /// its hidden host. Read only in landscape (`stageActive` checks
    /// `isLandscape` first), so portrait pages don't observe PiP state here.
    /// Per-channel flag, not the global `controller.isPictureInPictureActive`:
    /// a PiP transition re-evaluates only the page whose stream it is, never
    /// the pre-mounted neighbours.
    private var isPictureInPictureActive: Bool {
        #if os(iOS)
        guard let playback else { return false }
        return playback.pictureInPictureFlag(for: channel.channelId).isActive
        #else
        false
        #endif
    }

    private var chatWidth: CGFloat {
        LandscapeSettings.clampedChatWidth(CGFloat(storedChatWidth), containerWidth: containerWidth)
    }

    func body(content: Content) -> some View {
        let stage = stageActive
        let width = chatWidth
        let side = chatSide
        let mode = layoutMode
        ZStack(alignment: side.alignment) {
            if stage {
                LandscapeStreamStage(
                    channel: channel,
                    tabId: tabId,
                    chatSide: side,
                    layoutMode: mode,
                    chatWidth: width
                )
                // Beside: the stage stops at the chat column. Over: it
                // runs full width under the translucent chat.
                .padding(side.edge, mode == .beside ? width : 0)
                // The keyboard rises over the video instead of squeezing
                // it; the chat column (and its compose bar) still moves up.
                .ignoresSafeArea(.keyboard)
            }

            content
                // Same structural slot in every orientation (see type doc):
                // only the width proposal changes. `nil` = unconstrained.
                .frame(width: stage ? width : nil)
                .environment(
                    \.landscapeStage,
                    stage
                        ? LandscapeStageContext(
                            isActive: true,
                            surfaceOpacity: mode == .overlay ? overlayOpacity : 1
                        )
                        : .inactive
                )

            if stage {
                LandscapeDividerHandle(
                    side: side,
                    committedWidth: width,
                    containerWidth: containerWidth,
                    onCommit: commitChatWidth
                )
                // Centered on the chat column's inner edge.
                .padding(side.edge, width - LandscapeDividerHandle.hitWidth / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Measured on a backdrop that ignores the keyboard safe area, so
        // the size is the page's full, pre-avoidance size: the keyboard
        // shrinks the page's height, and in portrait a tall one (or an
        // emoji keyboard plus the compose bar) could otherwise flip the
        // page into "landscape". `onGeometryChange` only calls `action`
        // when the Equatable value changes.
        .background {
            Color.clear
                .onGeometryChange(for: LandscapePageGeometry.self) { proxy in
                    LandscapePageGeometry(size: proxy.size)
                } action: { newValue in
                    geometry = newValue
                }
                .ignoresSafeArea(.keyboard)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #if os(iOS)
        .retainsPictureInPictureFlag(for: channel.channelId, in: playback)
        #endif
    }

    /// Written once per drag, on release — the only point where the chat
    /// column (and so the transcript) re-lays out.
    private func commitChatWidth(_ width: CGFloat) {
        let rounded = Double(width.rounded())
        guard rounded != storedChatWidth else { return }
        storedChatWidth = rounded
    }
}

/// What `LandscapeStageLayout` needs from the page's size: orientation and
/// (rounded) width. Equatable so geometry callbacks fire only on a real
/// change.
struct LandscapePageGeometry: Equatable {
    var isLandscape: Bool
    var width: CGFloat

    static let zero = LandscapePageGeometry(isLandscape: false, width: 0)

    init(isLandscape: Bool, width: CGFloat) {
        self.isLandscape = isLandscape
        self.width = width
    }

    init(size: CGSize) {
        self.init(isLandscape: size.width > size.height, width: size.width.rounded())
    }
}
