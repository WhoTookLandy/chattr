import SwiftUI
import Accounts
import DesignSystem

/// The Chats tab: open chats (`OpenChatsList`), Live first. Tapping one
/// pushes the full-screen `ChatPagerScreen` (tab bar hidden).
///
/// The push is driven by `ChatTabsModel.isPresented` — never by
/// `activeTabId` (see its doc for the back-button freeze that caused).
/// Opening a channel from anywhere presents a tab and AppNavigation
/// switches to this tab.
///
/// Owns the open channels' status polling (one batched call a minute while
/// this tab — chat pushed or not — is on screen and the app is in the
/// foreground). It feeds the chat stream header, the pill's live dot and the
/// rows here.
struct ChatsScreen: View {
    let account: Account
    let accountStore: AccountStore
    /// For the empty state's "See who's live" (Home → Live). The model by
    /// reference rather than a closure, so this view's inputs compare equal
    /// when AppShell's body re-runs (every badge change) and its body isn't
    /// re-run with it.
    let navigation: AppNavigation

    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore
    @Environment(\.scenePhase) private var scenePhase

    private var openChannelIds: [String] {
        (chatTabs?.tabs ?? []).flatMap { $0.channels.map(\.channelId) }
    }

    /// Restarts the status poll when the open channels change or the app
    /// enters / leaves the background.
    private struct StatusPollKey: Equatable {
        let channelIds: [String]
        let inForeground: Bool
    }

    var body: some View {
        NavigationStack {
            OpenChatsList(onShowLive: { navigation.showLive() })
                .refreshable {
                    await channelStatus?.refresh(
                        channelIds: openChannelIds, account: account, accountStore: accountStore, force: true
                    )
                }
                .background(Color.chatSurface.ignoresSafeArea())
                .navigationTitle("Chats")
                .toolbar { editMenu }
                .navigationDestination(isPresented: chatIsPresented) {
                    ChatPagerScreen(account: account, accountStore: accountStore)
                }
        }
        .task(id: StatusPollKey(channelIds: openChannelIds, inForeground: scenePhase != .background)) {
            // Not while backgrounded: background audio and PiP keep the app
            // running, and nothing on screen shows these statuses. Coming
            // back restarts the loop; the store's own staleness check keeps
            // a quick hop from refetching.
            guard let channelStatus else { return }
            // A closed chat's stream state is never refreshed again; drop it
            // rather than let it answer "live" from memory.
            channelStatus.retainStreamState(forOpenChannels: openChannelIds)
            guard scenePhase != .background else { return }
            while !Task.isCancelled {
                await channelStatus.refresh(
                    channelIds: openChannelIds,
                    account: account,
                    accountStore: accountStore
                )
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Resume-last-chat and its scene storage live in their own empty
        // view: reading `activeTabId` here (and writing `@SceneStorage` on
        // every page change) re-ran this whole stack — toolbar, open-chats
        // list and its sort — on every pager swipe.
        .background { ChatResumeCoordinator(chatTabs: chatTabs) }
    }

    /// Bulk tidy-up: close every offline chat, or everything.
    @ToolbarContentBuilder
    private var editMenu: some ToolbarContent {
        if let chatTabs, !chatTabs.tabs.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        chatTabs.close(tabIds: offlineTabIds(chatTabs))
                    } label: {
                        Label("Close Offline Chats", systemImage: "moon.zzz")
                    }
                    .disabled(offlineTabIds(chatTabs).isEmpty)
                    Button(role: .destructive) {
                        chatTabs.close(tabIds: chatTabs.tabs.map(\.id))
                    } label: {
                        Label("Close All Chats", systemImage: "xmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Manage chats")
            }
        }
    }

    private func offlineTabIds(_ chatTabs: ChatTabsModel) -> [UUID] {
        chatTabs.tabs.filter { tab in
            guard let id = tab.channels.first?.channelId else { return false }
            return ChannelStatusStore.liveStream(for: id, status: channelStatus, follows: followsStore) == nil
        }.map(\.id)
    }

    private var chatIsPresented: Binding<Bool> {
        Binding(
            get: {
                guard let chatTabs else { return false }
                return chatTabs.isPresented && chatTabs.activeTabId != nil && !chatTabs.tabs.isEmpty
            },
            set: { presented in
                // Only the flag — never touch activeTabId here (see
                // ChatTabsModel.isPresented for the freeze that caused).
                chatTabs?.isPresented = presented
            }
        )
    }
}
