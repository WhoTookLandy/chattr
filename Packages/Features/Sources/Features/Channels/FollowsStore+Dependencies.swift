import Foundation
import Accounts
import TwitchKit

extension FollowsStore {

    /// Everything `FollowsStore` asks of the outside world: three Helix
    /// calls, the roster's disk cache and the clock. Production builds it
    /// from the `AccountStore` each public method is handed (see `live`);
    /// tests inject calls they can suspend, fail and count, so the store's
    /// ordering rules run without a network or an `AccountStore`.
    ///
    /// Every call names the account it is for, as the store's own entry
    /// points do.
    struct Dependencies: Sendable {
        /// One page of `/channels/followed`, after `cursor`.
        var followedChannelsPage: @Sendable (_ accountUserId: String, _ cursor: String?) async throws -> HelixPage<FollowedChannel>
        /// One page of `/streams/followed`, after `cursor`.
        var followedStreamsPage: @Sendable (_ accountUserId: String, _ cursor: String?) async throws -> HelixPage<TwitchStream>
        /// `/users` for up to 100 ids.
        var users: @Sendable (_ accountUserId: String, _ ids: [String]) async throws -> [TwitchUser]
        /// The roster saved for the account, or nil on any miss.
        var loadRoster: @Sendable (_ accountUserId: String) async -> FollowsRoster?
        /// Best-effort write of the account's roster.
        var saveRoster: @Sendable (_ accountUserId: String, _ roster: FollowsRoster) async -> Void
        /// Monotonic time, for the live throttle and the page-commit pacing.
        var now: @Sendable () -> ContinuousClock.Instant = { .now }
    }
}

extension FollowsStore.Dependencies {

    /// Helix through `accountStore` (each call retried once after a token
    /// refresh) and the roster cache on disk.
    static func live(
        accountStore: AccountStore,
        rosterCache: FollowsRosterCache = .shared
    ) -> FollowsStore.Dependencies {
        FollowsStore.Dependencies(
            followedChannelsPage: { accountUserId, cursor in
                let client = await accountStore.client(forUserId: accountUserId)
                return try await accountStore.withTokenRefresh(forUserId: accountUserId) {
                    try await client.api.fetchFollowedChannelsPage(
                        forUserID: accountUserId,
                        broadcasterID: nil,
                        first: 100,
                        after: cursor
                    )
                }
            },
            followedStreamsPage: { accountUserId, cursor in
                let client = await accountStore.client(forUserId: accountUserId)
                return try await accountStore.withTokenRefresh(forUserId: accountUserId) {
                    try await client.api.fetchFollowedStreamsPage(
                        userID: accountUserId,
                        first: 100,
                        after: cursor
                    )
                }
            },
            users: { accountUserId, ids in
                let client = await accountStore.client(forUserId: accountUserId)
                return try await accountStore.withTokenRefresh(forUserId: accountUserId) {
                    try await client.api.fetchUsers(ids: ids)
                }
            },
            loadRoster: { accountUserId in
                await rosterCache.load(forAccountUserId: accountUserId)
            },
            saveRoster: { accountUserId, roster in
                await rosterCache.save(roster, forAccountUserId: accountUserId)
            }
        )
    }
}
