import SwiftUI
import Accounts
import TwitchKit
import Core
import DesignSystem
import os

private let logger = AppLogger.make("Features.ChannelList")

/// Displays the signed-in user's followed channels.
/// Tapping a row pushes a `ChatScreen` for that channel.
///
/// State lives in `FollowsStore` (owned by `RootView`), not in this view. That
/// keeps the loaded list alive across navigation — popping back from a chat
/// no longer triggers a refetch. Pull-to-refresh and the failed-state retry
/// both call `store.refresh()` for an explicit reload.
public struct ChannelListScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    /// Injected by RootView. The actual data + load logic lives here so it
    /// survives back-navigation from chat screens.
    @Environment(\.followsStore) private var followsStore

    /// Injected by AppShell. Invoked when the user taps a row — adds the
    /// channel to the Chat tab and switches the tab selection to Chat.
    @Environment(\.openChannel) private var openChannel

    @State private var showingSignOutConfirm = false
    @State private var searchText: String = ""
    @State private var errorMessage: String?

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    // MARK: - Convenience accessors

    /// Empty when the store hasn't been injected (e.g. SwiftUI previews) — falls
    /// back to the "loading" placeholder rather than crashing.
    private var channels: [FollowedChannel] { followsStore?.channels ?? [] }
    private var liveStreams: [String: TwitchStream] { followsStore?.liveStreams ?? [:] }
    private var userProfiles: [String: TwitchUser] { followsStore?.userProfiles ?? [:] }
    private var loadState: FollowsStore.LoadState { followsStore?.loadState ?? .idle }
    private var loadProgress: Int { followsStore?.loadProgress ?? 0 }
    private var totalFollowed: Int? { followsStore?.totalFollowed }
    /// Combined: store's load error OR our local sign-out error.
    private var visibleError: String? { errorMessage ?? followsStore?.errorMessage }

    /// Channels sorted for display: live channels first (descending by viewer
    /// count), then offline channels in their original follow-list order
    /// (Twitch returns most-recently-followed first).
    ///
    /// We sort `(index, channel)` tuples and use the index as the tie-breaker
    /// for the offline-vs-offline case — Swift's `sorted(by:)` is not
    /// guaranteed stable, so we force stability explicitly.
    private var displayChannels: [FollowedChannel] {
        let indexed = channels.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let lViewers = liveStreams[lhs.1.broadcasterId]?.viewerCount
            let rViewers = liveStreams[rhs.1.broadcasterId]?.viewerCount
            switch (lViewers, rViewers) {
            case let (l?, r?): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.0 < rhs.0
            }
        }
        return sorted.map { $0.1 }
    }

    /// `displayChannels` filtered by the current search text, case-insensitive
    /// against both display name and login. Empty `searchText` returns the
    /// full sorted list.
    private var filteredChannels: [FollowedChannel] {
        let sorted = displayChannels
        guard !searchText.isEmpty else { return sorted }
        let query = searchText.lowercased()
        return sorted.filter { channel in
            channel.broadcasterName.lowercased().contains(query)
                || channel.broadcasterLogin.lowercased().contains(query)
        }
    }

    public var body: some View {
        Group {
            if channels.isEmpty {
                switch loadState {
                case .idle, .loading:
                    initialLoadingView
                case .loaded:
                    emptyFollowsView
                case .failed:
                    failedView
                }
            } else {
                loadedListView
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
        // failedView's "Sign out and try again" button triggers this dialog —
        // keep the recovery path available even when settings is unreachable.
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
        // Pull-to-refresh explicitly forces a reload regardless of cache state.
        .refreshable {
            guard let store = followsStore else { return }
            await store.refresh(account: account, accountStore: accountStore)
        }
        // NOTE: No `.task` here. The initial load is triggered by RootView's
        // `.task(id: account.userId)` which calls `store.loadIfNeeded(...)` once
        // on first sign-in. Avoiding `.task` here is the whole point — it would
        // re-fire on every back-nav.
    }

    // MARK: - Subviews

    /// First-load state — no channels arrived yet. Shows a spinner with an
    /// optional progressive count if `loadProgress` is non-zero.
    @ViewBuilder
    private var initialLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            if loadProgress > 0 {
                progressText
            } else {
                Text("Loading channels…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "No followed channels" state — distinct from loading.
    @ViewBuilder
    private var emptyFollowsView: some View {
        ContentUnavailableView(
            "No followed channels",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("Follow channels on twitch.tv and they'll appear here.")
        )
    }

    /// Initial-load failure with no partial data — surface the sign-out path.
    @ViewBuilder
    private var failedView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load channels",
                systemImage: "exclamationmark.triangle",
                description: Text(visibleError ?? "Unknown error")
            )
            Button("Sign out and try again") {
                showingSignOutConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 32)
        }
    }

    /// The list of channels (filtered + tappable). Includes a footer row when
    /// pagination is still in flight or has failed mid-load.
    @ViewBuilder
    private var loadedListView: some View {
        let filtered = filteredChannels
        Group {
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
                                stream: liveStreams[channel.broadcasterId],
                                profileImageURL: userProfiles[channel.broadcasterId]
                                    .flatMap { URL(string: $0.profileImageUrl) }
                            )
                        }
                        // .plain so the row doesn't get the system Button blue tint
                        // — it should still look like a list row, but tap-to-open.
                        .buttonStyle(.plain)
                    }
                    loadingMoreFooter
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search channels")
    }

    /// Footer row shown at the bottom of the list while pagination is still in
    /// flight or if it failed mid-load. Hidden once loadState is .loaded.
    @ViewBuilder
    private var loadingMoreFooter: some View {
        switch loadState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.75)
                progressText
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
                    Task { await store.refresh(account: account, accountStore: accountStore) }
                }
                .font(.footnote)
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        case .idle, .loaded:
            EmptyView()
        }
    }

    /// Reusable progress label — shows total when known, otherwise a "so far" count.
    @ViewBuilder
    private var progressText: some View {
        if let total = totalFollowed, total > 0 {
            Text("Loading channels — \(loadProgress) of \(total)")
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentTransition(.numericText())
        } else {
            Text("Loading channels — \(loadProgress) so far")
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Actions

    /// Removes the current account. RootView's `@Query` observes the SwiftData delete and
    /// re-renders to SignInView automatically — no manual navigation needed.
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

/// Retroactive `Identifiable` conformance for use in `ForEach`. Twitch's
/// broadcasterId is the natural stable identity for a followed channel.
extension FollowedChannel: @retroactive Identifiable {
    public var id: String { broadcasterId }
}

