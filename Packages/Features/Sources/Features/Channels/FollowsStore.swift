import Foundation
import SwiftUI
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.FollowsStore")

/// App-level cache of the active account's followed channels.
///
/// Owns two independent data sets sourced from two Helix endpoints:
///
///   - **Live** (`/streams/followed`): currently-live channels with rich
///     metadata (game, viewer count, title). Refetched on every Follows-tab
///     visit and on pull-to-refresh — live status changes minute-to-minute.
///     `liveStreamsOrdered` holds the array in Twitch's returned order
///     (descending viewer count); `liveStreams` is a (broadcasterId → stream)
///     dict used by the All view to overlay LIVE badges.
///
///   - **All** (`/channels/followed`): every followed channel (live + offline)
///     with only identity fields (id, login, name, followedAt). Loaded once
///     per account on first sign-in via `loadAllIfNeeded`, cached in-memory
///     for the rest of the session. Pull-to-refresh on the All view forces
///     a reload via `refreshAll`.
///
/// `userProfiles` (broadcasterId → TwitchUser) is shared between both views —
/// each refresh batches `fetchUsers(ids:)` for IDs not already cached.
///
/// Why this lives in a store (not in `ChannelListScreen.@State`): before this
/// existed, every pop-back from a chat triggered `.task` to re-fire and
/// `load()` to refetch from scratch. Hoisting to `RootView`-owned state means
/// the data survives view-tree churn and only refetches when actually wanted.
@MainActor
@Observable
public final class FollowsStore {

    public enum LoadState: Equatable, Sendable {
        case idle, loading, loaded, failed
    }

    // MARK: - "All" data set (full follow list, cached)

    public private(set) var channels: [FollowedChannel] = []
    public private(set) var userProfiles: [String: TwitchUser] = [:]
    public private(set) var allLoadState: LoadState = .idle
    public private(set) var allLoadProgress: Int = 0
    public private(set) var totalFollowed: Int?
    public private(set) var allErrorMessage: String?

    /// Memoized: `channels` sorted live-first (desc viewer count) with offline
    /// channels in their original recently-followed order. Recomputed only when
    /// `channels` or `liveStreams` actually change — moving this out of the
    /// View's computed property avoids re-sorting on every keystroke in search
    /// (the old code did O(n log n) per body recompute).
    ///
    /// Maintained by `recomputeSortedAllChannels()` which is called after every
    /// page commit in `loadAll` and after every live-pagination commit in
    /// `refreshLive`. Sort is stable: ties (same viewer count, or both offline)
    /// resolve by original-index position in `channels`.
    public private(set) var sortedAllChannels: [FollowedChannel] = []

    // MARK: - "Live" data set (foreground, refetched per visit)

    /// Live channels in Twitch's returned order (desc viewer count). Drives
    /// the Live segmented view.
    public private(set) var liveStreamsOrdered: [TwitchStream] = []

    /// Same data keyed by broadcasterId. Drives LIVE badges on the All view.
    public private(set) var liveStreams: [String: TwitchStream] = [:]

    public private(set) var liveLoadState: LoadState = .idle
    public private(set) var liveErrorMessage: String?

    // MARK: - Internal bookkeeping

    /// Which account's *All* data we currently hold. The cache hit/miss is
    /// driven entirely off this. Live data isn't cached this way — it's always
    /// considered stale and refetched on demand.
    private var loadedAllForUserId: String?

    /// In-flight enrichment Tasks (per-page profile batches + the inline
    /// loadAll pagination). Cancelled at the start of every load to prevent
    /// stale-account writes during a swap.
    private var enrichmentTasks: [Task<Void, Never>] = []

    public init() {}

    // MARK: - Public API: All

    /// Loads the full follow list only if we don't already have data for this
    /// account. Safe to call from `.task(id:)` which re-fires on account swap.
    public func loadAllIfNeeded(account: Account, accountStore: AccountStore) async {
        guard loadedAllForUserId != account.userId else { return }
        await loadAll(account: account, accountStore: accountStore)
    }

    /// Force-reload the All list (pull-to-refresh on the All view).
    public func refreshAll(account: Account, accountStore: AccountStore) async {
        await loadAll(account: account, accountStore: accountStore)
    }

    // MARK: - Public API: Live

    /// Reloads the Live list. Not cached — every call refetches. Drives
    /// `.task` on the Live view appearance + pull-to-refresh.
    public func refreshLive(account: Account, accountStore: AccountStore) async {
        liveLoadState = .loading
        liveErrorMessage = nil

        var fresh: [TwitchStream] = []
        var freshMap: [String: TwitchStream] = [:]

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

                fresh.append(contentsOf: page.data)
                for stream in page.data {
                    freshMap[stream.userId] = stream
                }
                // Commit progressively so the UI sees streams as pages arrive.
                liveStreamsOrdered = fresh
                liveStreams = freshMap
                // liveStreams changed — refresh the sort cache too so the
                // All view's live-first ordering reflects the new live set
                // as it arrives.
                recomputeSortedAllChannels()

                // Kick off profile enrichment for live channels not already cached.
                let liveIds = page.data.map(\.userId)
                let task = Task { await self.enrichProfiles(ids: liveIds, account: account, accountStore: accountStore) }
                enrichmentTasks.append(task)

                cursor = page.pagination?.cursor
                if pagesFetched >= 20 {
                    logger.warning("Hit live-streams pagination cap — stopping")
                    break
                }
            } while cursor != nil

