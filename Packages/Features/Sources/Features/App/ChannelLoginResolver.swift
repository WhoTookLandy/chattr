import Foundation
import Accounts
import Core
import TwitchKit

/// Resolves a Twitch login to its channel through Helix
/// `fetchUser(login:)`, the same lookup `AddChannelView` makes for a typed
/// channel name. Opening a chat needs the broadcaster id, which a link
/// (`chattr://open/channel/<login>`) doesn't carry.
@MainActor
enum ChannelLoginResolver {

    /// Throws what the Helix call throws (`HelixError.notFound` when no
    /// channel has that login).
    ///
    /// Takes the account's id rather than the `Account`: the lookup runs on
    /// a task that can outlive the row, and a deleted `@Model` must not be
    /// read.
    static func resolve(
        login: String,
        accountUserId: String,
        accountStore: AccountStore
    ) async throws -> ChannelDescriptor {
        let client = accountStore.client(forUserId: accountUserId)
        let user = try await accountStore.withTokenRefresh(forUserId: accountUserId) { [login] in
            try await client.api.fetchUser(login: login)
        }
        return ChannelDescriptor(
            platform: .twitch,
            channelId: user.id,
            channelLoginName: user.login,
            channelDisplayName: user.displayName,
            profileImageURL: URL(string: user.profileImageUrl)
        )
    }
}
