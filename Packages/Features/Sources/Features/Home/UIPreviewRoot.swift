#if DEBUG
import SwiftUI
import SwiftData
import Accounts
import Channels
import DesignSystem

/// Design-review harness: the full tab shell rendered from mock data, no
/// sign-in required. Launched via the `-uiPreview` argument (wired in
/// `chattrApp`) so the new device flow can be screenshotted on a fresh
/// simulator — same purpose as the `#Preview` blocks, but navigable.
///
/// Mirrors `AppShell`'s TabView structure with presentational stand-ins:
///   - Home: the section bar over `HomeContent` (fed by `HomePreviewData`),
///     the real `FollowingList` and the real `OpenChatsList`.
///   - Activity: real `ActivityScreen` (empty).
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
        case home, activity, you, search
    }

    /// Initial tab from `-uiPreviewTab <home|activity|you|search>` so each
    /// surface can be screenshotted headlessly without driving the UI.
    /// (`live|following|chats` select Home's section instead; see
    /// `homeSection`.)
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

    /// Home's section; `-uiPreviewTab following` lands on Following,
    /// everything else on Live. (Chats is its own tab in the app.)
    @State private var homeSection: HomeSection = {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-uiPreviewTab"),
           args.indices.contains(index + 1),
           let section = HomeSection(rawValue: args[index + 1]) {
            return section
        }
        return .live
    }()

    @State private var activity = ActivityStore()

    public var body: some View {
        TabView(selection: $selectedTab) {
            // Icon-only tabs — mirrors AppShell's custom-`label` tabs so the
            // design-review harness reflects the shipping tab bar.
            Tab(value: PreviewTab.home) {
                // Mirrors `HomeScreen`'s structure, but Live is fed mock
                // streams (`HomeScreen` reads the real, here-absent stores).
                NavigationStack {
                    VStack(spacing: 0) {
                        HomeSectionBar(selection: $homeSection)
                        Group {
                            switch homeSection {
                            case .live:
                                HomeContent(
                                    liveStreams: HomePreviewData.streams,
                                    profileImageURLs: [:],
                                    liveLoadState: .loaded,
                                    onStreamTap: { _, _ in }
                                )
                            case .following:
                                FollowingList(account: account, accountStore: accountStore)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color.chatSurface.ignoresSafeArea())
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    #endif
                    .navigationDestination(isPresented: chatIsPresented) {
                        ChatPagerScreen(account: account, accountStore: accountStore)
                    }
                }
            } label: {
                Image(systemName: "house")
            }
            .accessibilityLabel("Home")
            Tab(value: PreviewTab.activity) {
                ActivityScreen(store: activity)
            } label: {
                Image(systemName: "bell")
            }
            .accessibilityLabel("Activity")
            Tab(value: PreviewTab.you) {
                NavigationStack {
                    ProfileScreen(account: account, accountStore: accountStore, clientId: "preview")
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .accessibilityLabel("You")
            Tab(value: PreviewTab.search, role: .search) {
                AddChannelView(
                    account: account,
                    accountStore: accountStore,
                    showsCancelButton: false
                )
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search")
        }
        .modelContainer(container)
        .environment(\.chatTabs, chatTabsModel)
    }

    private var chatIsPresented: Binding<Bool> {
        Binding(
            get: { chatTabsModel.activeTabId != nil && !chatTabsModel.tabs.isEmpty },
            set: { if !$0 { chatTabsModel.activeTabId = nil } }
        )
    }
}
#endif
