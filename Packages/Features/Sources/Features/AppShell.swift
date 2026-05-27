import SwiftUI
import Accounts

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
            .badge(chatTabsModel.openChannels.isEmpty ? 0 : chatTabsModel.openChannels.count)
            .tag(Tab.chat)
        }
        .environment(\.chatTabs, chatTabsModel)
        // The openChannel action both updates the tab strip model AND switches
        // the visible tab. Concentrating both side effects behind one verb
        // keeps the call sites (e.g. ChannelListScreen row tap) ignorant of
        // the navigation model.
        .environment(\.openChannel, OpenChannelAction { channel, profileImageURL in
            chatTabsModel.open(OpenChannelDescriptor(
                channelId: channel.broadcasterId,
                channelLoginName: channel.broadcasterLogin,
                channelDisplayName: channel.broadcasterName,
                profileImageURL: profileImageURL
            ))
            selectedTab = .chat
        })
    }
}
