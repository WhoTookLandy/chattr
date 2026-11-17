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
/// this tab — chat pushed or not — is on screen). It feeds the chat stream
/// header, the pill's live dot and the rows here.
struct ChatsScreen: View {
    let account: Account
    let accountStore: AccountStore
    /// The empty state's "See who's live" — switches to Home → Live.
    let onShowLive: () -> Void

    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore

    private var openChannelIds: [String] {
        (chatTabs?.tabs ?? []).flatMap { $0.channels.map(\.channelId) }
    }

    var body: some View {
        NavigationStack {
            OpenChatsList(onShowLive: onShowLive)
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
        .task(id: openChannelIds) {
            guard let channelStatus else { return }
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

/// Owns every read of `activeTabId` / `isPresented` for scene restore, so a
/// pager swipe invalidates this empty view instead of `ChatsScreen`'s stack.
private struct ChatResumeCoordinator: View {
    let chatTabs: ChatTabsModel?

    /// Scene-scoped restoration of the open chat (round-tripped through
    /// `uuidString`; `@SceneStorage` only takes primitives). Not
    /// account-scoped: after an account switch the saved id simply won't
    /// match any of the new account's tabs, and the restore skips it.
    @SceneStorage("chattr.chat.activeTabId") private var persistedActiveTabId: String?

    /// Settings → Chat → Resume Last Chat.
    @AppStorage("chattr.resumeLastChatOnLaunch") private var resumeLastChatOnLaunch = true

    /// Cold start: put the user back in the chat they had open. One-shot.
    @State private var didResume = false

    var body: some View {
        Color.clear
            .onAppear(perform: resumeLastChatIfNeeded)
            // Tabs hydrate from disk asynchronously at launch; retry once they land.
            .onChange(of: chatTabs?.tabs.count) { _, _ in resumeLastChatIfNeeded() }
            // Persist the chat that's open on screen (nil once popped), so
            // "resume last chat" restores what the user was actually in.
            .onChange(of: chatTabs?.activeTabId) { _, newValue in
                if chatTabs?.isPresented == true {
                    persistedActiveTabId = newValue?.uuidString
                }
            }
            .onChange(of: chatTabs?.isPresented) { _, presented in
                persistedActiveTabId = presented == true ? chatTabs?.activeTabId?.uuidString : nil
            }
    }

    private func resumeLastChatIfNeeded() {
        guard !didResume,
              resumeLastChatOnLaunch,
              let chatTabs,
              chatTabs.activeTabId == nil,
              let savedId = persistedActiveTabId,
              let uuid = UUID(uuidString: savedId),
              chatTabs.tabs.contains(where: { $0.id == uuid })
        else { return }
        didResume = true
        chatTabs.activeTabId = uuid
        chatTabs.isPresented = true
    }
}
