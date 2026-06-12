#if DEBUG
import SwiftUI
import SwiftData
import Accounts
import Channels

/// Design-review harness: the full tab shell rendered from mock data, no
/// sign-in required. Launched via the `-uiPreview` argument (wired in
/// `chattrApp`) so the new device flow can be screenshotted on a fresh
/// simulator — same purpose as the `#Preview` blocks, but navigable.
///
/// Mirrors `AppShell`'s TabView structure with presentational stand-ins:
///   - Home: `HomeContent` fed by `HomePreviewData` (the real component).
///   - Chats: real `ChatTabsScreen` with no open tabs — shows the new
///     empty state.
///   - You: real `ProfileScreen` against an in-memory SwiftData container
///     holding one mock account.
///   - Search: real `AddChannelView` in its tab configuration.
///
/// DEBUG-only; never compiled into release builds.
public struct UIPreviewRoot: View {
    private let container: ModelContainer
    private let account: Account
    private let accountStore: AccountStore

    enum PreviewTab: String, Hashable {
        case home, chats, you, search
    }

    /// Initial tab from `-uiPreviewTab <home|chats|you|search>` so each
    /// surface can be screenshotted headlessly without driving the UI.
    @State private var selectedTab: PreviewTab = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-uiPreviewTab"),
           args.indices.contains(index + 1),
           let tab = PreviewTab(rawValue: args[index + 1]) {
            return tab
        }
        return .home
    }()

    public init() {
        do {
            container = try ModelContainer(
                for: Account.self, JoinedChannel.self, PersistedChatTab.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } catch {
            fatalError("UIPreviewRoot: in-memory container failed: \(error)")
        }
        let mock = Account(
            userId: "0",
            login: "whotooklandy",
            displayName: "Andrew",
            profileImageURL: "",
            tokenNamespace: "preview"
        )
        container.mainContext.insert(mock)
        account = mock
        accountStore = AccountStore(modelContainer: container, clientId: "preview")
    }

    /// Open chats for the Chats tab's list. `-uiPreviewChatOpen` leaves
    /// the first tab active so the transcript arrives pushed (for
    /// screenshotting the full-screen chat layout); otherwise the list
    /// root shows.
    @State private var chatTabsModel: ChatTabsModel = {
        let model = ChatTabsModel()
        for tab in HomePreviewData.openTabs {
            model.open(tab)
        }
        if !ProcessInfo.processInfo.arguments.contains("-uiPreviewChatOpen") {
            model.activeTabId = nil
        } else {
            model.activeTabId = model.tabs.first?.id
        }
        // A background tab with an unseen mention, so screenshots of the
        // quick-switcher popover show the red-dot state.
        if model.tabs.count > 1 {
            model.markMention(tabId: model.tabs[1].id)
        }
        return model
    }()

    public var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: PreviewTab.home) {
                NavigationStack {
                    HomeContent(
                        liveStreams: HomePreviewData.streams,
                        userProfiles: [:],
                        liveLoadState: .loaded,
                        openTabs: HomePreviewData.openTabs,
                        onStreamTap: { _ in },
                        onResumeChat: { _ in }
                    )
                    .navigationTitle("Home")
                    .toolbarTitleDisplayMode(.inlineLarge)
                }
            }
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: PreviewTab.chats) {
                ChatTabsScreen(account: account, accountStore: accountStore)
            }
            Tab("You", systemImage: "person.crop.circle", value: PreviewTab.you) {
                NavigationStack {
                    ProfileScreen(account: account, accountStore: accountStore, clientId: "preview")
                }
            }
            Tab(value: PreviewTab.search, role: .search) {
                AddChannelView(
                    account: account,
                    accountStore: accountStore,
                    showsCancelButton: false
                )
            }
        }
        .modelContainer(container)
        .environment(\.chatTabs, chatTabsModel)
    }
}
#endif
