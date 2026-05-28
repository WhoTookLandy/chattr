import SwiftUI
import Accounts

/// Root content of the Chat tab.
///
/// Layout (top to bottom):
///   1. The pill tab strip (`ChatTabStrip`) — hidden when no tabs are open.
///   2. A horizontally-paged `ScrollView` of `ChatScreen` pages — one page
///      per open tab. Swipe left/right to switch tabs; tap a pill to jump.
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
///     visible page to `ChatTabsModel.activeTabId`. Tap a pill → write
///     `activeTabId` → ScrollView animates to that page. Swipe → ScrollView
///     writes back to `activeTabId` → pill highlight updates.
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
/// that arrived while the page was off-screen. The "always connected in the
/// background" requirement is satisfied at the session layer, not the view.
public struct ChatTabsScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Called when the user taps the "+" button on the tab strip. AppShell
    /// wires this to "switch the TabView selection to Follows."
    private let onAddTab: () -> Void

    @Environment(\.chatTabs) private var chatTabs

    /// Scene-scoped restoration of the active tab id. `@SceneStorage` only
    /// supports primitive types, so we round-trip through UUID's
    /// `uuidString` representation. Persisted per-scene (each window has
    /// its own active tab — relevant for iPad multi-window where the user
    /// might want one window focused on chat A, another on chat B).
    ///
    /// Lifecycle:
    ///   - On VStack appear, if a saved id matches an existing tab, write
    ///     it back to `chatTabs.activeTabId`. The pill highlights, the
    ///     ScrollView snaps.
    ///   - On every `activeTabId` change (tap a pill, swipe a page), mirror
    ///     the new value back to `@SceneStorage`. The latest selection is
    ///     always durable.
    ///
    /// Tab list itself lives in SwiftData (account-scoped, see
    /// `PersistedChatTab`) — this storage is purely "which one was active
    /// in this scene."
    @SceneStorage("chattr.chat.activeTabId") private var persistedActiveTabId: String?

    public init(
        account: Account,
        accountStore: AccountStore,
        onAddTab: @escaping () -> Void
    ) {
        self.account = account
        self.accountStore = accountStore
        self.onAddTab = onAddTab
    }

    public var body: some View {
        Group {
            if let chatTabs, !chatTabs.tabs.isEmpty {
                VStack(spacing: 0) {
                    ChatTabStrip(model: chatTabs, onAddTab: onAddTab)
                    // Divider removed — the chat scroll's `.scrollEdgeEffectStyle`
                    // (set inside ChatScreen's ScrollView) produces a soft
                    // visual shelf where content dissolves into the
                    // background under the tab strip. Liquid Glass design
                    // prefers this dissolve over a hard line — feels more
                    // continuous with the floating-pill aesthetic.
                    pagedChatContent(chatTabs: chatTabs)
                }
                // Restore the active tab from scene storage. Only applies if
                // the saved id still matches an existing tab — if the user
                // closed that tab in a previous session, fall through to
                // whatever default `chatTabs.activeTabId` already holds
                // (typically the first tab, since pagedChatContent's
                // ScrollView auto-positions to the first child).
                .onAppear {
                    if let savedId = persistedActiveTabId,
                       let uuid = UUID(uuidString: savedId),
                       chatTabs.tabs.contains(where: { $0.id == uuid }) {
                        chatTabs.activeTabId = uuid
                    }
                }
                // Mirror every change back to scene storage. Includes both
                // tap-a-pill writes (ChatTabStrip → model.activeTabId) AND
                // swipe-a-page writes (.scrollPosition → model.activeTabId).
                // nil is written verbatim — restoration tolerates it
                // gracefully via the `if let savedId` guard above.
                .onChange(of: chatTabs.activeTabId) { _, newValue in
                    persistedActiveTabId = newValue?.uuidString
                }
            } else {
                emptyState
            }
        }
        .navigationTitle("Chat")
        .toolbarTitleDisplayMode(.inline)
    }

    /// Horizontally-paged ScrollView with one ChatScreen per open tab.
    /// Swipe left/right to switch tabs; tap a pill in the strip above to jump.
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
        // Two-way bind to activeTabId. Tap-a-pill writes activeTabId in
        // ChatTabsModel → ScrollView animates to that page. Swipe-to-page
        // writes back here → pill highlight in ChatTabStrip updates.
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

    /// Shown when no channel tabs are open. Calls out to the Follows tab.
    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No channels open", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Tap a channel on the Follows tab to start watching its chat.")
        } actions: {
            Button("Go to Follows") {
                onAddTab()
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
    }
}
