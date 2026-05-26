import Foundation
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Registry")

/// Owns active `ChannelSession` instances. Keys by (accountUserId, channelId).
///
/// Isolation: `@MainActor` rather than `actor`. The registry receives `Account`
/// instances (non-Sendable `@Model` classes) as parameters from `@MainActor` SwiftUI
/// views — an `actor` boundary here would require those `Account`s to be `Sendable`,
/// which they aren't. `@MainActor` keeps them inside their native isolation domain.
/// The contained `ChannelSession` instances are themselves `actor`s; they operate
/// off-main, but the registry only stores and dispenses them (no cross-actor data
/// crosses the boundary).
@MainActor
public final class ChannelSessionRegistry {
    private let accountStore: AccountStore

    /// Active sessions, keyed by composite "accountUserId/channelId".
    private var sessions: [String: ChannelSession] = [:]

    public init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    /// Returns (creating if needed) the session for the given account × channel pair.
    /// The session is `start()`ed automatically on first access.
    public func session(account: Account, channelId: String, channelLoginName: String) async throws -> ChannelSession {
        let key = Self.key(accountUserId: account.userId, channelId: channelId)
        if let existing = sessions[key] {
            return existing
        }

        let client = accountStore.client(for: account)
        let session = ChannelSession(
            client: client,
            channelId: channelId,
            channelLoginName: channelLoginName,
            accountUserId: account.userId
        )
        try await session.start()
        sessions[key] = session
        logger.info("Created session for @\(account.login)/#\(channelLoginName)")
        return session
    }

    /// Stops and removes the session for the given pair.
    public func leave(accountUserId: String, channelId: String) async {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let session = sessions[key] {
            await session.stop()
            sessions[key] = nil
            logger.info("Left session \(key)")
        }
    }

    private static func key(accountUserId: String, channelId: String) -> String {
        "\(accountUserId)/\(channelId)"
    }
}
