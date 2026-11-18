import SwiftUI
import Accounts
import TwitchKit
import DesignSystem
import Nuke
import NukeUI

/// The Home tab — the app's landing surface. Two Twitch-style text tabs
/// across the top (`HomeSectionBar`), which also page with a horizontal
/// swipe, and the account avatar in the corner (→ You: settings, accounts).
///
///   - **Live** — who you follow that's on now (`HomeContent`): category
///     chips, two featured cards, then every other live channel as rows.
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

    @Environment(\.followsStore) private var followsStore
    @Environment(\.openChannel) private var openChannel

    @State private var path: [HomeRoute] = []

    public init(
        account: Account,
        accountStore: AccountStore,
        clientId: String,
        section: Binding<HomeSection>
    ) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
        self._section = section
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
            #endif
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .allFollows:
                    ChannelListScreen(
                        account: account,
                        accountStore: accountStore,
                        initialMode: .live
                    )
                case .profile:
                    ProfileScreen(account: account, accountStore: accountStore, clientId: clientId)
                }
            }
        }
        // Live data whenever Home appears (tab switches included).
        // Throttled + coalesced in FollowsStore, so a recent refresh is a
        // no-op.
        .task {
            await followsStore?.refreshLive(account: account, accountStore: accountStore)
        }
    }

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

    @ViewBuilder
    private func sectionContent(_ section: HomeSection) -> some View {
        switch section {
        case .live:
            HomeContent(
                liveStreams: followsStore?.liveStreamsOrdered ?? [],
                profileImageURLs: followsStore?.profileImageURLs ?? [:],
                liveLoadState: followsStore?.liveLoadState ?? .idle,
                onStreamTap: { stream, intent in
                    let profileURL = followsStore?.profileImageURLs[stream.userId]
                    openChannel?(stream: stream, profileImageURL: profileURL, intent: intent)
                }
            )
            .refreshable {
                // Explicit user intent — bypass the staleness throttle.
                await followsStore?.refreshLive(account: account, accountStore: accountStore, force: true)
            }
        case .following:
            FollowingList(account: account, accountStore: accountStore)
        }
    }
}

/// Navigation routes Home can push.
enum HomeRoute: Hashable {
    case allFollows
    case profile
}

/// Home → Live. Presentational: everything arrives as plain values — no
/// stores, no account — so `#Preview` can drive every state. (Open chats
/// used to sit above this as an avatar rail; they're Home's Chats section
/// now.)
struct HomeContent: View {
    let liveStreams: [TwitchStream]
    let profileImageURLs: [String: URL]
    let liveLoadState: FollowsStore.LoadState
    /// The stream row was tapped (`.implicit`) or a preview-menu action
    /// chose how to watch (`.explicit`).
    let onStreamTap: (TwitchStream, ChatOpenIntent) -> Void

    /// Category chip selection; nil = All.
    @State private var selectedCategory: String?

