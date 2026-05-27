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
                ContentUnavailableView(
                    "Couldn't load channels",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "Unknown error")
                )
            }
        }
        .navigationTitle("\(account.displayName)'s Follows")
        .task { await load() }
        .refreshable { await load() }
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
