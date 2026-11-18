import Channels

/// What `TabSessionCoordinator` needs from the session registry: the
/// acquire / release refcounting that follows a chat tab's lifetime, and the
/// account-wide sweep when a shell goes away. A protocol so tests can drive
/// the coordinator against a fake; production is `ChannelSessionRegistry`.
@MainActor
protocol TabSessionRegistry: AnyObject, Sendable {
    func acquire(
        accountUserId: String,
        accountLogin: String,
        channelId: String,
        channelLoginName: String
    ) async throws -> ChannelSession

    func existingSession(accountUserId: String, channelId: String) -> ChannelSession?

    func release(accountUserId: String, channelId: String) async

    func releaseUnowned(accountUserId: String, channelId: String) async

    func releaseAll(forAccountUserId accountUserId: String) async
}

extension ChannelSessionRegistry: TabSessionRegistry {}
