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

    private var lastLiveFetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    public init() {}

    /// The live stream for `channelId`, merging this store with
    /// `FollowsStore` — whichever was refreshed more recently wins, so a
    /// channel that just went offline isn't kept "live" by a stale entry.
    public func liveStream(for channelId: String, follows: FollowsStore?) -> TwitchStream? {
        let followed = follows?.liveStreams[channelId]
        guard let status = statuses[channelId] else { return followed }
        if Date().timeIntervalSince(status.fetchedAt) < Self.streamStaleness * 2 {
            return status.stream
        }
        return followed ?? status.stream
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
        let now = Date()
        let due = Array(Set(channelIds)).filter { id in
            guard !inFlight.contains(id) else { return false }
            guard !force, let status = statuses[id] else { return true }
            return now.timeIntervalSince(status.fetchedAt) >= Self.streamStaleness
        }
        guard !due.isEmpty else { return }
        inFlight.formUnion(due)
        defer { inFlight.subtract(due) }

        let client = accountStore.client(for: account)
        do {
            for batch in due.chunked(into: 100) {
                let page = try await accountStore.withTokenRefresh(for: account) {
                    try await client.api.fetchStreamsPage(userIDs: batch, first: 100)
                }
                try Task.checkCancellation()
                let live = Dictionary(page.data.map { ($0.userId, $0) }, uniquingKeysWith: { a, _ in a })
                let offline = batch.filter { live[$0] == nil }

                var infos: [String: TwitchChannel] = [:]
                if !offline.isEmpty {
                    let channels = try await accountStore.withTokenRefresh(for: account) {
                        try await client.api.fetchChannelsInfo(forBroadcasterIDs: offline)
                    }
                    try Task.checkCancellation()
                    infos = Dictionary(channels.map { ($0.broadcasterId, $0) }, uniquingKeysWith: { a, _ in a })
                }

                let fetchedAt = Date()
                var updated = statuses
                for id in batch {
                    var status = updated[id] ?? Status(stream: nil, channelInfo: nil, lastLiveAt: nil, fetchedAt: fetchedAt)
                    status.stream = live[id]
                    if let info = infos[id] { status.channelInfo = info }
                    status.fetchedAt = fetchedAt
                    updated[id] = status
                }
                statuses = updated

                if includeLastLive {
                    for id in offline { await refreshLastLive(channelId: id, client: client, account: account, accountStore: accountStore) }
                }
            }
        } catch is CancellationError {
            // View went away mid-refresh; keep whatever landed.
        } catch {
            logger.error("Channel status refresh failed for \(due.count) channel(s): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Last-live for one channel on demand — the Following list calls this
    /// as offline rows scroll into view, so a 500-follow account costs one
    /// `/videos` call per row actually looked at (and none for 30 minutes
    /// after). No-op while the channel is known to be live.
    public func ensureLastLive(channelId: String, account: Account, accountStore: AccountStore) async {
        guard statuses[channelId]?.isLive != true else { return }
        await refreshLastLive(
            channelId: channelId,
            client: accountStore.client(for: account),
            account: account,
            accountStore: accountStore
        )
    }

    private func refreshLastLive(
        channelId: String,
        client: TwitchClient,
        account: Account,
        accountStore: AccountStore
    ) async {
        if let last = lastLiveFetchedAt[channelId],
           Date().timeIntervalSince(last) < Self.lastLiveStaleness { return }
        lastLiveFetchedAt[channelId] = Date()
        do {
            let page = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchVideosPage(userID: channelId, type: "archive", first: 1)
            }
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
