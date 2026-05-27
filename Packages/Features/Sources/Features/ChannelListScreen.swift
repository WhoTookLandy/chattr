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
    @State private var errorMessage: String?
    @State private var isSigningOut = false
    @State private var showingSignOutConfirm = false

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    public var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where channels.isEmpty:
                ContentUnavailableView(
                    "No followed channels",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Follow channels on twitch.tv and they'll appear here.")
                )
            case .loaded:
                List(channels) { channel in
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
            // `.primaryAction` is the cross-platform placement that renders top-trailing
            // on iOS and the appropriate toolbar slot on macOS. `.topBarTrailing` is iOS-only.
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

    @MainActor
    private func load() async {
        loadState = .loading
        errorMessage = nil
        do {
            let client = accountStore.client(for: account)
            // Capture the userId string before entering the @Sendable closure to avoid
            // capturing the non-Sendable Account model object across the boundary.
            let userId = account.userId
            // Actual TwitchKit signature: forUserID:first:after: (cursor label)
            let page = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchFollowedChannelsPage(
                    forUserID: userId,
                    first: 100,
                    after: nil
                )
            }
            channels = page.data
            loadState = .loaded
            logger.info("Loaded \(channels.count) followed channels")
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
