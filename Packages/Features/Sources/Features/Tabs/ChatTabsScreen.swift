import SwiftUI
import Accounts
import DesignSystem
import NukeUI
import Core

/// Root content of the Chats tab.
///
/// Structured like Messages: the tab's root is a *list* of open chats;
/// tapping one pushes the transcript full-screen with the tab bar hidden
/// (`.toolbar(.hidden, for: .tabBar)` on the pushed destination). A chat
/// transcript is an immersive surface — compose bar at the bottom, every
/// point of height mattering — so app-level chrome gets out of the way
/// and the system back button is the exit. The tab bar reappears at the
/// list root.
///
/// Layout:
///   1. A single `NavigationStack`. Root: open-chats list (reorder /
///      swipe-to-close) or the empty state. Pushed: the chat pager.
///   2. The pushed pager is a horizontally-paged `ScrollView` of
///      `ChatScreen` pages — one page per open tab. Swipe left/right to
///      switch chats without popping back.
///   3. The toolbar header of the pushed pager is the floating channel
///      pill (name + page dots) → opens the switcher sheet.
///
/// Push state is *derived from* `ChatTabsModel.activeTabId` (non-nil =
/// a chat is open) rather than a separate Bool — opening a channel from
/// Home/Search sets `activeTabId`, which both selects the page and
/// presents the push; popping back clears it. One source of truth, no
/// sync bugs between "which chat" and "is a chat showing."
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
/// `LazyHStack` lazily mounts ChatScreens — only the visible page (plus
/// a small adjacent buffer) actually exists in the view tree. When the user
/// swipes far away, off-screen ChatScreens unmount and their ChatTranscriptModels
/// release their subscriptions.
///
/// **The underlying `ChannelSession` stays alive in the registry, though.**
/// It keeps receiving events, keeps appending to its ring buffer. When the
/// user swipes back and the ChatScreen remounts, `ChatTranscriptModel.attach`
/// primes from the ring's current snapshot — so the user sees every message
/// that arrived while the page was off-screen.
public struct ChatTabsScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Injected by AppShell: switches the app to the Home tab. Used by the
    /// empty state's CTA — with no chats open, the useful next step is the
    /// Home surface (live follows), not a modal.
    private let goHome: (() -> Void)?

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

    @Environment(\.chatTabs) private var chatTabs

    /// Read for `edgeToEdge`: when the user runs chat full-bleed, the
    /// navigation bar's own background is hidden so the avatar / channel
    /// pill / heart become free-standing glass over the transcript
    /// (Reddit-style) instead of sitting on a bar.
    @Environment(\.chatAppearance) private var appearance

    /// Scene-scoped restoration of the active tab id. `@SceneStorage` only
    /// supports primitive types, so we round-trip through UUID's
    /// `uuidString` representation. Persisted per-scene (each window has
    /// its own active tab — relevant for iPad multi-window where the user
    /// might want one window focused on chat A, another on chat B).
    ///
    /// Lifecycle:
    ///   - On VStack appear, if a saved id matches an existing tab, write
    ///     it back to `chatTabs.activeTabId`. The header title updates; the
    ///     ScrollView snaps.
    ///   - On every `activeTabId` change (swipe a page, activate via switcher),
    ///     mirror the new value back to `@SceneStorage`. The latest selection
    ///     is always durable.
    ///
    /// Tab list itself lives in SwiftData (account-scoped, see
    /// `PersistedChatTab`) — this storage is purely "which one was active
    /// in this scene."
    @SceneStorage("chattr.chat.activeTabId") private var persistedActiveTabId: String?

    /// You → App → Resume Last Chat. When off, the Chats tab always
    /// starts at the list; the saved active-tab id is still recorded so
    /// turning the toggle back on resumes again.
    @AppStorage("chattr.resumeLastChatOnLaunch") private var resumeLastChatOnLaunch = true

    public init(
        account: Account,
        accountStore: AccountStore,
        goHome: (() -> Void)? = nil
    ) {
        self.account = account
        self.accountStore = accountStore
        self.goHome = goHome
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let chatTabs, !chatTabs.tabs.isEmpty {
                    openChatsList(chatTabs: chatTabs)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Chats")
            .toolbarTitleDisplayMode(.inlineLarge)
            .onAppear {
                // Scene restoration: resume the chat that was open when
                // the scene was last torn down (user-controllable via
                // You → App → Resume Last Chat). Setting `activeTabId`
                // both selects the page and (via the derived binding
                // below) presents the push.
                if resumeLastChatOnLaunch,
                   chatTabs?.activeTabId == nil,
                   let savedId = persistedActiveTabId,
                   let uuid = UUID(uuidString: savedId),
                   chatTabs?.tabs.contains(where: { $0.id == uuid }) == true {
                    chatTabs?.activeTabId = uuid
                }
            }
            .onChange(of: chatTabs?.activeTabId) { _, newValue in
                persistedActiveTabId = newValue?.uuidString
            }
            .navigationDestination(isPresented: chatIsPresented) {
                chatDetail
            }
        }
        // Open-chats switcher.
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
        // Follows browse — kept as a sheet for the switcher's "Browse
        // Follows" shortcut. The primary Follows surface is the Home tab.
        .sheet(isPresented: $showFollows) {
            NavigationStack {
                ChannelListScreen(account: account, accountStore: accountStore)
            }
        }
    }

    /// Push state, derived from the model: a chat is presented exactly
    /// when a tab is active. Popping (interactive swipe-back included)
    /// writes `false`, which clears the selection — the list root never
    /// shows with a stale "active" chat.
    private var chatIsPresented: Binding<Bool> {
        Binding(
            get: {
                guard let chatTabs else { return false }
                return chatTabs.activeTabId != nil && !chatTabs.tabs.isEmpty
            },
            set: { presented in
                if !presented {
                    chatTabs?.activeTabId = nil
                }
            }
        )
    }

    /// The pushed, full-screen chat surface: the paged transcript with the
    /// channel pill header and — the point of the push — no tab bar.
    @ViewBuilder
    private var chatDetail: some View {
        Group {
            if let chatTabs {
                pagedChatContent(chatTabs: chatTabs)
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
        #endif
    }

    /// Root list of open chats — Messages-style rows: avatar, channel
    /// name, login. Swipe to close (releases the session via the model's
    /// `onClose`), drag to reorder (defines the pager's swipe order).
    @ViewBuilder
    private func openChatsList(chatTabs: ChatTabsModel) -> some View {
        List {
            ForEach(chatTabs.tabs) { tab in
                Button {
                    chatTabs.activeTabId = tab.id
                } label: {
                    HStack(spacing: 12) {
                        tabAvatar(tab)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.displayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if let login = tab.channels.first?.channelLoginName {
                                Text("#\(login)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onMove { source, destination in
                chatTabs.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                let ids = offsets.map { chatTabs.tabs[$0].id }
                for id in ids {
                    chatTabs.close(tabId: id)
                }
            }
        }
        .listStyle(.plain)
    }

    /// Circle avatar for a list row (40pt) or quick-switcher row (28pt).
    /// Placeholder symbol while the image loads or when the descriptor has
    /// no profile URL.
    private func tabAvatar(_ tab: ChatTab, size: CGFloat = 40) -> some View {
        LazyImage(url: tab.profileImageURL) { state in
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
            // pill, not this `ChatTabsScreen` body — which also builds the
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
            LazyHStack(spacing: 0) {
                ForEach(chatTabs.tabs) { tab in
                    chatPage(for: tab, isActive: tab.id == chatTabs.activeTabId)
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
    private func chatPage(for tab: ChatTab, isActive: Bool) -> some View {
        if let primaryChannel = tab.channels.first {
            ChatScreen(
                account: account,
                accountStore: accountStore,
                channel: primaryChannel,
                isActiveTab: isActive
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

    /// Shown when no channel tabs are open. Points at the Home tab (live
    /// follows) — falls back to the Follows sheet when AppShell didn't
    /// inject `goHome` (previews, tests).
    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No chats open", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Pick a live channel from Home to start chatting.")
        } actions: {
            Button("See who's live") {
                if let goHome {
                    goHome()
                } else {
                    showFollows = true
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
    }
}

/// The channel-pill *label*: the visible tab's name, a chevron, an
/// unseen-mention dot, and (with 2+ tabs) miniature page dots.
///
/// Extracted from `ChatTabsScreen` into its own `View` purely for
/// invalidation isolation. The pill reads `chatTabs.mentionedTabIds`, which
/// changes whenever a ping lands in a *background* tab; left inline in
/// `ChatTabsScreen.body` that read made every mention re-evaluate the whole
/// screen body, including the paged `ScrollView` of `ChatScreen`s. As its own
/// view the mention dependency is scoped here, so a background ping redraws
/// the dot without touching the pager. (`ChatScreen` pages are protected by
/// their own identity regardless; this avoids the wasted container rebuild.)
private struct ChannelPillLabel: View {
    let chatTabs: ChatTabsModel?

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
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
