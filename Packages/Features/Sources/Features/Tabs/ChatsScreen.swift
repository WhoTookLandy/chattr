import SwiftUI
import Accounts
import Core
import DesignSystem

private let logger = AppLogger.make("Features.ChatsScreen")

/// The Chats tab: open chats (`OpenChatsList`), Live first. Tapping one
/// pushes the full-screen `ChatPagerScreen` (tab bar hidden) — or, on a
/// screen with room for both (iPad, unfolded foldable iPhone), shows it
/// beside the list in a `NavigationSplitView`.
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

    /// Split layout (open chats beside the chat) when the tab has room for
    /// both: iPad and an unfolded foldable iPhone. Decided from the space the
    /// tab actually gets rather than size classes — an unfolded foldable
    /// doesn't reliably report regular/regular the way an iPad does, so a
    /// size-class gate left it on the phone layout. Folding / unfolding flips
    /// this live; the open chat carries across because both layouts present
    /// from `isPresented`.
    @State private var usesSplitLayout = false

    /// Room for a ~320pt list plus a chat column at least as wide as a phone.
    private static let splitMinWidth: CGFloat = 700
    /// Keeps a Plus/Max iPhone in landscape (~930 × ~400pt) on the
    /// full-width chat and its landscape stream stage.
    private static let splitMinHeight: CGFloat = 500

    /// Rounded geometry + split decision for `onGeometryChange` so only
    /// whole-point resizes or layout flips trigger the callback.
    private struct ChatsGeometry: Equatable {
        let width: Int
        let height: Int
        let fitsSplit: Bool

        init(size: CGSize, fitsSplit: Bool) {
            self.width = Int(size.width.rounded())
            self.height = Int(size.height.rounded())
            self.fitsSplit = fitsSplit
        }
    }

    private static func fitsSplit(_ size: CGSize) -> Bool {
        size.width >= splitMinWidth && size.height >= splitMinHeight
    }

    /// Compact (iPhone, folded): Messages-style list that pushes the
    /// full-screen pager.
    private var stackLayout: some View {
        NavigationStack {
            chatsList(highlightsActiveChat: false)
                .navigationDestination(isPresented: chatIsPresented) {
                    ChatPagerScreen(account: account, accountStore: accountStore)
                }
        }
    }

    /// Roomy (iPad, unfolded): open chats in the sidebar, the pager as the
    /// detail. `isPresented` keeps meaning "a chat is on screen" — a row tap
    /// sets it, and with none chosen the detail shows a placeholder — so
    /// mention clearing, keep-awake, the mini player and resume-last-chat
    /// behave exactly as in the stack layout.
    private var splitLayout: some View {
        NavigationSplitView {
            chatsList(highlightsActiveChat: true)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
        } detail: {
            ChatSplitDetail(account: account, accountStore: accountStore, chatTabs: chatTabs)
        }
        .navigationSplitViewStyle(.balanced)
        #if os(iOS)
        // NavigationSplitView collapses into a single stack whenever the
        // horizontal size class is compact — which an unfolded foldable can
        // report even with tablet-sized room. We only get here once the
        // measured size fits both columns, so keep it expanded.
        .environment(\.horizontalSizeClass, .regular)
        #endif
    }

    private func chatsList(highlightsActiveChat: Bool) -> some View {
        OpenChatsList(onShowLive: { navigation.showLive() }, highlightsActiveChat: highlightsActiveChat)
            .refreshable {
                await channelStatus?.refresh(
                    channelIds: openChannelIds, account: account, accountStore: accountStore, force: true
                )
            }
            .background(Color.chatSurface.ignoresSafeArea())
            .navigationTitle("Chats")
            .toolbar { editMenu }
    }

    var body: some View {
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                stackLayout
            }
        }
        // `action` only runs when the Bool flips, so resizes within one
        // layout (rotation on iPad, Stage Manager drags) don't rebuild it.
        // Measured on a backdrop that ignores the keyboard: typing in the
        // chat shrinks the tab's height, which must not flip the layout and
        // remount the chat mid-message.
        .background {
            Color.clear
                .onGeometryChange(for: ChatsGeometry.self) { proxy in
                    ChatsGeometry(size: proxy.size, fitsSplit: Self.fitsSplit(proxy.size))
                } action: { geo in
                    let changed = usesSplitLayout != geo.fitsSplit
                    if changed {
                        usesSplitLayout = geo.fitsSplit
                    }
                    ChatDiagnostics.shared.updatePagerLayout(
                        usesSplitLayout: geo.fitsSplit,
                        containerSize: CGSize(width: geo.width, height: geo.height)
                    )
                    if changed {
                        logger.info("ChatsScreen layout → \(geo.fitsSplit ? "split" : "stack", privacy: .public) (\(geo.width)x\(geo.height))")
                    }
                }
                .ignoresSafeArea(.keyboard)
                .allowsHitTesting(false)
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

/// The split layout's detail column: the pager while a chat is presented,
/// otherwise a placeholder. Its own view so the `activeTabId` /
/// `isPresented` reads invalidate only this column — not `ChatsScreen`,
/// whose body also builds the sidebar list.
private struct ChatSplitDetail: View {
    let account: Account
    let accountStore: AccountStore
    let chatTabs: ChatTabsModel?

    private var showsChat: Bool {
        guard let chatTabs else { return false }
        return chatTabs.isPresented && chatTabs.activeTabId != nil && !chatTabs.tabs.isEmpty
    }

    var body: some View {
        if showsChat {
            ChatPagerScreen(account: account, accountStore: accountStore, hidesTabBar: false)
                // The tab bar stays visible here, so the user can leave for
                // another tab and come back with the chat still presented.
                // A ping that arrived meanwhile was badged; acknowledge it.
                .onAppear { chatTabs?.acknowledgePresentedMention() }
        } else {
            ContentUnavailableView {
                Label("No chat selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Pick a chat from the list.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.chatSurface.ignoresSafeArea())
        }
    }
}
