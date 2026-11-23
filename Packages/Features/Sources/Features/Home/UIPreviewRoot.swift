#if DEBUG
import SwiftUI
import SwiftData
import Accounts
import Channels
import Core
import DesignSystem

/// Design-review harness: the full tab shell rendered from mock data, no
/// sign-in required. Launched via the `-uiPreview` argument (wired in
/// `chattrApp`) so the new device flow can be screenshotted on a fresh
/// simulator — same purpose as the `#Preview` blocks, but navigable.
///
/// Built like `AppShell`: one `AppNavigation` holds the selected tab, Home's
/// section and stack, the open chats and the Activity inbox, and the tab bar
/// is the shipping one (Home / Chats / Activity / Search, with its badges).
///   - Home: the section bar over `HomeContent` (fed by `HomePreviewData`;
///     `HomeScreen` reads the follows store, absent here) and the real
///     `FollowingList`. Settings (`ProfileScreen`) pushes from the corner
///     button, as it does from the avatar in the app. Tapping a stream opens
///     its chat through `\.openChannel`.
///   - Chats: real `ChatsScreen`, so the chat push is driven by
///     `ChatTabsModel.isPresented` exactly as in the app.
///   - Activity: real `ActivityScreen` (empty).
///   - Search: real `AddChannelView` in its tab configuration.
///
/// Injected, as the app does: `\.chatTabs`, `\.openChannel`, the model
/// container, and the stores that work offline (`\.globalCatalog`,
/// `\.blockStore`, `\.chatImagePrefetcher`; all start empty and nothing here
/// loads them).
///
/// Left out on purpose, because their readers go to the network as soon as
/// they have one and the mock account has no token: `\.followsStore` and
/// `\.channelStatus` (Helix), `\.channelSessionRegistry` (a chat page would
/// open an EventSub socket; without it chats stay empty), `\.playback` (the
/// stream header would load the real stream). The tab-session coordinator
/// isn't started for the same reason.
///
/// DEBUG-only; never compiled into release builds.
public struct UIPreviewRoot: View {
    private let container: ModelContainer
    private let account: Account
    private let accountStore: AccountStore
    private let blockStore: BlockStore