    var body: some View {
        // Derived once per pass: the chips, the header count and the rows
        // all read it, and each used to re-total the categories.
        let feed = liveFeed
        ScrollViewReader { proxy in
            List {
                liveSection(feed)
            }
            .listStyle(.plain)
            // Rows stay transparent so the shared chat surface reads through;
            // the surface itself is drawn behind the list below. Same flat
            // `Color.chatSurface` the chat screen uses, so Home and Chats share
            // one background world instead of Home wearing a tinted gradient.
            .scrollContentBackground(.hidden)
            .background(Color.chatSurface.ignoresSafeArea())
            // Hard top edge: a defined boundary under the title. The soft
            // style let scrolled thumbnails ghost through the bar area,
            // which read as smudge over a media-heavy feed. Bottom stays
            // soft — content fading toward the tab bar is fine.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #if DEBUG
            // `-uiPreviewScrolled` jumps the list to the bottom so the
            // design-review harness can screenshot the scrolled-state top
            // edge without driving the UI. Same pattern as
            // `-uiPreviewChatOpen` in UIPreviewRoot.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-uiPreviewScrolled"),
                      let last = feed.displayedStreams.last else { return }
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(last.userId, anchor: .bottom)
            }
            #endif
        }
    }

    /// Leading streams that get the full-width card treatment.
    private static let featuredCount = 2

    // MARK: - Categories

    /// What one body pass shows, derived from `liveStreams` and the chip
    /// selection.
    private struct LiveFeed {
        /// Categories with at least one live followed channel, busiest
        /// (total viewers) first. Chips only appear when there are two or
        /// more — one chip would filter nothing.
        let categories: [String]
        /// The selection, ignored once its category has nobody live.
        let activeCategory: String?
        /// Every live followed channel (in the selected category). No
        /// preview cap + "See all": the feed is the full list.
        let displayedStreams: [TwitchStream]
    }

    private var liveFeed: LiveFeed {
        var totals: [String: Int] = [:]
        for stream in liveStreams where !stream.gameName.isEmpty {
            totals[stream.gameName, default: 0] += stream.viewerCount
        }
        let categories = totals.count >= 2
            ? totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            : []
        var activeCategory: String?
        if let selectedCategory, categories.contains(selectedCategory) {
            activeCategory = selectedCategory
        }
        var displayedStreams = liveStreams
        if let activeCategory {
            displayedStreams = liveStreams.filter { $0.gameName == activeCategory }
        }
        return LiveFeed(
            categories: categories,
            activeCategory: activeCategory,
            displayedStreams: displayedStreams
        )
    }

    // MARK: - Live now

    @ViewBuilder
    private func liveSection(_ feed: LiveFeed) -> some View {
        Section {
            // A regular row, not a Section header — plain-list headers pin
            // to the top as a translucent bar that never goes away.
            liveHeaderRow(feed)
            if liveStreams.isEmpty {
                liveEmptyContent
            } else {
                if !feed.categories.isEmpty {
                    categoryChips(feed)
                }
                ForEach(Array(feed.displayedStreams.enumerated()), id: \.element.userId) { index, stream in
                    Button {
                        onStreamTap(stream, .implicit)
                    } label: {
                        if index < Self.featuredCount {
                            LiveStreamCard(
                                stream: stream,
                                profileImageURL: profileImageURLs[stream.userId]
                            )
                        } else {
                            LiveStreamRow(
                                stream: stream,
                                profileImageURL: profileImageURLs[stream.userId]
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .channelPreviewMenu(
                        name: stream.userName,
                        profileImageURL: profileImageURLs[stream.userId],
                        stream: stream,
                        open: { intent in onStreamTap(stream, intent) }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(index < Self.featuredCount ? .hidden : .automatic)
                }
            }
        }
    }

    private func liveHeaderRow(_ feed: LiveFeed) -> some View {
        HStack(alignment: .firstTextBaseline) {
            sectionHeader("Live now")
            Spacer()
            // How many are live. The whole list is right here, so a
            // count replaces the old "See all" link.
            if !liveStreams.isEmpty {
                Text(feed.displayedStreams.count == liveStreams.count
                     ? "\(liveStreams.count) live"
                     : "\(feed.displayedStreams.count) of \(liveStreams.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textCase(nil)
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// All / per-category filter chips (Twitch Home's "All · Just Chatting
    /// · IRL" row), scoped to the Live now preview.
    private func categoryChips(_ feed: LiveFeed) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", isSelected: feed.activeCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(feed.categories, id: \.self) { category in
                    chip(category, isSelected: feed.activeCategory == category) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .background(
                    isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary.opacity(0.15)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Inline placeholder for the Live section's loading / quiet / failed
    /// states. Compact rows (not full-screen `ContentUnavailableView`) —
    /// Home still has the chats + follows sections below doing useful work.
    @ViewBuilder
    private var liveEmptyContent: some View {
        Group {
            switch liveLoadState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking who's live…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            case .loaded:
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                    Text("Nobody you follow is live right now.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text("Couldn't load live channels. Pull to retry.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: - Shared

    /// Plain-List section headers default to uppercased caption text;
    /// this keeps them sentence-case and slightly larger, matching the
    /// inlineLarge title's tone.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}
