import Foundation
import SwiftUI
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ChannelStatusStore")

/// Live / offline status for the channels the user has OPEN (chat tabs),
/// whether or not they follow them. `FollowsStore` only knows about followed
/// channels that are live; this store fills the gaps the chat surfaces need:
///
///   - a live channel opened from search (not followed) → its `TwitchStream`;
///   - an offline channel → its current title + category (`/channels`) and
///     when it was last live (latest archive VOD, `/videos?type=archive`).
///
/// Stream metadata is public data, so entries are keyed by channel id alone
/// and survive account switches. Refreshes are batched (one `/streams` call
/// for up to 100 ids) and throttled per channel; last-live lookups are one
/// call per offline channel and cached much longer, since a VOD's end time
/// doesn't move until the next stream.
@MainActor
@Observable
public final class ChannelStatusStore {

    /// What we know about one channel.
    public struct Status: Equatable, Sendable {
        /// Non-nil while live.
        public var stream: TwitchStream?
        /// Title / category / tags — current even while offline.
        public var channelInfo: TwitchChannel?
        /// End of the most recent archived broadcast. nil when unknown (VODs
        /// disabled, never streamed, or not fetched yet).
        public var lastLiveAt: Date?
        /// When `stream` was last confirmed (wall clock, for freshness
        /// comparisons against `FollowsStore`).
        public var fetchedAt: Date

        public var isLive: Bool { stream != nil }
    }

    public private(set) var statuses: [String: Status] = [:]

    /// Stream state goes stale fast (viewer counts, going live/offline).
    static let streamStaleness: TimeInterval = 60
    /// Last-live only changes when a new broadcast ends.
    static let lastLiveStaleness: TimeInterval = 30 * 60

    /// When each channel's last-live lookup last SUCCEEDED. A failed lookup
    /// leaves no mark, so it is retried the next time the channel is asked
    /// for instead of 30 minutes later.
    private var lastLiveFetchedAt: [String: Date] = [:]

    /// Channels a `refresh` is fetching right now, by the refresh that
    /// claimed them. A claim whose task was cancelled no longer counts: the
    /// poll that replaces a cancelled one (the open set changed) would
    /// otherwise skip those channels until its next round.
    private var inFlight: [String: RefreshClaim] = [:]

    private final class RefreshClaim: Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    /// Pending last-live lookups (see `LastLiveLookupQueue`), and who they
    /// run as — the most recent requester.
    @ObservationIgnored private var lastLiveQueue = LastLiveLookupQueue()
    @ObservationIgnored private var lastLiveRequester: (accountUserId: String, dependencies: Dependencies)?

    public init() {}

    /// The live stream for `channelId`, merging this store with
    /// `FollowsStore` — whichever was refreshed more recently wins, so a
    /// channel that just went offline isn't kept "live" by a stale entry.
    public func liveStream(for channelId: String, follows: FollowsStore?) -> TwitchStream? {
        let followed = follows?.liveStreams[channelId]
        guard let status = statuses[channelId] else { return followed }
        return Self.mergedLiveStream(
            statusStream: status.stream,
            statusFetchedAt: status.fetchedAt,
            followedStream: followed,
            followsRefreshedAt: follows?.liveRefreshedAt,
            isFollowed: followed != nil || follows?.followedChannelIds.contains(channelId) == true
        )
    }

    /// The merge behind `liveStream(for:follows:)`. The follows list answers
    /// for a channel only once it has loaded and only if the user follows
    /// the channel — to it, a channel opened from search is never live.
    /// Where both stores answer, the one refreshed more recently wins,
    /// including when its answer is "not live".
    nonisolated static func mergedLiveStream(
        statusStream: TwitchStream?,
        statusFetchedAt: Date,
        followedStream: TwitchStream?,
        followsRefreshedAt: Date?,
        isFollowed: Bool
    ) -> TwitchStream? {
        guard let followsRefreshedAt, isFollowed else { return statusStream ?? followedStream }
        return statusFetchedAt >= followsRefreshedAt ? statusStream : followedStream
    }

