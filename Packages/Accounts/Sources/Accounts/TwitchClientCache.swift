import Foundation
import TwitchKit
import Core

/// Per-account `TwitchClient` construction and in-memory cache, keyed by
/// `userId`.
///
/// Every client built here shares the app's `SessionActivitySignal` through
/// its `isLive` closure, so a client's EventSub reconnect stays aggressive
/// while any channel is open — no matter which path (Helix call, token
/// refresh, session start) happened to build it first.
@MainActor
final class TwitchClientCache {
    /// Public Twitch client id every client is built with.
    let clientId: String
    private let sessionActivity: SessionActivitySignal
    private var clients: [String: TwitchClient] = [:]

    init(clientId: String, sessionActivity: SessionActivitySignal) {
        self.clientId = clientId
        self.sessionActivity = sessionActivity
    }

    /// The canonical tokenNamespace string for a given Twitch userId.
    /// Stays stable across launches so Keychain entries persist.
    static func namespace(for userId: String) -> String {
        "chattr.account.\(userId)"
    }

    /// Returns the cached client for `userId`, constructing and caching a
    /// Keychain-backed one on first use. The namespace is derived from
    /// `userId`, so the token store finds the same Keychain entries across
    /// launches.
    func client(forUserId userId: String) -> TwitchClient {
        if let existing = clients[userId] {
            return existing
        }
        let client = makeClient(forUserId: userId)
        clients[userId] = client
        return client
    }

    /// Builds a fresh Keychain-backed client WITHOUT caching it. `add`
    /// seeds its token first and only then `install`s it, so a failed
    /// `setToken` never leaves a half-initialized client in the cache.
    func makeClient(forUserId userId: String) -> TwitchClient {
        // Capture the Sendable signal (NOT `self`, which is non-Sendable
        // @MainActor) so the @Sendable isLive closure stays isolation-clean.
        let signal = sessionActivity
        return TwitchClient(
            clientId: clientId,
            tokenNamespace: Self.namespace(for: userId),
            isLive: { signal.hasActiveSessions }
        )
    }

    /// A throwaway client over an in-memory token store — used to call
    /// `/users` and learn who a fresh token belongs to without writing
    /// anything to the Keychain until the userId is known.
    func makeProbeClient() -> TwitchClient {
        TwitchClient(clientId: clientId, tokenStore: InMemoryTokenStore())
    }

    /// Caches `client` as `userId`'s client, replacing any existing one.
    func install(_ client: TwitchClient, forUserId userId: String) {
        clients[userId] = client
    }

    /// Drops `userId`'s cached client (sign-out / removal). The next
    /// `client(forUserId:)` builds a fresh one.
    func evict(userId: String) {
        clients[userId] = nil
    }
}
