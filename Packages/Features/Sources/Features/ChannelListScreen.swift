import SwiftUI
import Accounts
import TwitchKit
import Core
import DesignSystem
import os

private let logger = AppLogger.make("Features.ChannelList")

/// Displays the signed-in user's followed channels.
/// Tapping a row pushes a `ChatScreen` for that channel.
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
            switch loadState {
            case .idle, .loading:
                loadingView
            case .loaded where channels.isEmpty:
                ContentUnavailableView(
                    "No followed channels",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Follow channels on twitch.tv and they'll appear here.")
                )
            case .loaded:
                loadedListView
            case .failed:
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

    /// Loading state. Shows a progressive count once any channels arrive — many
    /// power users follow 500+ channels, so a static spinner with no feedback
    /// can feel like the app is stuck. We update `loadProgress` after each page.
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            if loadProgress > 0 {
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
            } else {
                Text("Loading channels…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Filtered list of followed channels.
    @ViewBuilder
    private var loadedListView: some View {
        let filtered = filteredChannels
        if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List(filtered) { channel in
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
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search channels")
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
            // Even if logout HTTP fails, we want to recover — fall back to local deletion.
            logger.error("Sign out had an error: \(error.localizedDescription)")
            errorMessage = "Sign out: \(error.localizedDescription)"
        }
    }

    /// Loads ALL of the user's followed channels by paginating Helix until the
    /// `pagination.cursor` is nil. Updates `loadProgress` between pages so the
    /// loading state can show a live counter. Most users follow under a few
    /// hundred channels; power users can follow 1000+ which is ~10–11 pages
    /// at Twitch's 100-per-page max.
    @MainActor
    private func load() async {
        loadState = .loading
        loadProgress = 0
        totalFollowed = nil
        errorMessage = nil
        do {
            let client = accountStore.client(for: account)
            // Capture stable Sendable values for the closure — `Account` isn't Sendable.
            let userId = account.userId

            var collected: [FollowedChannel] = []
            var cursor: String? = nil
            // Safety cap: refuse to follow more than 200 pages = 20,000 channels.
            // Catches infinite-loop bugs in Twitch's cursor pagination (very rare but
            // we'd rather throw than hang the UI forever).
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
                collected.append(contentsOf: page.data)
                pagesFetched += 1

                // Twitch only includes `total` on the first page response. Capture it then.
                if totalFollowed == nil, let total = page.total {
                    totalFollowed = total
                }
                loadProgress = collected.count
                cursor = page.pagination?.cursor

                if pagesFetched >= pageCap {
                    logger.warning("Hit pagination safety cap (\(pageCap) pages) — stopping")
                    break
                }
            } while cursor != nil

            channels = collected
            loadState = .loaded
            logger.info("Loaded \(channels.count) followed channels across \(pagesFetched) page(s)")
        } catch {
            errorMessage = "\(error)"
            loadState = .failed
            logger.error("Failed to load followed channels: \(error.localizedDescription)")
        }
    }
}

extension FollowedChannel: @retroactive Identifiable {
    public var id: String { broadcasterId }
}
