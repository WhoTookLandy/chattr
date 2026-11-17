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
///
/// Token writes and lifecycle changes for one account are serialized on
/// that account's `AccountTokenGate`, so an old client's admitted write can
/// never land after a re-authorization's new credential.
@MainActor
final class TwitchClientCache {
    /// A client plus the lifecycle its interceptor and token store check.
    struct Entry {
        let client: TwitchClient
        let lifecycle: TwitchClientLifecycle
        /// The unguarded store under the client's `LifecycleGuardedTokenStore`.
        /// Only `replaceClient` writes it directly, while holding the gate.
        let tokenStore: any TwitchTokenStore
    }

    /// Public Twitch client id every client is built with.
    let clientId: String
    private let sessionActivity: SessionActivitySignal
    private var entries: [String: Entry] = [:]
    private var gates: [String: AccountTokenGate] = [:]

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

    /// Builds a fresh Keychain-backed client WITHOUT caching it.
    /// `replaceClient` seeds its token first and only then caches it, so a
    /// failed write never leaves a half-initialized client in the cache.
    func makeClient(forUserId userId: String) -> Entry {
        // Capture the Sendable signal (NOT `self`, which is non-Sendable
        // @MainActor) so the @Sendable isLive closure stays isolation-clean.
        let signal = sessionActivity
        let namespace = Self.namespace(for: userId)
        let lifecycle = TwitchClientLifecycle()
        let baseStore = tokenStoreFactory?(namespace) ?? KeychainTokenStore(clientId: clientId, namespace: namespace)
        let tokenStore = LifecycleGuardedTokenStore(
            base: baseStore,
            lifecycle: lifecycle,
            gate: tokenGate(forUserId: userId)
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
        return Entry(client: client, lifecycle: lifecycle, tokenStore: baseStore)
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

    /// Re-authorization: retires `userId`'s current client, writes `token`
    /// and caches a fresh client for it, all in one critical section on the
    /// account's `AccountTokenGate`. Every save or delete the old client was
    /// admitted for has finished before `token` is written, and any it
    /// attempts later is dropped, so nothing it does can overwrite or delete
    /// the new credential.
    ///
    /// The token goes straight to the new client's base store (the gate is
    /// already held, and it isn't reentrant). Its TwitchKit provider loads
    /// it on first use. If the write throws, nothing is cached for `userId`
    /// and the next `client(forUserId:)` builds a fresh client.
    func replaceClient(forUserId userId: String, seededWith token: OAuthToken) async throws -> Entry {
        let replacement = makeClient(forUserId: userId)
        try await tokenGate(forUserId: userId).withLock {
            // The old client stays cached (retired) during the write, so
            // nothing builds another active client in the meantime.
            entries[userId]?.lifecycle.retire()
            do {
                try await replacement.tokenStore.saveToken(token)
            } catch {
                entries.removeValue(forKey: userId)?.lifecycle.retire()
                replacement.lifecycle.retire()
                throw error
            }
            // A client built while the write was in flight (only possible
            // when the account had none cached) is replaced too.
            entries[userId]?.lifecycle.retire()
            entries[userId] = replacement
        }
        return replacement
    }

    /// Deliberately signs `userId`'s client out: TwitchKit's `logout()`
    /// clears its in-memory token and deletes the stored one. This is the
    /// only delete the guarded store lets through. The client stays cached;
    /// callers `evict` afterwards.
    func logOut(userId: String) async throws {
        let entry = entry(forUserId: userId)
        // Under the gate, so a save admitted while the client was active
        // finishes first and the delete below comes after it.
        await tokenGate(forUserId: userId).withLock {
            entry.lifecycle.beginSignOut()
        }
        try await entry.client.auth.logout()
    }

    /// Drops and retires `userId`'s cached client (sign-out, removal). The
    /// next `client(forUserId:)` builds a fresh one. Retiring waits for any
    /// write the client was already admitted for.
    func evict(userId: String) async {
        guard let old = entries.removeValue(forKey: userId) else { return }
        await tokenGate(forUserId: userId).withLock {
            old.lifecycle.retire()
        }
    }

    /// The account's token gate, shared by every client built for it.
    /// Never removed: one small object per account seen this launch.
    func tokenGate(forUserId userId: String) -> AccountTokenGate {
        if let gate = gates[userId] { return gate }
        let gate = AccountTokenGate()
        gates[userId] = gate
        return gate
    }
}
