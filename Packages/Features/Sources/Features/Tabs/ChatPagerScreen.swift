import SwiftUI
import Accounts
import DesignSystem
import NukeUI
import Nuke
import Core

/// The full-screen chat surface pushed from Home → Chats.
///
/// Structured like Messages: the list of open chats lives in Home's Chats
/// section (`OpenChatsList`); tapping one pushes THIS screen with the tab bar
/// hidden (`.toolbar(.hidden, for: .tabBar)`). A chat transcript is an
/// immersive surface — compose bar at the bottom, every point of height
/// mattering — so app-level chrome gets out of the way and the system back
/// button is the exit.
///
/// Layout:
///   1. A horizontally-paged `ScrollView` of `ChatScreen` pages — one page
///      per open tab. Swipe left/right to switch chats without popping back.
///   2. The toolbar header is the floating channel pill (name, live dot,
///      page dots) → opens the quick-switcher popover.
///
/// Push state is *derived from* `ChatTabsModel.activeTabId` (non-nil = a
/// chat is open) by the presenting `HomeScreen` — opening a channel from
/// anywhere sets `activeTabId`, which both selects the page and presents the
/// push; popping back clears it.
///
/// ## How the paging works
///
/// `ScrollView(.horizontal) + LazyHStack` with three iOS 17+ modifiers does
/// the heavy lifting:
///
///   - `.scrollTargetLayout()` on the LazyHStack tells SwiftUI that each
///     child carries an `.id(...)` to use as a snap anchor.
///   - `.scrollTargetBehavior(.paging)` makes swipes snap one full page at
///     a time (vs free-scrolling).
///   - `.scrollPosition(id: $activeTabId)` two-way binds the currently-
///     visible page to `ChatTabsModel.activeTabId`. Tap the name → switcher
///     → activate → ScrollView animates to that page. Swipe → ScrollView
///     writes back to `activeTabId` → header title + page-dot update.
///
/// ## How sessions persist across swipes
///
/// The pager keeps a WINDOW of ChatScreens mounted — the settled page plus
/// one neighbour each side (`PagerWindow`) — so the page being swiped in is
/// already attached and laid out before the gesture starts. Pages outside
/// the window are bare placeholders; when the window moves past a page, its
/// ChatScreen unmounts and its ChatTranscriptModel releases its
/// subscriptions.
///
/// **The underlying `ChannelSession` stays alive in the registry, though.**
/// It keeps receiving events, keeps appending to its ring buffer. When the
/// user swipes back and the ChatScreen remounts, `ChatTranscriptModel.attach`
/// primes from the ring's current snapshot — so the user sees every message
/// that arrived while the page was off-screen.
struct ChatPagerScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    @State private var showSwitcher = false
    /// The compact anchored popover the channel pill opens — quick tab
    /// switching only; `showSwitcher` remains the full management sheet.
    /// `-uiPreviewQuickSwitcher` (DEBUG) opens it at launch so the design-
    /// review harness can screenshot it without driving the UI.
    @State private var showQuickSwitcher: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uiPreviewQuickSwitcher")
        #else
        false
        #endif
    }()
    @State private var showFollows = false

    /// Which pages are mounted (see `PagerWindow`). A reference held in
    /// `@State`: this body only passes it along and never reads its
    /// properties, so moving the window doesn't re-run the pager.
    @State private var window = PagerWindow()

    @Environment(\.chatTabs) private var chatTabs

    /// Read for `edgeToEdge`: when the user runs chat full-bleed, the
    /// navigation bar's own background is hidden so the channel pill becomes
    /// free-standing glass over the transcript instead of sitting on a bar.
    @Environment(\.chatAppearance) private var appearance

    init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    var body: some View {
        Group {
            if let chatTabs {
                pagedChatContent(chatTabs: chatTabs)
                    // Neighbouring chats peek in from the edges after each
                    // page change — the swipe affordance the bare pager lacked.
                    .overlay {
                        PagerEdgeHints(chatTabs: chatTabs)
                    }
                    // While the visible chat plays its stream, the bar hides
                    // and the video overlay carries back / hide-video.
                    .background {
                        ChatNavBarAutoHider(chatTabs: chatTabs)
                        PagerWindowTracker(chatTabs: chatTabs, window: window)
                    }
            }
        }
        // Same surface as the transcript itself (ChatScreen applies it
        // too) — without this, the page-gutters sit on pure system black
        // and read as dead bars around the chat.
        .background(Color.chatSurface.ignoresSafeArea())
        .toolbar { headerToolbar(chatTabs: chatTabs) }
        .toolbarTitleDisplayMode(.inline)
        // Edge-to-Edge Chat: no bar background at all — the toolbar items
        // float free-standing over the transcript, each carrying its own
        // glass. Default (.automatic) restores the system bar treatment
        // for the inset layout. Placement `.automatic` = the primary bar
        // (nav bar on iOS) and, unlike `.navigationBar`, also compiles
        // for the package's macOS target.
        .toolbarBackgroundVisibility(
            appearance.edgeToEdge ? .hidden : .automatic,
            for: .automatic
        )
        // The immersive part: chat owns the whole screen; the system
        // back chevron is the way out. (`.tabBar` visibility control is
        // iOS-only; macOS has no tab bar to hide.)
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        // Audio-only / PiP controls, opposite the back button. Always
        // present (the control renders nothing when there's no condensed
        // stream) so the bar never gains or loses an item — see
        // `headerToolbar`.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let chatTabs {
                    NowPlayingToolbarControl(chatTabs: chatTabs)
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        #endif
        // Open-chats management sheet (reorder, close, browse).
        .sheet(isPresented: $showSwitcher) {
            if let chatTabs {
                ChannelSwitcherView(
                    model: chatTabs,
                    onBrowseFollows: {
                        showSwitcher = false
                        showFollows = true
                    }
                )
            }
        }
        // Follows browse — the switcher's "Browse Follows" shortcut.
        .sheet(isPresented: $showFollows) {
            NavigationStack {
                ChannelListScreen(account: account, accountStore: accountStore)
            }
        }
    }

    /// Circle avatar for a list row (40pt) or quick-switcher row (28pt).
    /// Placeholder symbol while the image loads or when the descriptor has
    /// no profile URL.
    private func tabAvatar(_ tab: ChatTab, size: CGFloat = 40) -> some View {
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

    /// The toolbar header of the pushed pager: a floating glass pill with
    /// the channel name (and page dots, when several tabs are open) in the
    /// center. One STABLE item whose label reflects the active tab — never
    /// inserted/removed conditionally (that would rebuild the bar and
    /// flicker; see axiom toolbars guidance).
    @ToolbarContentBuilder
    private func headerToolbar(chatTabs: ChatTabsModel?) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // The label is its own `View` (`ChannelPillLabel`) so that
            // unseen-mention updates (`mentionedTabIds`) invalidate ONLY the
            // pill, not this `ChatPagerScreen` body — which also builds the
            // paged transcript. A ping arriving in a background tab redraws
            // the dot without re-evaluating the pager. See `ChannelPillLabel`.
            Button { showQuickSwitcher = true } label: {
                ChannelPillLabel(chatTabs: chatTabs)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch channel")
            .disabled(chatTabs?.tabs.isEmpty ?? true)
            // Quick switcher: a compact anchored popover, not the
            // management sheet — switching chats is a two-tap flick, and
            // the popover keeps the transcript visible behind it. The
            // full sheet (reorder, close, browse) remains reachable via
            // the popover's footer.
            .popover(isPresented: $showQuickSwitcher, arrowEdge: .top) {
                if let chatTabs {
                    quickSwitcherContent(chatTabs: chatTabs)
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        // The pill carries its own glass above; hide the bar's shared
        // item background so the two don't stack into a double capsule.
        .sharedBackgroundVisibility(.hidden)
    }

    /// Body of the quick-switcher popover: one row per open chat — avatar,
    /// name, red mention dot, checkmark on the active row — plus an Edit
    /// footer that escalates to the full management sheet.
    private func quickSwitcherContent(chatTabs: ChatTabsModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(chatTabs.tabs) { tab in
                Button {
                    chatTabs.activeTabId = tab.id
                    showQuickSwitcher = false
                } label: {
                    HStack(spacing: 10) {
                        tabAvatar(tab, size: 28)
                        Text(tab.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        ChannelLiveDot(channelId: tab.channels.first?.channelId)
                        Spacer(minLength: 12)
                        if chatTabs.mentionedTabIds.contains(tab.id) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                                .accessibilityLabel("Mentioned you")
                        }
                        if tab.id == visibleTabId(chatTabs: chatTabs) {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
                .padding(.vertical, 4)
            Button {
                showQuickSwitcher = false
                showSwitcher = true
            } label: {
                Label("Edit chats", systemImage: "pencil")
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .frame(minWidth: 220, alignment: .leading)
    }

    /// The tab the pager is showing — `activeTabId`, falling back to the
    /// first tab pre-restoration (mirrors `activeTabTitle`'s resolution).
    private func visibleTabId(chatTabs: ChatTabsModel) -> UUID? {
        chatTabs.activeTabId ?? chatTabs.tabs.first?.id
    }



    /// Horizontally-paged ScrollView with one ChatScreen per open tab.
    /// Swipe left/right to switch tabs; tap a row in the switcher to jump.
    ///
    /// The `@Bindable` projection of `chatTabs` lets us pass `$bindable.activeTabId`
    /// as the `.scrollPosition` binding — that's the two-way connector between
    /// "what's on screen" and "which tab the model thinks is active." Without
    /// `@Bindable`, we'd have to hand-roll a `Binding(get:set:)` from the
    /// @Observable model, which works but is more verbose.
    @ViewBuilder
    private func pagedChatContent(chatTabs: ChatTabsModel) -> some View {
        @Bindable var bindable = chatTabs

        ScrollView(.horizontal) {
            // Eager `HStack`, not `LazyHStack`: mounting is decided by
            // `PagerWindow` (settled page ± 1), so neighbours are ready
            // BEFORE a swipe instead of mounting mid-gesture as they scroll
            // into view. Slots outside the window are a plain color.
            HStack(spacing: 0) {
                ForEach(chatTabs.tabs) { tab in
                    // No `activeTabId` read here: this body would then re-run
                    // on every page change and rebuild each mounted
                    // ChatScreen (fresh model + draft read in its init, then
                    // the transcript and the UIKit list update). Pages get
                    // their stable tab id; the few views that care whether
                    // they're the visible page (stream header, join greeting,
                    // list throttling) read `activeTabId` themselves.
                    ChatPagerPage(tabId: tab.id, chatTabs: chatTabs, window: window) {
                        chatPage(for: tab)
                    }
                    // `.containerRelativeFrame(.horizontal)` sizes each
                    // page to exactly the ScrollView's width — full-page
                    // panels instead of children at intrinsic width.
                    .containerRelativeFrame(.horizontal)
                    // `.id(tab.id)` is the snap anchor for
                    // `.scrollPosition(id:)`. SwiftUI uses tab.id (UUID)
                    // for view identity AND for the paged-position lookup
                    // — same value, both purposes.
                    .id(tab.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        // Two-way bind to activeTabId. Activating a tab via the switcher
        // writes activeTabId in ChatTabsModel → ScrollView animates to that
        // page. Swipe-to-page writes back here → header title + page-dot update.
        .scrollPosition(id: $bindable.activeTabId)
        // Freeze the mounted window while the user drags / the page snaps
        // (see `PagerWindow`). `.animating` (a quick-switcher jump) doesn't
        // count, so the destination mounts before the scroll lands. Writes
        // only — this body never reads the flag.
        .onScrollPhaseChange { _, phase in
            let scrolling = phase == .interacting || phase == .decelerating
            if window.isUserScrolling != scrolling {
                window.isUserScrolling = scrolling
            }
        }
        .scrollIndicators(.hidden)
        // Edge-to-Edge Chat: SwiftUI hangs the toolbar's scroll-edge
        // treatment off THIS pager ScrollView (the nearest scroll
        // container under the bar), not the UIKit list inside it. The
        // automatic style resolved to a heavy dark band over the whole
        // toolbar region; `.soft` is the progressive blur — content
        // gently blurs out as it nears the physical top, keeping the
        // free-standing pills legible without dimming the transcript.
        .scrollEdgeEffectStyle(appearance.edgeToEdge ? .soft : .automatic, for: .top)
    }

    /// One paged ChatScreen for a tab. MVP: renders the tab's first (and
    /// today, only) channel. When multi-channel-per-tab ships, ChatScreen
    /// will take the full ChatTab and ChatTranscriptModel will attach to ALL its
    /// channels in one go — the rest of this paged container won't change.
    @ViewBuilder
    private func chatPage(for tab: ChatTab) -> some View {
        if let primaryChannel = tab.channels.first {
            ChatScreen(
                account: account,
                accountStore: accountStore,
                channel: primaryChannel,
                tabId: tab.id
            )
        } else {
            // Defensive — ChatTab.init has a precondition against empty
            // channels, so this branch shouldn't reach in normal flow.
            // If a future code path ever does mutate channels to empty,
            // render a placeholder rather than a blank page.
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("This tab has no channels")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The channel-pill *label*: the visible tab's name, a chevron, an
/// unseen-mention dot, and (with 2+ tabs) miniature page dots.
///
/// Extracted from `ChatPagerScreen` into its own `View` purely for
/// invalidation isolation. The pill reads `chatTabs.mentionedTabIds`, which
/// changes whenever a ping lands in a *background* tab; left inline in
/// `ChatPagerScreen.body` that read made every mention re-evaluate the whole
/// screen body, including the paged `ScrollView` of `ChatScreen`s. As its own
/// view the mention dependency is scoped here, so a background ping redraws
/// the dot without touching the pager. (`ChatScreen` pages are protected by
/// their own identity regardless; this avoids the wasted container rebuild.)
private struct ChannelPillLabel: View {
    let chatTabs: ChatTabsModel?

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    #if os(iOS)
    @Environment(\.playback) private var playback
    @AppStorage(StreamHeaderView.expandedKey) private var isExpanded = false
    @AppStorage(PlayerSettings.audioOnlyKey) private var audioOnly = false
    #endif

    /// Viewer count when the visible channel is live; nil when offline or
    /// unknown. Read here (not in ChatPagerScreen) for the same isolation
    /// reason as the mention dot.
    private var liveViewers: Int? {
        guard let channelId = chatTabs?.visibleChannelId else { return nil }
        return ChannelStatusStore.liveStream(for: channelId, status: channelStatus, follows: followsStore)?.viewerCount
    }

    #if os(iOS)
    /// Audio-only / PiP: the header has collapsed, so the pill carries the
    /// mode as a glyph next to the viewer count.
    private var condensedMode: CondensedStreamMode? {
        CondensedStreamMode.resolve(
            channelId: chatTabs?.visibleChannelId,
            isLive: liveViewers != nil,
            isExpanded: isExpanded,
            audioOnly: audioOnly,
            playback: playback
        )
    }
    #endif

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                // "soochu ● 41" — live state at a glance, Twitch-style.
                if let liveViewers {
                    HStack(spacing: 3) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(StreamFormatting.viewers(liveViewers))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live, \(liveViewers) viewers")
                }
                #if os(iOS)
                if let condensedMode {
                    Image(systemName: condensedMode.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        .accessibilityLabel(condensedMode.accessibilityLabel)
                }
                #endif
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            // Unseen mention in a BACKGROUND tab: dot the pill so the ping is
            // visible from inside another chat.
            .overlay(alignment: .topTrailing) {
                if hasBackgroundMention {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .offset(x: 10, y: -3)
                        .accessibilityLabel("Unread mention in another chat")
                }
            }
            pageDots
        }
        #if os(iOS)
        .animation(.snappy(duration: 0.25), value: condensedMode)
        #endif
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // The pill's own glass — `.interactive()` so it responds to the
        // press like the standalone control it looks like.
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// Display name of the *visible* tab — `activeTabId`, falling back to
    /// `tabs.first` before scene restoration runs (matching the pager). "Chat"
    /// only when no tabs are open.
    private var title: String {
        guard let chatTabs,
              let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id,
              let tab = chatTabs.tabs.first(where: { $0.id == visibleId })
        else { return "Chat" }
        return tab.displayName
    }

    /// True when any non-active tab holds an unseen mention.
    private var hasBackgroundMention: Bool {
        guard let chatTabs else { return false }
        return !chatTabs.mentionedTabIds.subtracting([chatTabs.activeTabId].compactMap { $0 }).isEmpty
    }

    /// Miniature page dots — one per open tab, active highlighted, mention
    /// dots red. Rendered only with 2+ tabs; with a single tab the pill is
    /// just the name (nothing to switch between).
    @ViewBuilder
    private var pageDots: some View {
        if let chatTabs, chatTabs.tabs.count > 1 {
            HStack(spacing: 4) {
                // Resolve the same way the title does: the pager shows
                // `tabs.first` when `activeTabId` is still nil, so highlight
                // that dot rather than leaving all of them dim.
                let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id
                ForEach(chatTabs.tabs) { tab in
                    // Mention beats position: a red dot says "that page
                    // pinged you," which matters more than which page it is.
                    Circle()
                        .fill(chatTabs.mentionedTabIds.contains(tab.id)
                            ? AnyShapeStyle(.red)
                            : tab.id == visibleId
                                ? AnyShapeStyle(.tint)
                                : AnyShapeStyle(.secondary.opacity(0.35)))
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityHidden(true)
        }
    }
}
