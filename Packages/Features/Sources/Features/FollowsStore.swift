import Foundation
import SwiftUI
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.FollowsStore")

/// App-level cache of the active account's followed channels + their enrichment
/// data (live streams, profile images).
///
/// Why this exists: before this store, all follow-list state lived in
/// `ChannelListScreen`'s `@State`. SwiftUI's `.task` modifier re-fires every
/// time a view re-appears, and `load()` resets state at the start — so every
/// pop-back from a chat triggered a full refetch (pagination + per-page
/// live-streams + per-page user-profile batches). That's a lot of wasted
/// requests for what should be a stable list.
///
/// This store hoists the state up to `RootView`, which owns it as `@State`
/// and triggers a single load via `.task(id: account.userId)` on first sign-in
/// (or account swap). Subsequent ChannelListScreen mounts read from the store
/// without re-fetching. Pull-to-refresh calls `refresh()` for an explicit reload.
@MainActor
@Observable
public final class FollowsStore {

    public enum LoadState: Equatable, Sendable {
        case idle, loading, loaded, failed
    }

    // MARK: - Observable state

    public private(set) var channels: [FollowedChannel] = []
    public private(set) var liveStreams: [String: TwitchStream] = [:]
    public private(set) var userProfiles: [String: TwitchUser] = [:]
    public private(set) var loadState: LoadState = .idle
    public private(set) var loadProgress: Int = 0
    public private(set) var totalFollowed: Int?
    public private(set) var errorMessage: String?

    // MARK: - Internal bookkeeping

    /// Which account's data we currently hold. Reset on account-change so the
    /// next load() repopulates with the new account's follows.
    private var loadedForUserId: String?

    public init() {}

    // MARK: - Public API

    /// Loads only when the data we hold isn't for the requested account.
    /// Safe to call from `.task(id:)` which re-fires on account swap.
    public func loadIfNeeded(account: Account, accountStore: AccountStore) async {
        guard loadedForUserId != account.userId else { return }
        await load(account: account, accountStore: accountStore)
    }

    /// Force-reload — drops all state and re-fetches. Drives pull-to-refresh.
    public func refresh(account: Account, accountStore: AccountStore) async {
        await load(account: account, accountStore: accountStore)
    }

    /// Removes a channel from the local list. Used by the future "unfollow"
    /// affordance or by external state syncing — not currently called but
    /// reserved for the tab-bar `close X` flow if we ever want close to also
    /// un-follow. (Currently close just stops the EventSub session.)
    public func dropChannel(broadcasterId: String) {
        channels.removeAll { $0.broadcasterId == broadcasterId }
        liveStreams[broadcasterId] = nil
        userProfiles[broadcasterId] = nil
    }

    // MARK: - Load implementation (lifted from ChannelListScreen)

    /// Paginates Helix until pagination.cursor is nil. Appends after each page
    /// so the UI sees rows progressively. Enrichment (live streams + profile
    /// images) fires after the first page lands — keeps the token-refresh
    /// path serial through page 1.
    private func load(account: Account, accountStore: AccountStore) async {
        loadState = .loading
        loadProgress = 0
        totalFollowed = nil
        errorMessage = nil
        channels = []
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

                channels.append(contentsOf: page.data)
                loadProgress = channels.count

                if totalFollowed == nil, let total = page.total {
                    totalFollowed = total
                }

                let pageIds = page.data.map(\.broadcasterId)
                if pagesFetched == 1 {
                    Task { await self.loadLiveStreams(account: account, accountStore: accountStore) }
                }
                Task { await self.enrichProfiles(ids: pageIds, account: account, accountStore: accountStore) }

                cursor = page.pagination?.cursor

                if pagesFetched >= pageCap {
                    logger.warning("Hit pagination safety cap (\(pageCap) pages) — stopping")
                    break
                }
            } while cursor != nil

            loadState = .loaded
            loadedForUserId = account.userId
            logger.info("Loaded \(self.channels.count) followed channels across \(pagesFetched) page(s)")
        } catch {
            errorMessage = "\(error)"
            loadState = .failed
            logger.error("Failed to load followed channels: \(error.localizedDescription)")
        }
    }

    private func loadLiveStreams(account: Account, accountStore: AccountStore) async {
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

            logger.info("Loaded \(self.liveStreams.count) live followed channel(s) across \(pagesFetched) page(s)")
        } catch {
            logger.error("Failed to load live followed channels: \(error.localizedDescription)")
        }
    }

    private func enrichProfiles(ids: [String], account: Account, accountStore: AccountStore) async {
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
            logger.error("Failed to load profile images for \(missing.count) channels: \(error.localizedDescription)")
        }
    }
}

// MARK: - Environment plumbing

private struct FollowsStoreKey: EnvironmentKey {
    /// nil default for the same MainActor-isolation reason as GlobalCatalog —
    /// constructing `@MainActor` instances in a nonisolated context trips Swift 6.
    static let defaultValue: FollowsStore? = nil
}

public extension EnvironmentValues {
    var followsStore: FollowsStore? {
        get { self[FollowsStoreKey.self] }
        set { self[FollowsStoreKey.self] = newValue }
    }
}
