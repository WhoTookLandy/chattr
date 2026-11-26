import Foundation
import Observation
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelTwitchEmotesStore")

/// Per-channel Twitch native emotes (`GET /chat/emotes?broadcaster_id=`).
///
/// Complements the account-wide `UserEmoteStore` (which walks
/// `GET /chat/emotes/user` without a broadcaster filter so it can be cached
/// once per account). Twitch only includes a channel's **follower emotes**
/// in `/chat/emotes/user` when `broadcaster_id` is passed or the user is
/// subscribed — fetching the single-page channel endpoint once per open
/// channel gives the picker those follower emotes immediately too.
///
/// Same lifecycle and idempotency/coalescing rules as `ChatBadgeStore`:
/// registry-owned per `(accountUserId, channelId)`, survives `ChatScreen`
/// unmount/remount across pager swipes, and drops when the tab closes.
@MainActor
@Observable
public final class ChannelTwitchEmotesStore {

    /// The channel's Twitch emotes (follower, subscriber, bits-tier).
    public private(set) var emotes: [TwitchEmote] = []

    /// Process-wide version source so a replacement store for the same channel
    /// can never reuse an earlier store's cache key.
    private static let versionSource = OSAllocatedUnfairLock<Int>(initialState: 0)

    /// Monotonically bumped on every publish — O(1) cache key for the picker.
    public private(set) var version: Int = 0

    private static func nextVersion() -> Int {
        versionSource.withLock { value in
            value += 1
            return value
        }
    }

    private var loadedChannelId: String?
    @ObservationIgnored private var inFlightLoad: (channelId: String, token: UInt64, task: Task<Void, Never>)?
    @ObservationIgnored private var nextLoadToken: UInt64 = 0

    public init() {}

    /// Fetches this channel's Twitch emotes once (unless `force` is true).
    /// Concurrent callers for the same channel coalesce onto one Helix call.
    public func load(
        account: Account,
        accountStore: AccountStore,
        channelId: String,
        force: Bool = false
    ) async {
        if !force, loadedChannelId == channelId {
            return
        }
        if let inFlight = inFlightLoad, inFlight.channelId == channelId {
            await inFlight.task.value
            return
        }

        inFlightLoad?.task.cancel()
        nextLoadToken &+= 1
        let token = nextLoadToken

        let client = accountStore.client(for: account)
        let userId = account.userId
        let task = Task { @MainActor in
            await self.performLoad(
                client: client,
                accountStore: accountStore,
                userId: userId,
                channelId: channelId,
                token: token
            )
        }
        inFlightLoad = (channelId, token, task)
        await task.value
    }

    private func performLoad(
        client: TwitchClient,
        accountStore: AccountStore,
        userId: String,
        channelId: String,
        token: UInt64
    ) async {
        defer {
            if inFlightLoad?.token == token { inFlightLoad = nil }
        }
        do {
            let fetched = try await accountStore.withTokenRefresh(forUserId: userId) {
                try await client.api.fetchChannelEmotes(forBroadcasterID: channelId)
            }
            guard !Task.isCancelled, token == nextLoadToken else { return }
            if fetched != emotes {
                emotes = fetched
                version = Self.nextVersion()
            }
            loadedChannelId = channelId
            logger.info("Loaded \(fetched.count) Twitch channel emote(s) for \(channelId, privacy: .public)")
        } catch is CancellationError {
            // Expected on teardown/supersede.
        } catch {
            logger.error("Failed to load Twitch channel emotes for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
