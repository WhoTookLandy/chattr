import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.LifecycleGuardedTokenStore")

/// The token store every chattr-built `TwitchClient` gets. It passes reads
/// through and lets writes through only when the client's
/// `TwitchClientLifecycle` allows them (see the table there):
///
/// - Saves only while the client is `.active`, so a refresh that settles
///   after the account was removed or re-authorized can't put a stale
///   credential back.
/// - Deletes only while chattr is deliberately signing the client out
///   (`.signingOut`). TwitchKit 0.3.4 calls `logout()` on every failed
///   refresh, whatever the reason; those deletes are dropped, so a transient
///   failure can never wipe a credential. A dead refresh token still signs
///   the account out: `AccountStore.forceSignOut` deletes the token itself.
///
/// Dropped writes don't throw: TwitchKit treats a throwing store as one more
/// refresh failure and calls `logout()` again.
struct LifecycleGuardedTokenStore: TwitchTokenStore {
    let base: any TwitchTokenStore
    let lifecycle: TwitchClientLifecycle

    func loadToken() async throws -> OAuthToken? {
        try await base.loadToken()
    }

    func saveToken(_ token: OAuthToken) async throws {
        guard lifecycle.isActive else {
            logger.notice("Dropped a token save from a client that is no longer the account's client")
            return
        }
        try await base.saveToken(token)
    }

    func deleteToken() async throws {
        guard lifecycle.current == .signingOut else {
            logger.notice("Dropped a token delete chattr didn't ask for (TwitchKit gave up on a refresh)")
            return
        }
        try await base.deleteToken()
    }
}
