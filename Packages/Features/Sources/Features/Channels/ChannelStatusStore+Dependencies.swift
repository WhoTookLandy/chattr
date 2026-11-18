import Foundation
import Accounts
import TwitchKit

extension ChannelStatusStore {

    /// The Helix calls `ChannelStatusStore` makes, and the wall clock its
    /// staleness windows run on. Production builds it from the
    /// `AccountStore` each public method is handed (see `live`); tests
    /// inject calls they can suspend and count.
    ///
    /// Every call names the account it runs as.
    struct Dependencies: Sendable {
        /// `/streams` for up to 100 channel ids: the ones that are live.
        var streamsPage: @Sendable (_ accountUserId: String, _ channelIds: [String]) async throws -> HelixPage<TwitchStream>
        /// `/channels` for up to 100 channel ids.
        var channelsInfo: @Sendable (_ accountUserId: String, _ channelIds: [String]) async throws -> [TwitchChannel]
        /// The channel's most recent archived broadcast (`/videos`), if any.
        var latestArchivePage: @Sendable (_ accountUserId: String, _ channelId: String) async throws -> HelixPage<TwitchVideo>
        var now: @Sendable () -> Date = { Date() }
    }
}

extension ChannelStatusStore.Dependencies {

    /// Helix through `accountStore`, each call retried once after a token
    /// refresh.
    static func live(accountStore: AccountStore) -> ChannelStatusStore.Dependencies {
        ChannelStatusStore.Dependencies(
            streamsPage: { accountUserId, channelIds in
                let client = await accountStore.client(forUserId: accountUserId)
                return try await accountStore.withTokenRefresh(forUserId: accountUserId) {
                    try await client.api.fetchStreamsPage(userIDs: channelIds, first: 100)
                }
            },
            channelsInfo: { accountUserId, channelIds in
                let client = await accountStore.client(forUserId: accountUserId)
                return try await accountStore.withTokenRefresh(forUserId: accountUserId) {
                    try await client.api.fetchChannelsInfo(forBroadcasterIDs: channelIds)
                }
            },
            latestArchivePage: { accountUserId, channelId in
                let client = await accountStore.client(forUserId: accountUserId)
                return try await accountStore.withTokenRefresh(forUserId: accountUserId) {
                    try await client.api.fetchVideosPage(userID: channelId, type: "archive", first: 1)
                }
            }
        )
    }
}
