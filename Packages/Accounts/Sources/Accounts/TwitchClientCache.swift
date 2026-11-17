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
///
/// Each client has a `TwitchClientLifecycle`, and its token store is wrapped
/// in a `LifecycleGuardedTokenStore`. A client stops being `.active` when it
/// is evicted or replaced, so a refresh still running on it can no longer
/// write the account's shared Keychain entry.
@MainActor
final class TwitchClientCache {
    /// A client plus the lifecycle its interceptor and token store check.
    struct Entry {
        let client: TwitchClient
        let lifecycle: TwitchClientLifecycle
    }

    /// Public Twitch client id every client is built with.
    let clientId: String
    private let sessionActivity: SessionActivitySignal
    private var entries: [String: Entry] = [:]

    /// The transport under the interceptor. `URLSessionHTTPClient` in
    /// production; tests swap in a stub.
    private let transport: any HTTPClient

    /// Builds the token store for a namespace. `nil` means the Keychain
    /// store TwitchKit would build itself for that namespace (same Keychain
    /// key, so existing sign-ins carry over). Tests inject in-memory stores
    /// because a plain SwiftPM test bundle has no Keychain access.
    private let tokenStoreFactory: (@Sendable (_ namespace: String) -> any TwitchTokenStore)?

    /// Answers a refresh TwitchKit started on the client with `lifecycle`
    /// for `userId`. `AccountStore` sets this to its bridge refresh. While
    /// it's unset, refreshes answer `.unavailable(current: nil)`, which
    /// never saves or deletes anything.
    var refreshHandler: (@MainActor (_ userId: String, _ lifecycle: TwitchClientLifecycle) async -> TwitchKitRefreshAnswer)?

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
        entry(forUserId: userId).client
    }

    /// `client(forUserId:)` plus its lifecycle.
    func entry(forUserId userId: String) -> Entry {
        if let existing = entries[userId] {
            return existing
        }
        let entry = makeClient(forUserId: userId)
        entries[userId] = entry
        return entry
    }

    /// The cached client for `userId` if `lifecycle` is still its live
    /// lifecycle, else `nil`. A refresh uses this to tell whether the
    /// client that asked is still the account's client.
    func activeClient(forUserId userId: String, lifecycle: TwitchClientLifecycle) -> TwitchClient? {
        guard let entry = entries[userId], entry.lifecycle === lifecycle, lifecycle.isActive else {
            return nil
        }
        return entry.client
    }

    /// Builds a fresh Keychain-backed client WITHOUT caching it. `add`
    /// seeds its token first and only then `install`s it, so a failed
    /// `setToken` never leaves a half-initialized client in the cache.
    func makeClient(forUserId userId: String) -> Entry {
        // Capture the Sendable signal (NOT `self`, which is non-Sendable
        // @MainActor) so the @Sendable isLive closure stays isolation-clean.
        let signal = sessionActivity
        let namespace = Self.namespace(for: userId)
        let lifecycle = TwitchClientLifecycle()
        let tokenStore = LifecycleGuardedTokenStore(
            base: tokenStoreFactory?(namespace) ?? KeychainTokenStore(clientId: clientId, namespace: namespace),
            lifecycle: lifecycle
        )
        // Weak: the cache owns the clients, so a strong capture would be a
        // cycle. A refresh that outlives the cache saves nothing.
        let http = TwitchKitRefreshInterceptor(
            base: transport,
            lifecycle: lifecycle,
            refresh: { [weak self] in
                guard let self else { return .unavailable(current: nil) }
                return await self.answerRefresh(userId: userId, lifecycle: lifecycle)
            }
        )
        let client = TwitchClient(
            clientId: clientId,
            tokenStore: tokenStore,
            httpClient: http,
            isLive: { signal.hasActiveSessions }
        )
        return Entry(client: client, lifecycle: lifecycle)
    }

    /// A throwaway client over an in-memory store seeded with `token`,
    /// used to call `/users` and learn who a fresh token belongs to without
    /// writing anything to the Keychain until the userId is known.
    ///
    /// It still gets the interceptor, so TwitchKit never calls Twitch's
    /// token endpoint from here either. With no account yet there is nothing
    /// to refresh through the bridge, so a refresh hands back `token`
    /// unchanged and the probe call fails with `.unauthorized`.
    func makeProbeClient(token: OAuthToken) -> TwitchClient {
        let tokenStore = InMemoryTokenStore(token: token)
        let http = TwitchKitRefreshInterceptor(
            base: transport,
            lifecycle: TwitchClientLifecycle(),
            refresh: { .unavailable(current: token) }
        )
        return TwitchClient(clientId: clientId, tokenStore: tokenStore, httpClient: http)
    }

    private func answerRefresh(userId: String, lifecycle: TwitchClientLifecycle) async -> TwitchKitRefreshAnswer {
        guard let refreshHandler else { return .unavailable(current: nil) }
        return await refreshHandler(userId, lifecycle)
    }

    /// Caches `entry` as `userId`'s client. A different client it replaces
    /// is retired.
    func install(_ entry: Entry, forUserId userId: String) {
        if let old = entries[userId], old.lifecycle !== entry.lifecycle {
            old.lifecycle.retire()
        }
        entries[userId] = entry
    }

    /// Deliberately signs `userId`'s client out: TwitchKit's `logout()`
    /// clears its in-memory token and deletes the stored one. This is the
    /// only delete the guarded store lets through. The client stays cached;
    /// callers `evict` afterwards.
    func logOut(userId: String) async throws {
        let entry = entry(forUserId: userId)
        entry.lifecycle.beginSignOut()
        try await entry.client.auth.logout()
    }

    /// Drops and retires `userId`'s cached client (sign-out, removal,
    /// re-authorization). The next `client(forUserId:)` builds a fresh one.
    func evict(userId: String) {
        entries.removeValue(forKey: userId)?.lifecycle.retire()
    }
}
