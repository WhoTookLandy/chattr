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
/// Pagination behaviour: rather than blocking on the full follow-list before
/// showing anything, this screen renders the list as soon as the first page
/// arrives and appends more rows as additional pages stream in. While
/// pagination continues, a "loading more" footer cell stays at the bottom of
/// the list with a live count. Users can interact with already-loaded
/// channels (tap to open chat, search to filter) while loading completes in
/// the background.
public struct ChannelListScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    @State private var channels: [FollowedChannel] = []
    /// Live streams among `channels`, keyed by broadcasterId. Populated from a
    /// parallel `/streams/followed` pagination — empty for offline channels.
    @State private var liveStreams: [String: TwitchStream] = [:]
    /// Cached profile metadata (image URL etc) keyed by broadcasterId. Populated
    /// per-page via batched `fetchUsers(ids:)`. Missing entries render placeholder.
    @State private var userProfiles: [String: TwitchUser] = [:]
    @State private var loadState: LoadState = .idle
    @State private var loadProgress: Int = 0
    @State private var totalFollowed: Int?
    @State private var errorMessage: String?
    @State private var showingSignOutConfirm = false
    @State private var searchText: String = ""

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

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
                // No rows yet — show the initial placeholder for whichever
                // state we're in.
                switch loadState {
                case .idle, .loading:
                    initialLoadingView
                case .loaded:
                    emptyFollowsView
                case .failed:
                    failedView
                }
            } else {
                // We have at least one channel — show the list. If pagination
                // is still in flight, the list footer carries a "loading more"
                // row; if pagination failed mid-stream, the footer becomes a
                // small error indicator.
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
        // failedView's "Sign out and try again" button still triggers this dialog —
        // we keep it here so that recovery path works even when the user can't
        // reach Settings (e.g. initial-load failure with no channels).
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
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Subviews

    /// First-load state — no channels arrived yet. Shows a spinner with an
    /// optional progressive count if `loadProgress` is non-zero (we capture
    /// `total` from the first page response when Twitch includes it).
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

    /// Initial-load failure with no partial data — the user is stuck. Surface
    /// the "Sign out and try again" recovery path here too.
    @ViewBuilder
    private var failedView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load channels",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage ?? "Unknown error")
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
                // We have channels but the current search matches none of them.
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filtered) { channel in
                        NavigationLink {
                            ChatScreen(
                                account: account,
                                accountStore: accountStore,
                                channelId: channel.broadcasterId,
                                channelLoginName: channel.broadcasterLogin,
                                channelDisplayName: channel.broadcasterName
                            )
                        } label: {
                            ChannelRow(
                                channel: channel,
                                stream: liveStreams[channel.broadcasterId],
                                profileImageURL: userProfiles[channel.broadcasterId]
                                    .flatMap { URL(string: $0.profileImageUrl) }
                            )
                        }
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
            // Partial load — show what we have plus a "couldn't load remaining" notice.
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't load remaining channels")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    Task { await load() }
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

    /// Loads ALL of the user's followed channels by paginating Helix until
    /// `pagination.cursor` is nil. Updates `channels` AFTER EACH PAGE so the
    /// SwiftUI view sees rows appear progressively rather than waiting for the
    /// whole load to complete. Safety cap of 200 pages protects against stuck
    /// cursors.
    ///
    /// Enrichment (live status + profile images) runs in parallel:
    ///   - `loadLiveStreams()` paginates `/streams/followed` to mark live rows
    ///   - `enrichProfiles(ids:)` batches `fetchUsers(ids:)` per follow page
    ///
    /// Both are kicked off AFTER the first follow page lands so any token
    /// refresh triggered by a 401 happens serially through the first call —
    /// avoids two parallel refreshes racing to consume the same refresh_token.
    @MainActor
    private func load() async {
        loadState = .loading
        loadProgress = 0
        totalFollowed = nil
        errorMessage = nil
        channels = []  // reset on full reload (refreshable)
        liveStreams = [:]
        userProfiles = [:]

        do {
            let client = accountStore.client(for: account)
            let userId = account.userId

            var cursor: String? = nil
            let pageCap = 200
            var pagesFetched = 0

            repeat {
                let cursorForRequest = cursor
                let page = try await accountStore.withTokenRefresh(for: account) {
                    try await client.api.fetchFollowedChannelsPage(
                        forUserID: userId,
                        broadcasterID: nil,
                        first: 100,
                        after: cursorForRequest
                    )
                }
                pagesFetched += 1

                // Append to `channels` immediately so the view sees new rows.
                // SwiftUI's diffable List handles the inserts smoothly.
                channels.append(contentsOf: page.data)
                loadProgress = channels.count

                if totalFollowed == nil, let total = page.total {
                    totalFollowed = total
                }

                // Kick off enrichment for this page. Fire `loadLiveStreams` only
                // on the first page so subsequent pages don't restart it.
                let pageIds = page.data.map(\.broadcasterId)
                if pagesFetched == 1 {
                    Task { await loadLiveStreams() }
                }
                Task { await enrichProfiles(ids: pageIds) }

                cursor = page.pagination?.cursor

                if pagesFetched >= pageCap {
                    logger.warning("Hit pagination safety cap (\(pageCap) pages) — stopping")
                    break
                }
            } while cursor != nil

            loadState = .loaded
            logger.info("Loaded \(channels.count) followed channels across \(pagesFetched) page(s)")
        } catch {
            errorMessage = "\(error)"
            // If we have ANY channels already, transition to .failed (the list
            // stays visible with an error footer). If we have none, the
            // failedView covers the screen.
            loadState = .failed
            logger.error("Failed to load followed channels: \(error.localizedDescription)")
        }
    }

    /// Paginates `/streams/followed` to build a map of currently-live channels.
    /// Each page is up to 100 streams. The endpoint returns ONLY live channels
    /// among the user's follows — typically a small set (the user follows a lot
    /// of people but most are offline at any moment), so this completes in 1–2
    /// requests for normal accounts. Errors are non-fatal: the channel list
    /// still renders, just with every row appearing offline.
    @MainActor
    private func loadLiveStreams() async {
        do {
            let client = accountStore.client(for: account)
            let userId = account.userId
            var cursor: String? = nil
            var pagesFetched = 0

            repeat {
                let cursorForRequest = cursor
                let page = try await accountStore.withTokenRefresh(for: account) {
                    try await client.api.fetchFollowedStreamsPage(
                        userID: userId,
                        first: 100,
                        after: cursorForRequest
                    )
                }
                pagesFetched += 1
                for stream in page.data {
                    liveStreams[stream.userId] = stream
                }
                cursor = page.pagination?.cursor
                if pagesFetched >= 20 {
                    logger.warning("Hit live-streams pagination cap — stopping")
                    break
                }
            } while cursor != nil

            logger.info("Loaded \(liveStreams.count) live followed channel(s) across \(pagesFetched) page(s)")
        } catch {
            // Non-fatal — the list renders fine, just without LIVE badges.
            logger.error("Failed to load live followed channels: \(error.localizedDescription)")
        }
    }

    /// Batch-fetches user profiles for the given broadcaster IDs and stores
    /// them in `userProfiles`. Skips IDs already cached. Errors are non-fatal:
    /// rows without a profile entry fall back to the placeholder avatar.
    /// Helix `/users` accepts up to 100 IDs per request — we always feed pages
    /// of 100 from the follow-list paginator so one call covers a page.
    @MainActor
    private func enrichProfiles(ids: [String]) async {
        let missing = ids.filter { userProfiles[$0] == nil }
        guard !missing.isEmpty else { return }
        do {
            let client = accountStore.client(for: account)
            let users = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchUsers(ids: missing)
            }
            for user in users {
                userProfiles[user.id] = user
            }
        } catch {
            // Non-fatal — rows render with the placeholder avatar instead.
            logger.error("Failed to load profile images for \(missing.count) channels: \(error.localizedDescription)")
        }
    }
}

extension FollowedChannel: @retroactive Identifiable {
    public var id: String { broadcasterId }
}