    /// Forgets the stream state of every channel not in `channelIds` (the
    /// open chats): nothing refreshes it once its chat is closed, so it
    /// would only go stale. A known last-live time is kept — the Following
    /// list shows it, and it doesn't go stale the same way.
    public func retainStreamState(forOpenChannels channelIds: [String]) {
        let open = Set(channelIds)
        var updated = statuses
        var changed = false
        for (id, status) in statuses where !open.contains(id) {
            if let lastLiveAt = status.lastLiveAt {
                let cleared = Status(stream: nil, channelInfo: nil, lastLiveAt: lastLiveAt, fetchedAt: .distantPast)
                guard cleared != status else { continue }
                updated[id] = cleared
            } else {
                updated[id] = nil
            }
            changed = true
        }
        if changed { statuses = updated }
    }

    /// Nil-tolerant form for views reading both (optional) environment
    /// stores: the merged answer when the status store exists, else the
    /// follows cache alone.
    public static func liveStream(
        for channelId: String,
        status: ChannelStatusStore?,
        follows: FollowsStore?
    ) -> TwitchStream? {
        if let status { return status.liveStream(for: channelId, follows: follows) }
        return follows?.liveStreams[channelId]
    }

    /// Refreshes every channel in `channelIds` whose stream state is stale
    /// (or all of them when `force`). Offline channels also get their
    /// title/category and, when `includeLastLive`, last-live time.
    public func refresh(
        channelIds: [String],
        account: Account,
        accountStore: AccountStore,
        includeLastLive: Bool = true,
        force: Bool = false
    ) async {
        await refresh(
            channelIds: channelIds,
            accountUserId: account.userId,
            dependencies: .live(accountStore: accountStore),
            includeLastLive: includeLastLive,
            force: force
        )
    }

    func refresh(
        channelIds: [String],
        accountUserId: String,
        dependencies: Dependencies,
        includeLastLive: Bool = true,
        force: Bool = false
    ) async {
        let now = dependencies.now()
        let due = Array(Set(channelIds)).filter { id in
            if let claim = inFlight[id], !claim.isCancelled { return false }
            guard !force, let status = statuses[id] else { return true }
            return now.timeIntervalSince(status.fetchedAt) >= Self.streamStaleness
        }
        guard !due.isEmpty else { return }
        let claim = RefreshClaim()
        for id in due { inFlight[id] = claim }
        // Only our own claims: a newer refresh may have taken over an id
        // after this one was cancelled.
        defer {
            for id in due where inFlight[id] === claim { inFlight[id] = nil }
        }
        // The claim is dropped the moment this task is cancelled, not when
        // the cancelled request finally unwinds.
        await withTaskCancellationHandler {
            await fetchStatuses(
                for: due, accountUserId: accountUserId, dependencies: dependencies, includeLastLive: includeLastLive
            )
        } onCancel: {
            claim.cancel()
        }
    }

