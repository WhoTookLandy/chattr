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

    @State private var selectedTab: Tab = .follows
    @State private var chatTabsModel = ChatTabsModel()

    /// Read from environment so we can wire close-X → registry.leave below.
    @Environment(\.channelSessionRegistry) private var channelSessionRegistry

    enum Tab: Hashable, Sendable {
        case follows, chat
    }

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            // Follows tab
            NavigationStack {
                ChannelListScreen(account: account, accountStore: accountStore)
            }
            .tabItem {
                Label("Follows", systemImage: "person.2.fill")
            }
            .tag(Tab.follows)

            // Chat tab
            NavigationStack {
                ChatTabsScreen(
                    account: account,
                    accountStore: accountStore,
                    onAddTab: { selectedTab = .follows }
                )
            }
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .badge(chatTabsModel.tabs.isEmpty ? 0 : chatTabsModel.tabs.count)
            .tag(Tab.chat)
        }
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
