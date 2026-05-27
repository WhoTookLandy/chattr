import SwiftUI
import Accounts
import TwitchKit
import Core
import DesignSystem
import os

private let logger = AppLogger.make("Features.ChannelList")

/// Top-level Follows tab content.
///
/// Two segmented views:
///   - **Live** (default): currently-streaming channels, refetched per visit
///     and on pull-to-refresh. Backed by `FollowsStore.liveStreamsOrdered`.
///   - **All**: full follow list (live + offline), cached once per account.
///     Backed by `FollowsStore.channels` + `liveStreams` (dict) for badges.
///
/// The two views share `searchText` so typing on Live and switching to All
/// keeps the filter. The selected view is persisted via `@AppStorage` so it
/// survives navigation away and back.
public struct ChannelListScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    @Environment(\.followsStore) private var followsStore
    @Environment(\.openChannel) private var openChannel

    @State private var showingSignOutConfirm = false
    @State private var searchText: String = ""
    @State private var errorMessage: String?

    @AppStorage("followsViewMode") private var rawViewMode: String = ViewMode.live.rawValue

    enum ViewMode: String, CaseIterable {
        case live, all

        var displayName: String {
            switch self {
            case .live: return "Live"
            case .all:  return "All"
            }
        }
    }

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    // MARK: - Convenience accessors

    private var channels: [FollowedChannel] { followsStore?.channels ?? [] }
    private var liveStreamsDict: [String: TwitchStream] { followsStore?.liveStreams ?? [:] }
    private var liveStreamsOrdered: [TwitchStream] { followsStore?.liveStreamsOrdered ?? [] }
    private var userProfiles: [String: TwitchUser] { followsStore?.userProfiles ?? [:] }
    private var allLoadState: FollowsStore.LoadState { followsStore?.allLoadState ?? .idle }
    private var liveLoadState: FollowsStore.LoadState { followsStore?.liveLoadState ?? .idle }
    private var allLoadProgress: Int { followsStore?.allLoadProgress ?? 0 }
    private var totalFollowed: Int? { followsStore?.totalFollowed }
    private var allErrorMessage: String? { followsStore?.allErrorMessage }
    private var liveErrorMessage: String? { followsStore?.liveErrorMessage }

    private var selectedMode: ViewMode {
        ViewMode(rawValue: rawViewMode) ?? .live
    }

    // MARK: - Sorting + filtering

    /// All channels sorted live-first (descending by viewer count), with
    /// offline channels in their original recently-followed order.
    private var sortedAllChannels: [FollowedChannel] {
        let indexed = channels.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let lViewers = liveStreamsDict[lhs.1.broadcasterId]?.viewerCount
            let rViewers = liveStreamsDict[rhs.1.broadcasterId]?.viewerCount
            switch (lViewers, rViewers) {
            case let (l?, r?): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.0 < rhs.0
            }
        }
        return sorted.map { $0.1 }
    }

    private var filteredAllChannels: [FollowedChannel] {
        guard !searchText.isEmpty else { return sortedAllChannels }
        let query = searchText.lowercased()
        return sortedAllChannels.filter { channel in
            channel.broadcasterName.lowercased().contains(query)
                || channel.broadcasterLogin.lowercased().contains(query)
        }
    }

    /// Live channels filtered by search. `/streams/followed` already returns
    /// them in descending viewer-count order, so no extra sort needed.
    private var filteredLiveStreams: [TwitchStream] {
        guard !searchText.isEmpty else { return liveStreamsOrdered }
        let query = searchText.lowercased()
        return liveStreamsOrdered.filter { stream in
            stream.userName.lowercased().contains(query)
                || stream.userLogin.lowercased().contains(query)
                || stream.gameName.lowercased().contains(query)
        }
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Segmented picker pinned above whichever list is showing. Hidden
            // inside the body's VStack rather than as a toolbar item so it
            // stays visible while the list scrolls.
            Picker("View", selection: Binding(
                get: { selectedMode },
                set: { rawViewMode = $0.rawValue }
            )) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                switch selectedMode {
                case .live: liveSegment
                case .all:  allSegment
                }
            }
        }
        .navigationTitle("\(account.displayName)'s Follows")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SettingsScreen(account: account, accountStore: accountStore)
                } label: {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Settings")
                }
            }
        }
        .confirmationDialog(
            "Sign out of @\(account.login)?",
            isPresented: $showingSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to authorize chattr with Twitch again to use this account.")
        }
        // Search applies to whichever view is showing — the filter logic is
        // mode-aware inside `filteredAllChannels` / `filteredLiveStreams`.
        .searchable(text: $searchText, prompt: searchPrompt)
        // Pull-to-refresh routes to the right refresher.
        .refreshable {
            guard let store = followsStore else { return }
            switch selectedMode {
            case .live:
                await store.refreshLive(account: account, accountStore: accountStore)
            case .all:
                await store.refreshAll(account: account, accountStore: accountStore)
            }
        }
        // Refresh live data whenever the user visits the Follows tab. The
        // initial load is triggered by RootView's .task on sign-in; this
        // .task fires on every appear (including tab switches), giving us
        // fresh live data without manual pull-to-refresh.
        .task {
            guard let store = followsStore else { return }
            await store.refreshLive(account: account, accountStore: accountStore)
        }
    }

    /// Mode-specific search placeholder.
    private var searchPrompt: String {
        switch selectedMode {
        case .live: return "Search live channels"
        case .all:  return "Search all channels"
        }
    }

    // MARK: - Live segment

    @ViewBuilder
    private var liveSegment: some View {
        let filtered = filteredLiveStreams
        if liveStreamsOrdered.isEmpty {
            switch liveLoadState {
            case .idle, .loading:
                ProgressView("Loading live channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ContentUnavailableView(
                    "Nobody's live",
                    systemImage: "wifi.slash",
                    description: Text("None of your followed channels are streaming right now. Switch to All to see your full list.")
                )
            case .failed:
                liveFailedView
            }
        } else if filtered.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(filtered, id: \.userId) { stream in
                    Button {
                        let profileURL = userProfiles[stream.userId]
                            .flatMap { URL(string: $0.profileImageUrl) }
                        openChannel?(stream: stream, profileImageURL: profileURL)
                    } label: {
                        ChannelRow(
                            stream: stream,
                            profileImageURL: userProfiles[stream.userId]
                                .flatMap { URL(string: $0.profileImageUrl) }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var liveFailedView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load live channels",
                systemImage: "exclamationmark.triangle",
                description: Text(liveErrorMessage ?? "Unknown error")
            )
            Button("Retry") {
                guard let store = followsStore else { return }
                Task { await store.refreshLive(account: account, accountStore: accountStore) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - All segment

    @ViewBuilder
    private var allSegment: some View {
        if channels.isEmpty {
            switch allLoadState {
            case .idle, .loading:
                initialAllLoadingView
            case .loaded:
                emptyFollowsView
            case .failed:
                allFailedView
            }
        } else {
            allLoadedListView
        }
    }

    @ViewBuilder
    private var initialAllLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            if allLoadProgress > 0 {
                allProgressText
            } else {
                Text("Loading channels…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyFollowsView: some View {
        ContentUnavailableView(
            "No followed channels",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("Follow channels on twitch.tv and they'll appear here.")
        )
    }

    @ViewBuilder
    private var allFailedView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load channels",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage ?? allErrorMessage ?? "Unknown error")
            )
            Button("Sign out and try again") {
                showingSignOutConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var allLoadedListView: some View {
        let filtered = filteredAllChannels
        if filtered.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(filtered) { channel in
                    Button {
                        let profileURL = userProfiles[channel.broadcasterId]
                            .flatMap { URL(string: $0.profileImageUrl) }
                        openChannel?(channel: channel, profileImageURL: profileURL)
                    } label: {
                        ChannelRow(
                            channel: channel,
                            stream: liveStreamsDict[channel.broadcasterId],
                            profileImageURL: userProfiles[channel.broadcasterId]
                                .flatMap { URL(string: $0.profileImageUrl) }
                        )
                    }
                    .buttonStyle(.plain)
                }
                allLoadingMoreFooter
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var allLoadingMoreFooter: some View {
        switch allLoadState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.75)
                allProgressText
                Spacer()
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't load remaining channels")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    guard let store = followsStore else { return }
                    Task { await store.refreshAll(account: account, accountStore: accountStore) }
                }
                .font(.footnote)
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        case .idle, .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var allProgressText: some View {
        if let total = totalFollowed, total > 0 {
            Text("Loading channels — \(allLoadProgress) of \(total)")
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentTransition(.numericText())
        } else {
            Text("Loading channels — \(allLoadProgress) so far")
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Actions

    @MainActor
    private func signOut() async {
        do {
            try await accountStore.remove(account: account)
            logger.info("Signed out @\(account.login)")
        } catch {
            logger.error("Sign out had an error: \(error.localizedDescription)")
            errorMessage = "Sign out: \(error.localizedDescription)"
        }
    }
}

// MARK: - Identifiable conformance

/// Retroactive `Identifiable` conformance for use in `ForEach` over
/// `[FollowedChannel]`. The All view uses this; the Live view uses an
/// explicit `id: \.userId` keyPath because TwitchStream isn't Identifiable
/// out of the box and we don't need that conformance at the top level.
extension FollowedChannel: @retroactive Identifiable {
    public var id: String { broadcasterId }
}
