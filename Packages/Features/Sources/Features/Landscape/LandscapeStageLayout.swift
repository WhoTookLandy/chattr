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

    /// Wider than tall. Tracked as a Bool so keyboard / safe-area height
    /// changes don't re-run this body unless the orientation flips.
    @State private var isLandscape = false
    /// The page's width — only changes on rotation / window resize.
    @State private var containerWidth: CGFloat = 0

    /// The stage shows when the header would otherwise be playing video:
    /// "show video" on, the channel live, and not listening audio-only.
    private var stageActive: Bool {
        guard isLandscape, isExpanded, !isAudioOnlyActive else { return false }
        return ChannelStatusStore.liveStream(
            for: channel.channelId,
            status: channelStatus,
            follows: followsStore
        ) != nil
    }

    /// Mirrors `StreamHeaderView.isAudioOnlyActive`: audio-only needs the
    /// native engine; if it failed, the video layout comes back.
    private var isAudioOnlyActive: Bool {
        #if os(iOS)
        audioOnly && !(playback?.controller.nativeFailed ?? false)
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
                    layoutMode: mode
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
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width > proxy.size.height
        } action: { landscape in
            isLandscape = landscape
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width.rounded()
        } action: { width in
            containerWidth = width
        }
    }

    /// Written once per drag, on release — the only point where the chat
    /// column (and so the transcript) re-lays out.
    private func commitChatWidth(_ width: CGFloat) {
        let rounded = Double(width.rounded())
        guard rounded != storedChatWidth else { return }
        storedChatWidth = rounded
    }
}