            liveLoadState = .loaded
            logger.info("Loaded \(fresh.count) live followed channel(s) across \(pagesFetched) page(s)")
        } catch is CancellationError {
            // Cancelled (e.g. tab switch mid-load) — leave whatever we already
            // committed visible and exit silently.
            logger.info("Live-streams load cancelled")
        } catch {
            liveErrorMessage = "\(error)"
            liveLoadState = .failed
            logger.error("Failed to load live followed channels: \(error.localizedDescription)")
        }
    }

    // MARK: - Public API: misc

    /// Removes a channel from the local list. Used by the future "unfollow"
    /// affordance — not currently called but kept for parity.
    public func dropChannel(broadcasterId: String) {
        channels.removeAll { $0.broadcasterId == broadcasterId }
        liveStreams[broadcasterId] = nil
        liveStreamsOrdered.removeAll { $0.userId == broadcasterId }
        userProfiles[broadcasterId] = nil
        recomputeSortedAllChannels()
    }

    // MARK: - Sorted cache maintenance

    /// Recomputes `sortedAllChannels` from the current `channels` + `liveStreams`.
    /// Called from every data-mutation site (page commits in `loadAll` and
    /// `refreshLive`, plus `dropChannel`).
    ///
    /// We sort `(index, channel)` tuples and use the index as the tie-breaker
    /// for the offline-vs-offline case — Swift's `sorted(by:)` is not
    /// guaranteed stable, so we force stability explicitly.
    private func recomputeSortedAllChannels() {
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
        sortedAllChannels = sorted.map { $0.1 }
    }

    // MARK: - Load implementation: All

    /// Paginates `/channels/followed`, building the next channel list into a
    /// local array and committing per page so the UI sees rows progressively.
    /// Profile enrichment fires per page.
    ///
    /// State-reset policy:
    ///   - Account swap: wipe stale data immediately so the previous user's
    ///     follows don't briefly appear under the new user's name.
    ///   - Refresh (same account): keep existing data visible until new pages
    ///     arrive — pull-to-refresh's own spinner is the loading signal.
    ///
    /// CancellationError is treated as benign and leaves state intact (view
    /// tear-down / `.task(id:)` re-fire).
    private func loadAll(account: Account, accountStore: AccountStore) async {
        // Cancel any in-flight enrichment from previous loads.
        for task in enrichmentTasks { task.cancel() }
        enrichmentTasks = []

        let isAccountSwap = (loadedAllForUserId != nil && loadedAllForUserId != account.userId)

        allLoadState = .loading
        allLoadProgress = 0
        totalFollowed = nil
        allErrorMessage = nil

        if isAccountSwap {
            channels = []
            liveStreams = [:]
            liveStreamsOrdered = []
            userProfiles = [:]
            recomputeSortedAllChannels()
        }

        do {
            let client = accountStore.client(for: account)
            let userId = account.userId

            var accumulated: [FollowedChannel] = []
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

                accumulated.append(contentsOf: page.data)
                channels = accumulated
                allLoadProgress = accumulated.count
                // channels changed — refresh the sort cache. Per-page commit
                // means the All view sees rows appearing in correct sorted
                // order as pagination progresses.
                recomputeSortedAllChannels()

                if totalFollowed == nil, let total = page.total {
                    totalFollowed = total
                }

                // Enrich profile images for this page. We DON'T do live-stream
                // enrichment here anymore — refreshLive() handles that path.
                let pageIds = page.data.map(\.broadcasterId)
                let profileTask = Task { await self.enrichProfiles(ids: pageIds, account: account, accountStore: accountStore) }
                enrichmentTasks.append(profileTask)

                cursor = page.pagination?.cursor

                if pagesFetched >= pageCap {
                    logger.warning("Hit pagination safety cap (\(pageCap) pages) — stopping")
                    break
                }
            } while cursor != nil

            allLoadState = .loaded
            loadedAllForUserId = account.userId
            logger.info("Loaded \(self.channels.count) followed channels across \(pagesFetched) page(s)")
        } catch is CancellationError {
            logger.info("All-channels load cancelled — leaving existing data intact")
        } catch {
            allErrorMessage = "\(error)"
            allLoadState = .failed
            logger.error("Failed to load followed channels: \(error.localizedDescription)")
        }
    }

    /// Batches `fetchUsers(ids:)` for IDs not already cached. Skips empty
    /// inputs cheaply. Called from both loadAll (per page) and refreshLive
    /// (per page). The userProfiles dict accretes across both sources.
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
        } catch is CancellationError {
            logger.info("Profile enrichment cancelled for \(missing.count) channels")
        } catch {
            logger.error("Failed to load profile images for \(missing.count) channels: \(error.localizedDescription)")
        }
    }
}

// MARK: - Environment plumbing

public extension EnvironmentValues {
    @Entry var followsStore: FollowsStore? = nil
}
