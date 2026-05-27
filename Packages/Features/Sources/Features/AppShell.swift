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
            .badge(chatTabsModel.openChannels.isEmpty ? 0 : chatTabsModel.openChannels.count)
            .tag(Tab.chat)
        }
        .environment(\.chatTabs, chatTabsModel)
        // The openChannel action both updates the tab strip model AND switches
        // the visible tab. Concentrating both side effects behind one verb
        // keeps the call sites (e.g. ChannelListScreen row tap) ignorant of
        // the navigation model.
        .environment(\.openChannel, OpenChannelAction { channelId, login, displayName, profileImageURL in
            chatTabsModel.open(OpenChannelDescriptor(
                channelId: channelId,
                channelLoginName: login,
                channelDisplayName: displayName,
                profileImageURL: profileImageURL
            ))
            selectedTab = .chat
        })
        // Wire close-X to actually free the underlying ChannelSession.
        // Without this, sessions accumulate in the registry indefinitely as the
        // user opens and closes channels. ChannelSession.start() tolerates
        // HelixError.conflict on re-open (Twitch's subscription persists across
        // close until WebSocket disconnect), so this cleanup is safe — the user
        // can close a channel and re-open it without breakage.
        .onAppear {
            chatTabsModel.onClose = { [accountUserId = account.userId] channelId in
                await channelSessionRegistry?.leave(accountUserId: accountUserId, channelId: channelId)
            }
        }
    }
}
