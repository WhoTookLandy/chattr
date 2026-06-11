import SwiftUI
import Accounts
import DesignSystem
import NukeUI

/// Root content of the Chat surface — now also the app's home screen.
///
/// Layout:
///   1. A single `NavigationStack` with a toolbar header that reflects the
///      active tab (account avatar leading → Profile, floating channel-name
///      pill principal → switcher, heart trailing → Follows).
///   2. A horizontally-paged `ScrollView` of `ChatScreen` pages — one page
///      per open tab. Swipe left/right to switch tabs.
///   3. Page-dots live INSIDE the channel pill (hidden for a single tab) —
///      they used to occupy a dedicated strip below the transcript, which
///      read as a dead black bar between the chat surface and the home
///      indicator. Folding them into the pill returns that strip's height
///      to the transcript.
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
/// swipes far away, off-screen ChatScreens unmount and their TabChatModels
/// release their subscriptions.
///
/// **The underlying `ChannelSession` stays alive in the registry, though.**
/// It keeps receiving events, keeps appending to its ring buffer. When the
/// user swipes back and the ChatScreen remounts, `TabChatModel.attach`
/// primes from the ring's current snapshot — so the user sees every message
/// that arrived while the page was off-screen.
public struct ChatTabsScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Twitch client id, forwarded to the Profile sheet's account switcher.
    private let clientId: String

    @State private var showSwitcher = false
    @State private var showFollows = false
    @State private var showProfile = false

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

    public init(
        account: Account,
        accountStore: AccountStore,
        clientId: String
    ) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let chatTabs, !chatTabs.tabs.isEmpty {
                    pagedChatContent(chatTabs: chatTabs)
                    .onAppear {
                        if let savedId = persistedActiveTabId,
                           let uuid = UUID(uuidString: savedId),
                           chatTabs.tabs.contains(where: { $0.id == uuid }) {
                            chatTabs.activeTabId = uuid
                        }
                    }
                    .onChange(of: chatTabs.activeTabId) { _, newValue in
                        persistedActiveTabId = newValue?.uuidString
                    }
                } else {
                    emptyState
                }
            }
            // Same surface as the transcript itself (ChatScreen applies it
            // too) — without this, the page-gutters and empty state sit on
            // pure system black and read as dead bars around the chat.
            .background(Color.chatSurface.ignoresSafeArea())
            .toolbar { headerToolbar(chatTabs: chatTabs) }
            .toolbarTitleDisplayMode(.inline)
            // Edge-to-Edge Chat: no bar background at all — the three
            // toolbar items float free-standing over the transcript,
            // each carrying its own glass. Default (.automatic) restores
            // the system bar treatment for the inset layout. Placement
            // `.automatic` = the primary bar (nav bar on iOS) and, unlike
            // `.navigationBar`, also compiles for the package's macOS
            // target.
            .toolbarBackgroundVisibility(
                appearance.edgeToEdge ? .hidden : .automatic,
                for: .automatic
            )
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
        // Follows browse — its own NavigationStack inside the sheet.
        .sheet(isPresented: $showFollows) {
            NavigationStack {
                ChannelListScreen(account: account, accountStore: accountStore)
            }
        }
        // Profile / settings — its own NavigationStack inside the sheet.
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                ProfileScreen(account: account, accountStore: accountStore, clientId: clientId)
            }
        }
    }

    /// `.topBar*` placements are iOS-only; map to cross-platform equivalents
    /// on macOS so the Features package still compiles for its declared
    /// `.macOS` platform — matching the rest of the target's semantic-
    /// placement convention.
    private var leadingHeaderPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
    private var trailingHeaderPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    /// The toolbar header, Reddit-style: the account's actual avatar
    /// leading, a floating glass pill with the channel name (and page
    /// dots, when several tabs are open) in the center, follows trailing.
    /// Three STABLE items whose labels reflect the active tab — never
    /// inserted/removed conditionally (that would rebuild the bar and
    /// flicker; see axiom toolbars guidance).
    @ToolbarContentBuilder
    private func headerToolbar(chatTabs: ChatTabsModel?) -> some ToolbarContent {
        ToolbarItem(placement: leadingHeaderPlacement) {
            Button { showProfile = true } label: {
                avatarImage
            }
            .accessibilityLabel("Profile")
        }
        ToolbarItem(placement: .principal) {
            Button { showSwitcher = true } label: {
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Text(activeTabTitle(chatTabs: chatTabs))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    pillPageDots(chatTabs: chatTabs)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                // The pill's own glass — `.interactive()` so it responds
                // to the press like the standalone control it looks like.
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch channel")
            .disabled(chatTabs?.tabs.isEmpty ?? true)
        }
        // The pill carries its own glass above; hide the bar's shared
        // item background so the two don't stack into a double capsule.
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: trailingHeaderPlacement) {
            Button { showFollows = true } label: {
                Image(systemName: "heart")
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Follows")
        }
    }

    /// The signed-in account's avatar, circle-cropped to toolbar-icon
    /// size. Falls back to the old SF Symbol while loading or when the
    /// profile-image URL is missing (first sign-in before the /users
    /// probe completes).
    private var avatarImage: some View {
        LazyImage(url: URL(string: account.profileImageURL)) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }

    /// Miniature page dots inside the channel pill — one per open tab,
    /// active highlighted. Rendered only with 2+ tabs; with a single tab
    /// the pill is just the name (nothing to switch between). These
    /// replace the dedicated dots strip that used to sit below the
    /// transcript eating vertical space.
    @ViewBuilder
    private func pillPageDots(chatTabs: ChatTabsModel?) -> some View {
        if let chatTabs, chatTabs.tabs.count > 1 {
            HStack(spacing: 4) {
                // Resolve the same way the title does: the pager shows
                // `tabs.first` when `activeTabId` is still nil, so highlight
                // that dot rather than leaving all of them dim.
                let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id
                ForEach(chatTabs.tabs) { tab in
                    Circle()
                        .fill(tab.id == visibleId ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.35)))
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Title for the principal item — the display name of the *visible* tab.
    /// When `activeTabId` hasn't been set yet (e.g. cold launch before scene
    /// restoration runs), the pager shows `tabs.first`, so the title resolves
    /// to it too instead of a generic fallback. "Chat" shows only when no
    /// tabs are open.
    private func activeTabTitle(chatTabs: ChatTabsModel?) -> String {
        guard let chatTabs,
              let visibleId = chatTabs.activeTabId ?? chatTabs.tabs.first?.id,
              let tab = chatTabs.tabs.first(where: { $0.id == visibleId })
        else { return "Chat" }
        return tab.displayName
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
                    chatPage(for: tab)
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
    /// will take the full ChatTab and TabChatModel will attach to ALL its
    /// channels in one go — the rest of this paged container won't change.
    @ViewBuilder
    private func chatPage(for tab: ChatTab) -> some View {
        if let primaryChannel = tab.channels.first {
            ChatScreen(
                account: account,
                accountStore: accountStore,
                channelId: primaryChannel.channelId,
                channelLoginName: primaryChannel.channelLoginName,
                channelDisplayName: primaryChannel.channelDisplayName
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

    /// Shown when no channel tabs are open. Invites the user to browse Follows.
    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No channels open", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Browse your Follows to start watching a channel's chat.")
        } actions: {
            Button("Go to Follows") {
                showFollows = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
    }
}
