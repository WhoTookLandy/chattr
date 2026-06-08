import SwiftUI
import Accounts

/// Root content of the Chat surface — now also the app's home screen.
///
/// Layout:
///   1. A single `NavigationStack` with a toolbar header that reflects the
///      active tab (avatar leading → Profile, channel name principal →
///      switcher, grid trailing → Follows).
///   2. A horizontally-paged `ScrollView` of `ChatScreen` pages — one page
///      per open tab. Swipe left/right to switch tabs.
///   3. Page-dots below the transcript (hidden for a single tab).
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
                    VStack(spacing: 0) {
                        pagedChatContent(chatTabs: chatTabs)
                        pageDots(chatTabs: chatTabs)
                    }
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
            .toolbar { headerToolbar(chatTabs: chatTabs) }
            .toolbarTitleDisplayMode(.inline)
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

    /// The toolbar header. Three STABLE items whose labels reflect the
    /// active tab — never inserted/removed conditionally (that would rebuild
    /// the bar and flicker; see axiom toolbars guidance).
    @ToolbarContentBuilder
    private func headerToolbar(chatTabs: ChatTabsModel?) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showProfile = true } label: {
                Image(systemName: "person.crop.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Profile")
        }
        ToolbarItem(placement: .principal) {
            Button { showSwitcher = true } label: {
                HStack(spacing: 5) {
                    Text(activeTabTitle(chatTabs: chatTabs))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Switch channel")
            .disabled(chatTabs?.tabs.isEmpty ?? true)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFollows = true } label: {
                Image(systemName: "square.grid.2x2")
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Follows")
        }
    }

    /// Title for the principal item — the active tab's display name, or a
    /// neutral fallback when nothing is open.
    private func activeTabTitle(chatTabs: ChatTabsModel?) -> String {
        guard let chatTabs,
              let activeId = chatTabs.activeTabId,
              let tab = chatTabs.tabs.first(where: { $0.id == activeId })
        else { return "Chat" }
        return tab.displayName
    }

    /// Page-dots under the transcript — one per open tab, active highlighted.
    /// Hidden for a single tab (no switching to indicate).
    @ViewBuilder
    private func pageDots(chatTabs: ChatTabsModel) -> some View {
        if chatTabs.tabs.count > 1 {
            HStack(spacing: 6) {
                ForEach(chatTabs.tabs) { tab in
                    Circle()
                        .fill(tab.id == chatTabs.activeTabId ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
        }
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
            Text("Tap a channel on the Follows tab to start watching its chat.")
        } actions: {
            Button("Go to Follows") {
                showFollows = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
    }
}