    /// The shell's navigation state, seeded with the mock open chats and
    /// positioned by the launch arguments so each surface can be
    /// screenshotted headlessly without driving the UI:
    ///
    ///   - `-uiPreviewTab <home|chats|activity|search>` selects a tab;
    ///     `live` / `following` select Home's section; `you` opens Settings
    ///     on Home.
    ///   - `-uiPreviewChatOpen` lands on Chats with the first chat pushed
    ///     (for screenshotting the full-screen chat layout); otherwise the
    ///     Chats tab shows its list.
    @State private var navigation: AppNavigation = {
        let navigation = AppNavigation()
        let arguments = ProcessInfo.processInfo.arguments
        let chatTabs = navigation.chatTabs
        for tab in HomePreviewData.openTabs {
            chatTabs.open(tab)
        }
        // `open` presents each tab as it adds it; put the pager where the
        // arguments want it.
        let chatOpen = arguments.contains("-uiPreviewChatOpen")
        chatTabs.activeTabId = chatOpen ? chatTabs.tabs.first?.id : nil
        chatTabs.isPresented = chatOpen
        if chatOpen {
            navigation.selectedTab = .chats
        }
        // A background tab with an unseen mention, so screenshots of the
        // quick-switcher popover show the red-dot state.
        if chatTabs.tabs.count > 1 {
            chatTabs.markMention(tabId: chatTabs.tabs[1].id)
        }

        if let index = arguments.firstIndex(of: "-uiPreviewTab"),
           arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "chats": navigation.selectedTab = .chats
            case "activity": navigation.selectedTab = .activity
            case "search": navigation.selectedTab = .search
            case "you": navigation.homePath = [.profile]
            case "following": navigation.homeSection = .following
            default: break  // "home" / "live": where the shell starts
            }
        }
        return navigation
    }()

    @State private var globalCatalog = GlobalCatalog()
    @State private var chatImagePrefetcher = ChatImagePrefetcher()

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var canAutoHideTabBar: Bool {
        horizontalSizeClass == .compact || verticalSizeClass == .compact
    }

    private var effectiveHomeTabBarHidden: Bool {
        canAutoHideTabBar
            && navigation.selectedTab == .home
            && navigation.homePath.isEmpty
            && navigation.isHomeTabBarHidden
    }
    #endif

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
        let store = AccountStore(modelContainer: container, clientId: "preview")
        accountStore = store
        blockStore = BlockStore(accountUserId: mock.userId, accountStore: store)
    }

    public var body: some View {
        @Bindable var navigation = navigation
        // The same action the shell injects; Home's mock streams open
        // through it the way `HomeScreen`'s do.
        let openChannel = OpenChannelAction(navigation)
        let tabBarHiddenBinding = homeTabBarHiddenBinding($navigation.isHomeTabBarHidden)
        TabView(selection: $navigation.selectedTab) {
            // Icon-only tabs — mirrors AppShell's custom-`label` tabs so the
            // design-review harness reflects the shipping tab bar.
            Tab(value: AppShell.AppTab.home) {
                // Mirrors `HomeScreen`'s structure, but Live is fed mock
                // streams (`HomeScreen` reads the real, here-absent stores).
                NavigationStack(path: $navigation.homePath) {
                    VStack(spacing: 0) {
                        HomeSectionBar(selection: $navigation.homeSection)
                            .overlay(alignment: .trailing) {
                                profileButton
                                    .padding(.trailing, 16)
                            }
                        Group {
                            switch navigation.homeSection {
                            case .live:
                                HomeContent(
                                    liveStreams: HomePreviewData.streams,
                                    profileImageURLs: [:],
                                    liveLoadState: .loaded,
                                    recentChannels: HomePreviewData.recentChannels,
                                    isActive: false,
                                    isTabBarAutoHideActive: navigation.selectedTab == .home && navigation.homePath.isEmpty,
                                    isTabBarHidden: tabBarHiddenBinding,
                                    onStreamTap: { stream, intent in
                                        openChannel(stream: stream, profileImageURL: nil, intent: intent)
                                    },
                                    onRecentChannelTap: { item, intent in
                                        openChannel(
                                            ChannelDescriptor(
                                                platform: .twitch,
                                                channelId: item.broadcasterId,
                                                channelLoginName: item.broadcasterLogin,
                                                channelDisplayName: item.broadcasterName,
                                                profileImageURL: item.profileImageURL
                                            ),
                                            intent: intent
                                        )
                                    }
                                )
                            case .following:
                                FollowingList(
                                    account: account,
                                    accountStore: accountStore,
                                    isActive: navigation.selectedTab == .home && navigation.homePath.isEmpty,
                                    isTabBarHidden: tabBarHiddenBinding
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color.chatSurface.ignoresSafeArea())
                    #if os(iOS)
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbarVisibility(effectiveHomeTabBarHidden ? .hidden : .automatic, for: .tabBar)
                    .onChange(of: navigation.homeSection) { _, _ in
                        withAnimation(.snappy(duration: 0.25)) {
                            navigation.isHomeTabBarHidden = false
                        }
                    }
                    .onChange(of: navigation.homePath.isEmpty) { _, isEmpty in
                        if !isEmpty { navigation.isHomeTabBarHidden = false }
                    }
                    .onChange(of: navigation.selectedTab) { _, tab in
                        if tab != .home { navigation.isHomeTabBarHidden = false }
                    }
                    #endif
                    .navigationDestination(for: HomeRoute.self) { route in
                        switch route {
                        case .profile:
                            ProfileScreen(account: account, accountStore: accountStore, clientId: "preview")
                        }
                    }
                }
            } label: {
                Image(systemName: "house")
            }
            .accessibilityLabel("Home")
            Tab(value: AppShell.AppTab.chats) {
                ChatsScreen(account: account, accountStore: accountStore, navigation: navigation)
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            .badge(navigation.chatTabs.mentionedTabIds.count)
            .accessibilityLabel("Chats")
            Tab(value: AppShell.AppTab.activity) {
                ActivityScreen(store: navigation.activity)
            } label: {
                Image(systemName: "bell")
            }
            .badge(navigation.activity.unreadCount)
            .accessibilityLabel("Activity")
            Tab(value: AppShell.AppTab.search, role: .search) {
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
        .environment(\.chatTabs, navigation.chatTabs)
        .environment(\.openChannel, openChannel)
        .environment(\.globalCatalog, globalCatalog)
        .environment(\.blockStore, blockStore)
        .environment(\.chatImagePrefetcher, chatImagePrefetcher)
    }

    private func homeTabBarHiddenBinding(_ binding: Binding<Bool>) -> Binding<Bool>? {
        #if os(iOS)
        canAutoHideTabBar ? binding : nil
        #else
        nil
        #endif
    }

    /// Stands in for `HomeScreen`'s avatar button (the mock account has no
    /// profile image): Settings, pushed on Home.
    private var profileButton: some View {
        Button {
            navigation.homePath.append(.profile)
        } label: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("You")
        .accessibilityHint("Settings and accounts")
    }
}
#endif
