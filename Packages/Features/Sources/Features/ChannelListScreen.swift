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
    @State private var loadState: LoadState = .idle
    @State private var loadProgress: Int = 0
    @State private var totalFollowed: Int?
    @State private var errorMessage: String?
    @State private var isSigningOut = false
    @State private var showingSignOutConfirm = false
    @State private var searchText: String = ""

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    /// Channels filtered by the current search text, case-insensitive against both
    /// display name and login. Empty `searchText` returns all loaded channels.
    private var filteredChannels: [FollowedChannel] {
        guard !searchText.isEmpty else { return channels }
        let query = searchText.lowercased()
        return channels.filter { channel in
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
                Menu {
                    Button(role: .destructive) {
                        showingSignOutConfirm = true
                    } label: {
                        Label("Sign out @\(account.login)", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .disabled(isSigningOut)
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
                            HStack {
                                Text(channel.broadcasterName)
                                    .font(.headline)
                                Spacer()
                                Text("@\(channel.broadcasterLogin)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
        isSigningOut = true
        defer { isSigningOut = false }
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
    @MainActor
    private func load() async {
        loadState = .loading
        loadProgress = 0
        totalFollowed = nil
        errorMessage = nil
        channels = []  // reset on full reload (refreshable)

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

                // KEY DIFFERENCE FROM PREVIOUS VERSION: append to `channels`
                // immediately so the view sees the new rows. SwiftUI's diffable
                // List handles the inserts smoothly.
                channels.append(contentsOf: page.data)
                loadProgress = channels.count

                if totalFollowed == nil, let total = page.total {
                    totalFollowed = total
                }
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
}

extension FollowedChannel: @retroactive Identifiable {
    public var id: String { broadcasterId }
}
