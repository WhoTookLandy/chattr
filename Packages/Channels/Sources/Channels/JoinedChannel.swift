import Foundation
import SwiftData

/// A Twitch channel a user is currently sitting in chat for.
///
/// One row per (account, channel) pair. Rows persist across launches so we can
/// restore the user's chat tabs on cold start.
///
/// Note: composite uniqueness on (accountUserId, channelId) is not enforced at the
/// schema level (SwiftData's `@Attribute(.unique)` only does single columns). The
/// invariant is maintained at the application layer by `ChannelSessionRegistry`
/// (Task 17), which keys its session cache on the pair and never creates duplicates.
@Model
public final class JoinedChannel {
    /// Twitch broadcaster_user_id.
    public var channelId: String

    /// userId of the Account this join is scoped to (which identity we're chatting *as*).
    public var accountUserId: String

    /// Twitch login of the broadcaster (e.g. "xqc").
    public var loginName: String

    /// Twitch display name of the broadcaster (e.g. "xQc").
    public var displayName: String

    /// When the user joined this channel.
    public var joinedAt: Date

    public init(channelId: String, accountUserId: String, loginName: String, displayName: String, joinedAt: Date = .now) {
        self.channelId = channelId
        self.accountUserId = accountUserId
        self.loginName = loginName
        self.displayName = displayName
        self.joinedAt = joinedAt
    }
}