    private func fetchStatuses(
        for due: [String],
        accountUserId: String,
        dependencies: Dependencies,
        includeLastLive: Bool
    ) async {
        do {
            for batch in due.chunked(into: 100) {
                let page = try await dependencies.streamsPage(accountUserId, batch)
                try Task.checkCancellation()
                let live = Dictionary(page.data.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })
                let offline = batch.filter { live[$0] == nil }

                var infos: [String: TwitchChannel] = [:]
                if !offline.isEmpty {
                    let channels = try await dependencies.channelsInfo(accountUserId, offline)
                    try Task.checkCancellation()
                    infos = Dictionary(channels.map { ($0.broadcasterId, $0) }, uniquingKeysWith: { a, _ in a })
                }

                let fetchedAt = dependencies.now()
                var updated = statuses
                for id in batch {
                    var status = updated[id] ?? Status(stream: nil, channelInfo: nil, lastLiveAt: nil, fetchedAt: fetchedAt)
                    status.stream = live[id]
                    if let info = infos[id] { status.channelInfo = info }
                    status.fetchedAt = fetchedAt
                    updated[id] = status
                }
                statuses = updated

                if includeLastLive, !offline.isEmpty {
                    // Queued, not awaited: each lookup is an independent
                    // `/videos` call, and the statuses above shouldn't wait
                    // on them.
                    requestLastLive(offline, accountUserId: accountUserId, dependencies: dependencies)
                }
            }
        } catch is CancellationError {
            // View went away mid-refresh; keep whatever landed.
        } catch {
            logger.error("Channel status refresh failed for \(due.count) channel(s): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Last-live for one channel on demand — the Following list calls this
    /// as offline rows scroll into view. It only joins the store's lookup
    /// line (`LastLiveLookupQueue`): the row's task neither runs the request
    /// nor can cancel it, so flinging through a long roster costs a few
    /// lookups for the rows it stops on, not one per row passed. No-op
    /// while the channel is known to be live, and for 30 minutes after a
    /// lookup that succeeded.
    public func ensureLastLive(channelId: String, account: Account, accountStore: AccountStore) {
        ensureLastLive(
            channelId: channelId,
            accountUserId: account.userId,
            dependencies: .live(accountStore: accountStore)
        )
    }

    func ensureLastLive(channelId: String, accountUserId: String, dependencies: Dependencies) {
        guard statuses[channelId]?.isLive != true else { return }
        requestLastLive([channelId], accountUserId: accountUserId, dependencies: dependencies)
    }

    /// Queues a last-live lookup for each of `channelIds` that isn't fresh,
    /// already waiting or already running.
    private func requestLastLive(_ channelIds: [String], accountUserId: String, dependencies: Dependencies) {
        lastLiveRequester = (accountUserId: accountUserId, dependencies: dependencies)
        let now = dependencies.now()
        for id in channelIds {
            if let last = lastLiveFetchedAt[id],
               now.timeIntervalSince(last) < Self.lastLiveStaleness { continue }
            lastLiveQueue.enqueue(id)
        }
        startLastLiveLookups()
    }

    /// Starts lookups until the line is empty or its concurrency limit is
    /// reached. Each runs on a task the store owns — not a child of whatever
    /// asked — so a row scrolling away cancels nothing.
    private func startLastLiveLookups() {
        guard let requester = lastLiveRequester else { return }
        while let channelId = lastLiveQueue.startNext() {
            Task { [weak self] in
                await self?.lookUpLastLive(
                    channelId: channelId,
                    accountUserId: requester.accountUserId,
                    dependencies: requester.dependencies
                )
            }
        }
    }

    private func lookUpLastLive(channelId: String, accountUserId: String, dependencies: Dependencies) async {
        defer {
            lastLiveQueue.finish(channelId)
            startLastLiveLookups()
        }
        // It may have gone live while it waited.
        guard statuses[channelId]?.isLive != true else { return }
        do {
            let page = try await dependencies.latestArchivePage(accountUserId, channelId)
            lastLiveFetchedAt[channelId] = dependencies.now()
            guard let video = page.data.first else { return }
            let end = video.createdAt.addingTimeInterval(Self.seconds(inTwitchDuration: video.duration))
            if statuses[channelId] != nil {
                statuses[channelId]?.lastLiveAt = end
            } else {
                // First thing we've learned about this channel. `distantPast`
                // fetchedAt keeps the (unknown) stream state stale, so
                // `liveStream(for:)` still defers to FollowsStore and the
                // next `refresh` still fetches it.
                statuses[channelId] = Status(stream: nil, channelInfo: nil, lastLiveAt: end, fetchedAt: .distantPast)
            }
        } catch {
            // Non-fatal: the header just says "Offline" without a time.
            logger.info("Last-live lookup failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Parses Twitch's VOD duration format ("3h2m1s", "45m10s", "12s").
    nonisolated static func seconds(inTwitchDuration duration: String) -> TimeInterval {
        var total: TimeInterval = 0
        var number = ""
        for character in duration {
            if character.isNumber {
                number.append(character)
                continue
            }
            let value = TimeInterval(number) ?? 0
            number = ""
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: break
            }
        }
        return total
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
