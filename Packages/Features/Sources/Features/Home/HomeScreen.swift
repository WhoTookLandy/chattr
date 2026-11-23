import SwiftUI
import Accounts
import Core
import TwitchKit
import DesignSystem
import Nuke
import NukeUI

/// The Home tab — the app's landing surface. Two Twitch-style text tabs
/// across the top (`HomeSectionBar`), which also page with a horizontal
/// swipe, and the account avatar in the corner (→ You: settings, accounts).
///
///   - **Live** — a top horizontal rail of recently-streamed followed
///     channels, category chips, and a consistent full-bleed live stream feed
///     with inline muted video previews (`HomeContent`).
///   - **Following** — every followed channel in Live / Offline sections
///     (`FollowingList`).
///
/// Open chats live in their own tab (`ChatsScreen`); tapping a channel here
/// opens it there.
public struct HomeScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Threaded to ProfileScreen → the account switcher ("Add Account").
    private let clientId: String
    /// Which section is showing. Owned by AppNavigation.
    @Binding private var section: HomeSection
    /// Whether the Home tab is currently selected in `AppShell`.
    private let isTabSelected: Bool

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.openChannel) private var openChannel

    /// The Home stack. Owned by AppNavigation, so a link can push Settings.
    @Binding private var path: [HomeRoute]

    /// Whether scrolling down Home's feed has auto-hidden the bottom tab bar.
    /// Owned by AppNavigation so `MiniPlayerHost` can adjust its bottom inset
    /// without observing scroll geometry directly.
    @Binding private var isTabBarHidden: Bool

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Auto-hide only when the tab bar lives at the bottom (iPhone in portrait
    /// or landscape, and compact iPad Slide Over / Split View). Full-screen
    /// iPad keeps its top floating tab bar visible.
    private var canAutoHideTabBar: Bool {
        horizontalSizeClass == .compact || verticalSizeClass == .compact
    }

    private var effectiveTabBarHidden: Bool {
        canAutoHideTabBar && isTabSelected && path.isEmpty && isTabBarHidden
    }
    #endif

    /// Cap on offline channels surfaced in the top recent-channels rail so
    /// scrolling across it keeps lazy `/videos` lookups bounded.
    private static let recentRailLimit = 20

    public init(
        account: Account,
        accountStore: AccountStore,
        clientId: String,
        section: Binding<HomeSection>,
        path: Binding<[HomeRoute]>,
        isTabSelected: Bool = true,
        isTabBarHidden: Binding<Bool> = .constant(false)
    ) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
        self._section = section
        self._path = path
        self.isTabSelected = isTabSelected
        self._isTabBarHidden = isTabBarHidden
    }

    public var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HomeSectionBar(selection: $section)
                    .overlay(alignment: .trailing) {
                        profileButton
                            .padding(.trailing, 16)
                    }
                sectionPager
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.chatSurface.ignoresSafeArea())
            // The section bar IS the header; no nav-bar title above it.
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            .toolbarVisibility(effectiveTabBarHidden ? .hidden : .automatic, for: .tabBar)
            #endif
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .profile:
                    ProfileScreen(account: account, accountStore: accountStore, clientId: clientId)
                }
            }
        }
        #if os(iOS)
        .onChange(of: section) { _, _ in
            revealTabBar(animated: true)
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            if !isEmpty {
                revealTabBar(animated: false)
            }
        }
        .onChange(of: isTabSelected) { _, selected in
            if !selected {
                revealTabBar(animated: false)
            }
        }
        .onChange(of: canAutoHideTabBar) { _, allowed in
            if !allowed {
                revealTabBar(animated: false)
            }
        }
        #endif
        // Live data whenever Home appears (tab switches included), plus the
        // followed roster (cached on disk) so the top recent-channels rail
        // populates right away. Both run on `@MainActor` and are throttled /
        // idempotent in FollowsStore.
        .task {
            await followsStore?.refreshLive(account: account, accountStore: accountStore)
        }
        .task {
            await followsStore?.loadAllIfNeeded(account: account, accountStore: accountStore)
        }
    }

    #if os(iOS)
    private func revealTabBar(animated: Bool) {
        guard isTabBarHidden else { return }
        if animated {
            withAnimation(.snappy(duration: 0.25)) {
                isTabBarHidden = false
            }
        } else {
            isTabBarHidden = false
        }
    }
    #endif

    /// You → settings, accounts, appearance. The avatar in the corner is
    /// where iOS apps keep the account.
    private var profileButton: some View {
        Button {
            path.append(.profile)
        } label: {
            LazyImage(request: ImageRequest.avatar(url: URL(string: account.profileImageURL), side: 32)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("You")
        .accessibilityHint("Settings and accounts")
    }

    /// Live / Following, swipeable side to side (iOS); the bar's tabs and
    /// the swipe drive the same `section`.
    @ViewBuilder
    private var sectionPager: some View {
        #if os(iOS)
        TabView(selection: $section) {
            ForEach(HomeSection.allCases, id: \.self) { section in
                sectionContent(section)
                    .tag(section)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        sectionContent(section)
        #endif
    }

    /// Offline follows shown in the top rail. Helix has no batch last-live
    /// endpoint (`/videos` is one call per broadcaster), so this intentionally
    /// takes the first `recentRailLimit` offline follows in follow order and
    /// resolves each card's last broadcast lazily on appear rather than fanning
    /// out hundreds of requests up front.
    private var recentChannels: [RecentChannelItem] {
        guard let followsStore else { return [] }
        return followsStore.sortedAllChannels
            .lazy
            .filter { followsStore.liveStreams[$0.broadcasterId] == nil }
            .prefix(Self.recentRailLimit)
            .map { channel in
                RecentChannelItem(
                    broadcasterId: channel.broadcasterId,
                    broadcasterLogin: channel.broadcasterLogin,
                    broadcasterName: channel.broadcasterName,
                    profileImageURL: followsStore.profileImageURLs[channel.broadcasterId]
                )
            }
    }

    private var tabBarHiddenBinding: Binding<Bool>? {
        #if os(iOS)
        canAutoHideTabBar ? $isTabBarHidden : nil
        #else
        nil
        #endif
    }

    @ViewBuilder
    private func sectionContent(_ section: HomeSection) -> some View {
        switch section {
        case .live:
            HomeContent(
                liveStreams: followsStore?.liveStreamsOrdered ?? [],
                profileImageURLs: followsStore?.profileImageURLs ?? [:],
                liveLoadState: followsStore?.liveLoadState ?? .idle,
                recentChannels: recentChannels,
                isActive: isTabSelected && self.section == .live && path.isEmpty,
                isTabBarHidden: tabBarHiddenBinding,
                onStreamTap: { stream, intent in
                    let profileURL = followsStore?.profileImageURLs[stream.userId]
                    openChannel?(stream: stream, profileImageURL: profileURL, intent: intent)
                },
                onRecentChannelTap: { item, intent in
                    openChannel?(
                        ChannelDescriptor(
                            platform: .twitch,
                            channelId: item.broadcasterId,
                            channelLoginName: item.broadcasterLogin,
                            channelDisplayName: item.broadcasterName,
                            profileImageURL: item.profileImageURL
                        ),
                        intent: intent
                    )
                },
                onRecentChannelAppear: { broadcasterId in
                    channelStatus?.ensureLastLive(
                        channelId: broadcasterId,
                        account: account,
                        accountStore: accountStore
                    )
                }
            )
            .refreshable {
                // Explicit user intent — bypass the staleness throttle.
                await followsStore?.refreshLive(account: account, accountStore: accountStore, force: true)
            }
        case .following:
            FollowingList(
                account: account,
                accountStore: accountStore,
                isActive: isTabSelected && self.section == .following && path.isEmpty,
                isTabBarHidden: tabBarHiddenBinding
            )
        }
    }
}
