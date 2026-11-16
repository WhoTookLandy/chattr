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
///     metadata (game, viewer count, title). Refetched on Home / Follows
///     visits and on app foreground, throttled to once per
///     `liveStalenessInterval`; pull-to-refresh and Retry pass `force: true`
///     to bypass the throttle. Concurrent callers share one in-flight fetch.
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
    /// broadcasterId → parsed profile-image URL, maintained alongside
    /// `userProfiles` so list bodies hand each row a resolved URL instead of
    /// re-parsing `profileImageUrl` strings on every body evaluation.
    public private(set) var profileImageURLs: [String: URL] = [:]
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
    /// Maintained by `recomputeSortedAllChannels()`, which runs on throttled
    /// page commits in `loadAll` and once at the end of each live refresh —
    /// not per live page. Sort is stable: ties (same viewer count, or both
    /// offline) resolve by original-index position in `channels`.
    public private(set) var sortedAllChannels: [FollowedChannel] = []

    /// Lowercased search keys aligned index-for-index with
    /// `sortedAllChannels` (`"name\nlogin"`). Precomputed alongside the sort
    /// so search filtering doesn't lowercase every channel on every keystroke.
    public private(set) var sortedAllChannelSearchKeys: [String] = []

    // MARK: - "Live" data set (foreground, refetched when stale)

    /// Live channels in Twitch's returned order (desc viewer count). Drives
    /// the Live segmented view.
    public private(set) var liveStreamsOrdered: [TwitchStream] = []

    /// Same data keyed by broadcasterId. Drives LIVE badges on the All view.
    public private(set) var liveStreams: [String: TwitchStream] = [:]

    /// Lowercased search keys (`"name\nlogin\ngame"`) keyed by broadcaster
    /// userId, rebuilt with each live commit so the Live search filter
    /// doesn't re-lowercase every stream per keystroke.
    public private(set) var liveStreamSearchKeys: [String: String] = [:]

    public private(set) var liveLoadState: LoadState = .idle
    public private(set) var liveErrorMessage: String?

    // MARK: - Internal bookkeeping

    /// Minimum age of the last successful live refresh before a non-forced
    /// `refreshLive` refetches. Home, Following, RootView and scene
    /// activation all request a refresh; without this, every tab switch or
    /// quick background/foreground round-trip refetched.
    public static let liveStalenessInterval: Duration = .seconds(60)

    /// Minimum interval between intermediate page commits in `loadAll`.
    /// A commit re-sorts the whole accumulated list, so a large follow list
    /// no longer re-sorts once per page — the first and last page always
    /// commit; pages in between commit at most this often.
    private static let allCommitInterval: Duration = .milliseconds(500)

    /// The account whose data (All + Live + profiles) this store currently
    /// holds. `prepare(forAccountUserId:)` wipes everything and cancels all
    /// in-flight work when a load for a different account starts — whichever
    /// of `refreshLive` / `loadAll` runs first after a swap does the wipe;
    /// the other sees a matching id and leaves the new account's data alone.
    private var currentUserId: String?

    /// Which account's *All* data we currently hold. The cache hit/miss is
    /// driven entirely off this.
    private var loadedAllForUserId: String?

    /// Shared in-flight live refresh. Concurrent `refreshLive` callers (Home,
    /// Following, RootView, scene activation) await this one Task instead of
    /// each starting their own.
    private var liveRefreshTask: Task<Void, Never>?

    /// When the last live refresh completed successfully. Drives the
    /// staleness throttle; reset on account swap.
    private var lastLiveRefreshAt: ContinuousClock.Instant?

    /// In-flight profile-enrichment Tasks, split by data set so a live
    /// refresh and an All load never cancel each other's enrichment. Each
    /// list is cancelled + cleared at the start of its own load (both on an
    /// account swap), so each is bounded by one load's page count.
    private var liveEnrichmentTasks: [Task<Void, Never>] = []
    private var allEnrichmentTasks: [Task<Void, Never>] = []

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

    /// Refreshes the Live list.
    ///
    /// - Coalesced: if a refresh is already in flight for this account, the
    ///   caller awaits it instead of starting another (even when `force`).
    /// - Throttled: a non-forced call within `liveStalenessInterval` of the
    ///   last successful refresh is a no-op. Pass `force: true` for explicit
    ///   user intent (pull-to-refresh, Retry).
    ///
    /// The fetch runs in a store-owned Task, so one caller's cancellation
    /// (e.g. a `.task` torn down by a tab switch) doesn't abort a refresh
    /// other callers share. An account swap does cancel it.
    public func refreshLive(account: Account, accountStore: AccountStore, force: Bool = false) async {
        prepare(forAccountUserId: account.userId)

        if let inFlight = liveRefreshTask {
            await inFlight.value
            return
        }
        if !force, liveLoadState == .loaded, let last = lastLiveRefreshAt,
           ContinuousClock.now - last < Self.liveStalenessInterval {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLiveRefresh(account: account, accountStore: accountStore)
        }
        liveRefreshTask = task
        await task.value
        // Only clear our own Task — an account swap may already have
        // cancelled it and a newer refresh may now occupy the slot.
        if liveRefreshTask == task {
            liveRefreshTask = nil
        }
    }

    // MARK: - Account scoping

    /// Wipes all per-account state and cancels all in-flight work when
    /// `userId` differs from the account whose data we hold; no-op otherwise.
    /// Wiping immediately keeps the previous user's follows from briefly
    /// appearing under the new user's name.
    private func prepare(forAccountUserId userId: String) {
        guard currentUserId != userId else { return }
        let hadPreviousAccount = currentUserId != nil
        currentUserId = userId

        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        lastLiveRefreshAt = nil
        for task in liveEnrichmentTasks { task.cancel() }
        liveEnrichmentTasks = []
        for task in allEnrichmentTasks { task.cancel() }
        allEnrichmentTasks = []

        guard hadPreviousAccount else { return }
        loadedAllForUserId = nil
        channels = []
        liveStreams = [:]
        liveStreamsOrdered = []
        liveStreamSearchKeys = [:]
        userProfiles = [:]
        profileImageURLs = [:]
        liveLoadState = .idle
        allLoadState = .idle
        recomputeSortedAllChannels()
    }

    // MARK: - Sorted cache maintenance

    /// Recomputes `sortedAllChannels` (and its aligned search keys) from the
    /// current `channels` + `liveStreams`. Called on throttled page commits in
    /// `loadAll`, once at the end of each live refresh, and on account swap.
    ///
    /// Viewer counts are resolved once per channel up front rather than with
    /// two dictionary lookups per comparison. The original index breaks ties
    /// — Swift's `sorted(by:)` is not guaranteed stable, so we force it.
    private func recomputeSortedAllChannels() {
        let keyed = channels.enumerated().map { offset, channel in
            (offset: offset, viewers: liveStreams[channel.broadcasterId]?.viewerCount, channel: channel)
        }
        let sorted = keyed.sorted { lhs, rhs in
            switch (lhs.viewers, rhs.viewers) {
            case let (l?, r?): return l != r ? l > r : lhs.offset < rhs.offset
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }
        sortedAllChannels = sorted.map { $0.channel }
        sortedAllChannelSearchKeys = sortedAllChannels.map {
            ($0.broadcasterName + "\n" + $0.broadcasterLogin).lowercased()
        }
    }

    // MARK: - Load implementation: Live

    /// Paginates `/streams/followed`, committing per page so the UI sees
    /// streams as they arrive. The All view's live-first sort is refreshed
    /// once when the loop exits (on every path), not per page.
    private func performLiveRefresh(account: Account, accountStore: AccountStore) async {
        // Swapped away before this Task even started: don't touch state (or
        // the new account's enrichment tasks below).
        guard !Task.isCancelled else { return }

        // Cancel + clear enrichment from a prior *live* load only — the All
        // load's enrichment is independent and keeps running.
        for task in liveEnrichmentTasks { task.cancel() }
        liveEnrichmentTasks = []

        liveLoadState = .loading
        liveErrorMessage = nil

        var fresh: [TwitchStream] = []
        var freshMap: [String: TwitchStream] = [:]
        var freshKeys: [String: String] = [:]
        // A cancelled (swapped-away) refresh must not re-sort: `prepare`
        // already reset the cache for the new account.
        defer {
            if !Task.isCancelled { recomputeSortedAllChannels() }
        }

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
                // An account swap cancels this Task; don't commit the previous
                // account's page into the freshly-wiped store.
                try Task.checkCancellation()
                pagesFetched += 1

                fresh.append(contentsOf: page.data)
                for stream in page.data {
                    freshMap[stream.userId] = stream
                    freshKeys[stream.userId] =
                        (stream.userName + "\n" + stream.userLogin + "\n" + stream.gameName).lowercased()
                }
                // Commit progressively so the UI sees streams as pages arrive.
                liveStreamsOrdered = fresh
                liveStreams = freshMap
                liveStreamSearchKeys = freshKeys

                // Kick off profile enrichment for live channels not already cached.
                let liveIds = page.data.map(\.userId)
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.enrichProfiles(ids: liveIds, account: account, accountStore: accountStore)
                }
                liveEnrichmentTasks.append(task)

                cursor = page.pagination?.cursor
                if pagesFetched >= 20 {
                    logger.warning("Hit live-streams pagination cap — stopping")
                    break
                }
            } while cursor != nil

            liveLoadState = .loaded
            lastLiveRefreshAt = .now
            logger.info("Loaded \(fresh.count) live followed channel(s) across \(pagesFetched) page(s)")
        } catch is CancellationError {
            // Cancelled (account swap) — leave whatever we already committed
            // visible and exit silently.
            logger.info("Live-streams load cancelled")
        } catch {
            liveErrorMessage = "\(error)"
            liveLoadState = .failed
            logger.error("Failed to load live followed channels: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Load implementation: All

    /// Paginates `/channels/followed`, building the next channel list into a
    /// local array and committing progressively so the UI sees rows as pages
    /// arrive. Commits (each re-sorts the full list) are throttled to the
    /// first page, the last page, and at most one per `allCommitInterval` in
    /// between; the progress counter still updates every page. Profile
    /// enrichment fires per page.
    ///
    /// State-reset policy:
    ///   - Account swap: `prepare(forAccountUserId:)` wipes stale data
    ///     immediately so the previous user's follows don't briefly appear
    ///     under the new user's name.
    ///   - Refresh (same account): keep existing data visible until new pages
    ///     arrive — pull-to-refresh's own spinner is the loading signal.
    ///
    /// CancellationError is treated as benign and leaves state intact (view
    /// tear-down / `.task(id:)` re-fire).
    private func loadAll(account: Account, accountStore: AccountStore) async {
        prepare(forAccountUserId: account.userId)

        // Cancel in-flight enrichment from a previous *All* load only — the
        // live refresh's enrichment is independent.
        for task in allEnrichmentTasks { task.cancel() }
        allEnrichmentTasks = []

        allLoadState = .loading
        allLoadProgress = 0
        totalFollowed = nil
        allErrorMessage = nil

        let userId = account.userId
        // Outside the `do` so a mid-pagination failure can still commit the
        // pages fetched since the last throttled commit.
        var accumulated: [FollowedChannel] = []

        do {
            let client = accountStore.client(for: account)

            var cursor: String? = nil
            let pageCap = 200
            var pagesFetched = 0
            var lastCommitAt: ContinuousClock.Instant?

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
                // A swap to another account (via either load path) wiped the
                // store mid-request; don't commit this account's page into it.
                guard currentUserId == userId else { throw CancellationError() }
                pagesFetched += 1

                accumulated.append(contentsOf: page.data)
                allLoadProgress = accumulated.count
                cursor = page.pagination?.cursor
                let isLastPage = cursor == nil || pagesFetched >= pageCap

                // Throttled commit: first page (rows appear fast), last page,
                // and otherwise at most once per `allCommitInterval`.
                let now = ContinuousClock.now
                if isLastPage || lastCommitAt.map({ now - $0 >= Self.allCommitInterval }) ?? true {
                    channels = accumulated
                    recomputeSortedAllChannels()
                    lastCommitAt = now
                }

                if totalFollowed == nil, let total = page.total {
                    totalFollowed = total
                }

                // Enrich profile images for this page. Live-stream enrichment
                // is refreshLive()'s job, not this path's.
                let pageIds = page.data.map(\.broadcasterId)
                let profileTask = Task { [weak self] in
                    guard let self else { return }
                    await self.enrichProfiles(ids: pageIds, account: account, accountStore: accountStore)
                }
                allEnrichmentTasks.append(profileTask)

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
            // Keep what we fetched visible (the footer offers Retry for the
            // rest), matching the pre-throttle per-page-commit behavior.
            if currentUserId == userId, accumulated.count > channels.count {
                channels = accumulated
                recomputeSortedAllChannels()
            }
            allErrorMessage = "\(error)"
            allLoadState = .failed
            logger.error("Failed to load followed channels: \(error.localizedDescription, privacy: .public)")
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
            // Bail if cancelled while the request was in flight (account swap):
            // the fetch can return *after* `prepare` has cancelled us and wiped
            // userProfiles, and writing here would re-populate the new account's
            // dict with the previous account's profiles.
            guard !Task.isCancelled else { return }
            // Build into locals and assign once each, so observers see one
            // change per batch rather than one per user.
            var profiles = userProfiles
            var urls = profileImageURLs
            for user in users {
                profiles[user.id] = user
                urls[user.id] = URL(string: user.profileImageUrl)
            }
            userProfiles = profiles
            profileImageURLs = urls
        } catch is CancellationError {
            logger.info("Profile enrichment cancelled for \(missing.count) channels")
        } catch {
            logger.error("Failed to load profile images for \(missing.count) channels: \(error.localizedDescription, privacy: .public)")
        }
    }
}
