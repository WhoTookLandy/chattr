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
///
/// Every client also sends its HTTP through a `TwitchKitRefreshInterceptor`,
/// so TwitchKit's own 401 refresh goes through the chattr-auth bridge
/// (via `refreshHandler`) instead of Twitch's token endpoint. Without it,
/// TwitchKit's refresh always fails (no client secret in the app) and it
/// deletes the account's token as it gives up.
@MainActor
final class TwitchClientCache {
    /// Public Twitch client id every client is built with.
    let clientId: String
    private let sessionActivity: SessionActivitySignal
    private var clients: [String: TwitchClient] = [:]

    /// The transport under the interceptor. `URLSessionHTTPClient` in
    /// production; tests swap in a stub.
    private let transport: any HTTPClient

    /// Builds the token store for a namespace. `nil` means the Keychain
    /// store TwitchKit would build itself for that namespace (same Keychain
    /// key, so existing sign-ins carry over). Tests inject in-memory stores
    /// because a plain SwiftPM test bundle has no Keychain access.
    private let tokenStoreFactory: (@Sendable (_ namespace: String) -> any TwitchTokenStore)?

    /// Answers a refresh TwitchKit started for `userId`. `AccountStore` sets
    /// this to its bridge refresh. While it's unset, refreshes answer
    /// `.unavailable`, which never deletes anything.
    var refreshHandler: (@MainActor (_ userId: String) async -> TwitchKitRefreshAnswer)?

    init(
        clientId: String,
        sessionActivity: SessionActivitySignal,
        transport: any HTTPClient = URLSessionHTTPClient(),
        tokenStoreFactory: (@Sendable (_ namespace: String) -> any TwitchTokenStore)? = nil
    ) {
        self.clientId = clientId
        self.sessionActivity = sessionActivity
        self.transport = transport
        self.tokenStoreFactory = tokenStoreFactory
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
        let namespace = Self.namespace(for: userId)
        let tokenStore: any TwitchTokenStore = tokenStoreFactory?(namespace)
            ?? KeychainTokenStore(clientId: clientId, namespace: namespace)
        // Weak: the cache owns the clients, so a strong capture would be a
        // cycle. A refresh that outlives the cache answers `.unavailable`.
        let http = TwitchKitRefreshInterceptor(
            base: transport,
            tokenStore: tokenStore,
            refresh: { [weak self] in
                guard let self else { return .unavailable }
                return await self.answerRefresh(userId: userId)
            }
        )
        return TwitchClient(
            clientId: clientId,
            tokenStore: tokenStore,
            httpClient: http,
            isLive: { signal.hasActiveSessions }
        )
    }

    /// A throwaway client over an in-memory token store — used to call
    /// `/users` and learn who a fresh token belongs to without writing
    /// anything to the Keychain until the userId is known.
    ///
    /// It still gets the interceptor, so TwitchKit never calls Twitch's
    /// token endpoint from here either. With no account yet there is nothing
    /// to refresh through the bridge, so a refresh answers `.unavailable`
    /// and the probe call fails with `.unauthorized`.
    func makeProbeClient() -> TwitchClient {
        let tokenStore = InMemoryTokenStore()
        let http = TwitchKitRefreshInterceptor(
            base: transport,
            tokenStore: tokenStore,
            refresh: { .unavailable }
        )
        return TwitchClient(clientId: clientId, tokenStore: tokenStore, httpClient: http)
    }

    private func answerRefresh(userId: String) async -> TwitchKitRefreshAnswer {
        guard let refreshHandler else { return .unavailable }
        return await refreshHandler(userId)
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
