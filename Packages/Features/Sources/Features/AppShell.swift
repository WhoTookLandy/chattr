import SwiftUI
import Accounts
import Channels

/// Top-level navigation shell for a signed-in user: a TabView with two tabs.
///
///   - `Follows` — the channel list (ChannelListScreen) inside its own
///     NavigationStack so the Settings push still works.
///   - `Chat` — the multi-channel chat surface (ChatTabsScreen) inside its
///     own NavigationStack so future channel-specific drill-downs (mods,
///     viewers, etc.) can push.
///
/// Each tab's NavigationStack is independent — they don't share back-stacks.
///
/// ## Modern Tab struct syntax (iOS 18+)
///
/// Uses the `Tab(_:systemImage:value:content:)` initializer rather than the
/// pre-iOS-18 "subview + .tabItem + .tag" pattern. Benefits:
///   - Unlocks `Tab(role: .search)` for future search-specific tabs (gets
///     iOS 26's morph-from-tab-icon-to-search-field animation automatically).
///   - Unlocks `.sidebarAdaptable` for iPad layouts (sidebar in landscape,
///     bottom tabs in portrait) with `TabSection` groupings.
///   - Unlocks `.hidden(_:)` with state preservation, `.customizationID(_:)`
///     for user-rearrangeable tab orders persisted via `TabViewCustomization`.
///   - Composes cleanly with `.tabBarMinimizeBehavior(_:)` (iOS 26+).
///
/// ## Auto-minimize on scroll
///
/// `.tabBarMinimizeBehavior(.onScrollDown)` collapses the bottom tab bar to
/// a compact form when the user scrolls down through tab content, and
/// re-expands on scroll up. Both our tabs have meaningful scroll content
/// (Follows = channel list, Chat = paged ChatScreens with their own scroll
/// views), so the behavior is contextual: more vertical real estate while
/// reading; chrome reappears when the user goes back to the top.
///
/// AppShell owns:
///   - `selectedTab`: which tab is visible.
///   - `chatTabsModel`: the open-channel tab strip state.
///
/// It exposes both via `@Environment` to descendants, plus an
/// `OpenChannelAction` closure that descendants (specifically
/// `ChannelListScreen`'s row tap) invoke to "open this channel in chat" —
/// the closure both adds the channel to the model AND switches the tab.
public struct AppShell: View {
    private let account: Account
    private let accountStore: AccountStore

    @State private var selectedTab: AppTab = .follows
    @State private var chatTabsModel = ChatTabsModel()

    /// Read from environment so we can wire close-X → registry.leave below.
    @Environment(\.channelSessionRegistry) private var channelSessionRegistry

    /// Renamed from `Tab` to disambiguate from SwiftUI's `Tab` struct (iOS
    /// 18+). With both in scope inside `body`, unqualified `Tab(...)` would
    /// otherwise resolve to this nested enum and the new init wouldn't compile.
    enum AppTab: Hashable, Sendable {
        case follows, chat
    }

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Follows", systemImage: "person.2.fill", value: AppTab.follows) {
                NavigationStack {
                    ChannelListScreen(account: account, accountStore: accountStore)
                }
            }

            Tab("Chat", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chat) {
                NavigationStack {
                    ChatTabsScreen(
                        account: account,
                        accountStore: accountStore,
                        onAddTab: { selectedTab = .follows }
                    )
                }
            }
            // Badge attaches directly to the Tab struct (vs the old
            // `.tabItem { ... }.badge(...)` chain). Same semantics.
            // The conditional yields 0 (which renders no badge) when no
            // tabs are open — Tab.badge interprets 0 as "hidden".
            .badge(chatTabsModel.tabs.isEmpty ? 0 : chatTabsModel.tabs.count)
        }
        // iOS 26+: tab bar auto-collapses on scroll-down within a tab's
        // content, expands back on scroll-up. Gives the user more vertical
        // room when reading chat / scrolling channel lists.
        //
        // `.onScrollDown` is iOS-only (explicitly unavailable on macOS via
        // SwiftUI's @available annotation), so we gate the modifier here.
        // The SPM cross-platform compile targets macOS for type-checking;
        // without the gate it errors at build time.
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        .environment(\.chatTabs, chatTabsModel)
        // The openChannel action both updates the tab strip model AND switches
        // the visible tab. Concentrating both side effects behind one verb
        // keeps the call sites (e.g. ChannelListScreen row tap) ignorant of
        // the navigation model. Today this wraps a single channel into a new
        // tab; future "add to existing tab" UI would use a separate action.
        .environment(\.openChannel, OpenChannelAction { channelId, login, displayName, profileImageURL in
            let descriptor = ChannelDescriptor(
                channelId: channelId,
                channelLoginName: login,
                channelDisplayName: displayName,
                profileImageURL: profileImageURL
            )
            chatTabsModel.open(channel: descriptor)
            selectedTab = .chat
        })
        // Wire close-X to actually free the underlying ChannelSession(s).
        // The callback receives the closed `ChatTab` so we can iterate its
        // channels and call `registry.leave` for each. Sessions stay alive
        // in the registry if other tabs still reference them — commit E
        // adds proper reference counting; today closing a tab leaves
        // sessions that any other tab is using (single-channel-per-tab
        // means no actual sharing happens yet).
        .onAppear {
            chatTabsModel.onClose = { [accountUserId = account.userId] tab in
                guard let registry = channelSessionRegistry else { return }
                for channel in tab.channels {
                    await registry.leave(accountUserId: accountUserId, channelId: channel.channelId)
                }
            }
        }
    }
}
