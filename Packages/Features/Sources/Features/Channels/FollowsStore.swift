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
///     a reload via `refreshAll`. The last completed list is also kept on
///     disk per account (`FollowsRosterCache`): a cold launch shows it at
///     once and the load then revalidates it.
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

    /// Broadcaster ids of `channels`, maintained with the sort. Lets a
    /// reader tell "followed and not in the live list" (offline) from "not
    /// followed" (the live list says nothing about it).
    public private(set) var followedChannelIds: Set<String> = []

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

    /// Wall-clock time of the last successful live refresh — what
    /// `liveStreams` is current as of. Nil until one completes for this
    /// account. (`lastLiveRefreshAt` is the same moment on the monotonic
    /// clock, for the throttle.)
    public private(set) var liveRefreshedAt: Date?

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

    /// Bumped by every live refresh and by every account switch; only the
    /// newest refresh may write its outcome (see `performLiveRefresh`).
    @ObservationIgnored private var liveRefreshGeneration = 0

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
    ///
    /// Coalesced: RootView's launch load and FollowingList's `.task` both
    /// call this, often before the first full load (follows ÷ 100 Helix
    /// pages, plus profile lookups) finishes — the second caller awaits the
    /// in-flight load instead of running a duplicate paginated fetch.
    public func loadAllIfNeeded(account: Account, accountStore: AccountStore) async {
        await loadAllIfNeeded(
            accountUserId: account.userId,
            dependencies: .live(accountStore: accountStore)
        )
    }

    func loadAllIfNeeded(accountUserId userId: String, dependencies: Dependencies) async {
        // A caller that's already cancelled (e.g. a torn-down `.task` for the
        // previous account) must not switch the store: the unstructured load
        // task below wouldn't inherit its cancellation.
        guard !Task.isCancelled, loadedAllForUserId != userId else { return }
        // Switch accounts NOW, synchronously, as the inline load always did —
        // not later when the queued task starts. Otherwise a `refreshLive` for
        // the store's current account in that gap would see no switch, leave
        // this queued load alone, and then be undone by it. `prepare` also
        // cancels and drops another account's in-flight load.
        prepare(forAccountUserId: userId)
        if let inFlight = allLoadInFlight, inFlight.userId == userId {
            await inFlight.task.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            // The roster saved on disk goes up first, so the list is on
            // screen while the load below revalidates it (as a refresh: one
            // swap when it completes).
            await self.restoreRoster(userId: userId, dependencies: dependencies)
            await self.loadAll(userId: userId, dependencies: dependencies)
        }
        allLoadInFlight = (userId, task)
        await task.value
        if allLoadInFlight?.task == task { allLoadInFlight = nil }
    }

    /// The `loadAllIfNeeded` load in flight, keyed by account.
    @ObservationIgnored private var allLoadInFlight: (userId: String, task: Task<Void, Never>)?

    /// Bumped by every full load and by every account switch; only the
    /// newest load may commit (see `loadAll`).
    @ObservationIgnored private var allLoadGeneration = 0

    /// Force-reload the All list (pull-to-refresh on the All view).
    public func refreshAll(account: Account, accountStore: AccountStore) async {
        await refreshAll(
            accountUserId: account.userId,
            dependencies: .live(accountStore: accountStore)
        )
    }

    func refreshAll(accountUserId: String, dependencies: Dependencies) async {
        await loadAll(userId: accountUserId, dependencies: dependencies)
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
        await refreshLive(
            accountUserId: account.userId,
            dependencies: .live(accountStore: accountStore),
            force: force
        )
    }

    func refreshLive(accountUserId userId: String, dependencies: Dependencies, force: Bool = false) async {
        prepare(forAccountUserId: userId)

        if let inFlight = liveRefreshTask {
            await inFlight.value
            return
        }
        if !force, liveLoadState == .loaded, let last = lastLiveRefreshAt,
           dependencies.now() - last < Self.liveStalenessInterval {
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLiveRefresh(userId: userId, dependencies: dependencies)
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
        liveRefreshGeneration &+= 1
        lastLiveRefreshAt = nil
        if liveRefreshedAt != nil { liveRefreshedAt = nil }
        for task in liveEnrichmentTasks { task.cancel() }
        liveEnrichmentTasks = []
        for task in allEnrichmentTasks { task.cancel() }
        allEnrichmentTasks = []

        // Any full load from an earlier account session is dead, whichever
        // path switched accounts: it can no longer commit (generation), and
        // nobody may join it — an A → B → A round trip must start A afresh.
        // A load for THIS account is the one calling us (`loadAll` runs
        // `prepare` first), so it's left alone.
        allLoadGeneration &+= 1
        if let inFlight = allLoadInFlight, inFlight.userId != userId {
            inFlight.task.cancel()
            allLoadInFlight = nil
        }

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
    /// `loadAll`, once at the end of each live refresh, when the saved roster
    /// is restored, and on account swap.
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
        // Unchanged on a live-only re-sort: don't notify its readers then.
        let ids = Set(channels.map(\.broadcasterId))
        if ids != followedChannelIds { followedChannelIds = ids }
    }

    // MARK: - Load implementation: Live

    /// Paginates `/streams/followed`. The first load into an empty list
    /// commits per page so the UI sees streams as they arrive; a refresh of
    /// a list that already has rows builds the new one locally and swaps it
    /// in once, so the list never shrinks to its first page and regrows.
    /// The All view's live-first sort is refreshed once when the loop exits
    /// (on every path), not per page.
    private func performLiveRefresh(userId: String, dependencies: Dependencies) async {
        // Swapped away before this Task even started: don't touch state (or
        // the new account's enrichment tasks below).
        guard !Task.isCancelled else { return }

        liveRefreshGeneration &+= 1
        let generation = liveRefreshGeneration

        // Cancel + clear enrichment from a prior *live* load only — the All
        // load's enrichment is independent and keeps running.
        for task in liveEnrichmentTasks { task.cancel() }
        liveEnrichmentTasks = []

        let commitsProgressively = liveStreamsOrdered.isEmpty
        // What a cancelled refresh puts back.
        let stateBeforeRefresh: LoadState = liveLoadState == .loading ? .idle : liveLoadState
        let errorBeforeRefresh = liveErrorMessage

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
            var cursor: String? = nil
            var pagesFetched = 0

            repeat {
                let page = try await dependencies.followedStreamsPage(userId, cursor)
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
                if commitsProgressively {
                    // Commit progressively so the UI sees streams as pages arrive.
                    liveStreamsOrdered = fresh
                    liveStreams = freshMap
                    liveStreamSearchKeys = freshKeys
                }

                // Kick off profile enrichment for live channels not already cached.
                let liveIds = page.data.map(\.userId)
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.enrichProfiles(ids: liveIds, userId: userId, dependencies: dependencies)
                }
                liveEnrichmentTasks.append(task)

                cursor = page.pagination?.cursor
                if pagesFetched >= 20 {
                    logger.warning("Hit live-streams pagination cap — stopping")
                    break
                }
            } while cursor != nil

            if !commitsProgressively {
                // The one swap of a refresh. No suspension since the last
                // cancellation check, so this is still our account's store.
                liveStreamsOrdered = fresh
                liveStreams = freshMap
                liveStreamSearchKeys = freshKeys
            }
            liveLoadState = .loaded
            lastLiveRefreshAt = dependencies.now()
            liveRefreshedAt = Date()
            logger.info("Loaded \(fresh.count) live followed channel(s) across \(pagesFetched) page(s)")
        } catch is CancellationError {
            // Cancelled by an account swap, which already reset the state
            // for the new account (and may have started its refresh): leave
            // whatever we already committed and exit silently. Only if
            // nothing took over is the `.loading` above still ours to undo.
            if liveRefreshGeneration == generation {
                liveLoadState = stateBeforeRefresh
                liveErrorMessage = errorBeforeRefresh
            }
            logger.info("Live-streams load cancelled")
        } catch {
            // Superseded while failing: the state belongs to a newer refresh.
            guard liveRefreshGeneration == generation else { return }
            liveErrorMessage = "\(error)"
            liveLoadState = .failed
            logger.error("Failed to load live followed channels: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Load implementation: All

    /// Paginates `/channels/followed`, building the next channel list into a
    /// local array. The first load into an empty store commits progressively
    /// so the UI sees rows as pages arrive: commits (each re-sorts the full
    /// list) are throttled to the first page, the last page, and at most one
    /// per `allCommitInterval` in between. A refresh of a store that already
    /// has rows commits once, on the last page. The progress counter still
    /// updates every page. Profile enrichment fires per page.
    ///
    /// State-reset policy:
    ///   - Account swap: `prepare(forAccountUserId:)` wipes stale data
    ///     immediately so the previous user's follows don't briefly appear
    ///     under the new user's name.
    ///   - Refresh (same account): keep existing data visible until the new
    ///     list is complete — pull-to-refresh's own spinner is the loading
    ///     signal.
    ///
    /// CancellationError is treated as benign and leaves the data intact
    /// (view tear-down / `.task(id:)` re-fire); the load state goes back to
    /// what it was before this load unless a newer load owns it.
    private func loadAll(userId: String, dependencies: Dependencies) async {
        // A load cancelled before it started (an account switch got there
        // first) must not run `prepare`: it would switch the store back to
        // its stale account and wipe the newer one's state.
        guard !Task.isCancelled else { return }
        prepare(forAccountUserId: userId)

        // Only the newest full load may commit, and only into the account it
        // was started for: every account switch bumps this too (`prepare`),
        // so a load that outlived a switch — or a round trip (A → B → A),
        // which an account check alone would pass — is stale either way.
        allLoadGeneration &+= 1
        let generation = allLoadGeneration

        // Cancel in-flight enrichment from a previous *All* load only — the
        // live refresh's enrichment is independent.
        for task in allEnrichmentTasks { task.cancel() }
        allEnrichmentTasks = []

        // Page-by-page commits only when filling an empty store. A refresh
        // keeps the current list on screen and swaps the new one in whole —
        // committing its first page shrank a long list to 100 rows and
        // regrew it.
        let commitsProgressively = channels.isEmpty
        // What a cancelled load puts back. `.loading` here is a load this
        // one just superseded, which will never finish it: fall back to
        // what the store actually holds.
        let stateBeforeLoad: LoadState
        if allLoadState == .loading {
            stateBeforeLoad = loadedAllForUserId == userId ? .loaded : .idle
        } else {
            stateBeforeLoad = allLoadState
        }
        let errorBeforeLoad = allErrorMessage
        let totalBeforeLoad = totalFollowed

        allLoadState = .loading
        allLoadProgress = 0
        totalFollowed = nil
        allErrorMessage = nil

        // Outside the `do` so a mid-pagination failure can still commit the
        // pages fetched since the last throttled commit.
        var accumulated: [FollowedChannel] = []

        do {
            var cursor: String? = nil
            let pageCap = 200
            var pagesFetched = 0
            var lastCommitAt: ContinuousClock.Instant?

            repeat {
                let page = try await dependencies.followedChannelsPage(userId, cursor)
                // A swap to another account (via either load path) wiped the
                // store mid-request, or a newer load took over; don't commit
                // this page into it.
                guard allLoadGeneration == generation else { throw CancellationError() }
                pagesFetched += 1

                accumulated.append(contentsOf: page.data)
                allLoadProgress = accumulated.count
                cursor = page.pagination?.cursor
                let isLastPage = cursor == nil || pagesFetched >= pageCap

                // Always the last page. When filling an empty store, also
                // the first page (rows appear fast) and otherwise at most
                // once per `allCommitInterval`.
                let now = dependencies.now()
                let commitsThisPage = commitsProgressively
                    && (lastCommitAt.map { now - $0 >= Self.allCommitInterval } ?? true)
                if isLastPage || commitsThisPage {
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
                    await self.enrichProfiles(ids: pageIds, userId: userId, dependencies: dependencies)
                }
                allEnrichmentTasks.append(profileTask)

                if pagesFetched >= pageCap {
                    logger.warning("Hit pagination safety cap (\(pageCap) pages) — stopping")
                    break
                }
            } while cursor != nil

            guard allLoadGeneration == generation else { throw CancellationError() }
            allLoadState = .loaded
            loadedAllForUserId = userId
            logger.info("Loaded \(self.channels.count) followed channels across \(pagesFetched) page(s)")
            saveRoster(userId: userId, generation: generation, dependencies: dependencies)
        } catch is CancellationError {
            // Superseded (an account switch, or a newer load): that load
            // owns the state now. Cancelled outright (pull-to-refresh torn
            // down): nothing will finish this load, so don't leave it
            // spinning.
            if allLoadGeneration == generation {
                allLoadState = stateBeforeLoad
                allErrorMessage = errorBeforeLoad
                totalFollowed = totalBeforeLoad
                allLoadProgress = channels.count
            }
            logger.info("All-channels load cancelled — leaving existing data intact")
        } catch {
            // Keep what we fetched visible (the footer offers Retry for the
            // rest), matching the pre-throttle per-page-commit behavior.
            guard allLoadGeneration == generation else { return }
            if accumulated.count > channels.count {
                channels = accumulated
                recomputeSortedAllChannels()
            }
            allErrorMessage = "\(error)"
            allLoadState = .failed
            logger.error("Failed to load followed channels: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Roster cache

    /// Puts the roster saved by this account's last completed load on
    /// screen. Only into an empty list, and only while nothing else has
    /// claimed it: the read suspends, and an account switch (which also
    /// cancels this task) or a full load started meanwhile bumps
    /// `allLoadGeneration` — that one owns the list, and a load filling it
    /// page by page must not have a whole roster dropped under it. The load
    /// state is left alone: a cached roster is not a completed load, so
    /// `loadAllIfNeeded` still revalidates.
    private func restoreRoster(userId: String, dependencies: Dependencies) async {
        // Cancelled before it started: an account switch got there first,
        // and this account's roster is not for that store (see `loadAll`).
        guard !Task.isCancelled, channels.isEmpty else { return }
        let generation = allLoadGeneration
        guard let roster = await dependencies.loadRoster(userId), !roster.channels.isEmpty else { return }
        guard !Task.isCancelled, allLoadGeneration == generation, channels.isEmpty else { return }
        channels = roster.channels
        // A live refresh may already have fetched some of these: keep the
        // fetched ones, they are newer.
        profileImageURLs = roster.profileImageURLs.merging(profileImageURLs) { _, fetched in fetched }
        recomputeSortedAllChannels()
        logger.info("Restored \(roster.channels.count) followed channels from disk")
    }

    /// Saves the list a full load just completed, once that load's profile
    /// batches have landed so their image URLs go with it. Skipped if the
    /// list has moved on by then (an account switch or a newer load, either
    /// of which also cancels those batches): the newer load saves its own.
    private func saveRoster(userId: String, generation: Int, dependencies: Dependencies) {
        let enrichment = allEnrichmentTasks
        rosterSaveTask = Task { [weak self] in
            for task in enrichment { await task.value }
            guard let self, self.allLoadGeneration == generation else { return }
            let followed = self.followedChannelIds
            let roster = FollowsRoster(
                channels: self.channels,
                profileImageURLs: self.profileImageURLs.filter { followed.contains($0.key) }
            )
            await dependencies.saveRoster(userId, roster)
        }
    }

    /// The most recent roster save, so tests can wait for it (and for the
    /// profile batches it waits on).
    @ObservationIgnored private(set) var rosterSaveTask: Task<Void, Never>?

    /// Batches `fetchUsers(ids:)` for IDs not already cached. Skips empty
    /// inputs cheaply. Called from both loadAll (per page) and refreshLive
    /// (per page). The userProfiles dict accretes across both sources.
    private func enrichProfiles(ids: [String], userId: String, dependencies: Dependencies) async {
        let missing = ids.filter { userProfiles[$0] == nil }
        guard !missing.isEmpty else { return }
        do {
            let users = try await dependencies.users(userId, missing)
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

// MARK: - Environment plumbing

public extension EnvironmentValues {
    @Entry var followsStore: FollowsStore? = nil
}
