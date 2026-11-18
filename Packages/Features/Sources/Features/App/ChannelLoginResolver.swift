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
    static func resolve(
        login: String,
        account: Account,
        accountStore: AccountStore
    ) async throws -> ChannelDescriptor {
        let client = accountStore.client(for: account)
        let user = try await accountStore.withTokenRefresh(for: account) { [login] in
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
