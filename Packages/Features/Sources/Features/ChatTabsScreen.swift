import SwiftUI
import Accounts

/// Root content of the Chat tab.
///
/// Layout (top to bottom):
///   1. The pill tab strip (`ChatTabStrip`) — hidden when no tabs are open.
///   2. The active channel's `ChatScreen`, or an empty state CTA when no
///      tabs are open.
///
/// `ChatScreen` is re-instantiated when `activeChannelId` changes (via the
/// `.id(...)` modifier), so SwiftUI tears down the previous chat's stream
/// subscription and starts a fresh one for the newly-active channel. The
/// underlying `ChannelSession` stays alive in the registry though — only the
/// SwiftUI consumer changes.
public struct ChatTabsScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Called when the user taps the "+" button on the tab strip. AppShell
    /// wires this to "switch the TabView selection to Follows."
    private let onAddTab: () -> Void

    @Environment(\.chatTabs) private var chatTabs

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
                    Divider()
                    activeChatContent(chatTabs: chatTabs)
                }
            } else {
                emptyState
            }
        }
        .navigationTitle("Chat")
        .toolbarTitleDisplayMode(.inline)
    }

    /// Renders the ChatScreen for the currently-active channel. `.id(...)`
    /// forces a fresh subscription when the user switches tabs — otherwise
    /// SwiftUI would diff the existing ChatScreen and keep its session
    /// subscription pointed at the old channel.
    @ViewBuilder
    private func activeChatContent(chatTabs: ChatTabsModel) -> some View {
        if let activeId = chatTabs.activeTabId,
           let active = chatTabs.tabs.first(where: { $0.id == activeId }),
           let primaryChannel = active.channels.first {
            // MVP: render the tab's first (and today, only) channel. When
            // multi-channel-per-tab ships, ChatScreen will take the full
            // ChatTab and TabChatModel will attach to all its channels —
            // for now, the single-channel path keeps the View thin.
            ChatScreen(
                account: account,
                accountStore: accountStore,
                channelId: primaryChannel.channelId,
                channelLoginName: primaryChannel.channelLoginName,
                channelDisplayName: primaryChannel.channelDisplayName
            )
            // Identity by tab id, NOT channel id — different tabs containing
            // the same channel must have distinct view identities.
            .id(active.id)
        } else {
            // Tabs exist but none selected — rare (we set activeChannelId on
            // open). Show a small hint.
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("Pick a channel above")
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
        }
    }
}
