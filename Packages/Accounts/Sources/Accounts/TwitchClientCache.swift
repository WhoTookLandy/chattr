import Foundation
import TwitchKit
import Core

/// Per-account `TwitchClient` construction and in-memory cache, keyed by
/// `userId`.
///
/// Every client built here shares the app's `SessionActivitySignal` through
/// its `isLive` closure, so a client's EventSub reconnect stays aggressive
/// while its own account has a channel open — no matter which path (Helix
/// call, token refresh, session start) happened to build it first.
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
/// Token writes, lifecycle changes, and every change to which client is
/// cached for an account are serialized on that account's
/// `AccountTokenGate`, so an old client's admitted write can never land
/// after a re-authorization's new credential, and a sign-out that started
/// before a re-authorization can't tear the new session down. The one
/// unguarded cache write is `entry(forUserId:)` filling an *empty* slot on
/// first use: it is on the request path (so it can't wait on the gate), and
/// it never displaces or retires a client.
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
    nonisolated static func namespace(for userId: String) -> String {
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

    /// Whether a client is cached for `userId` right now.
    func hasCachedClient(forUserId userId: String) -> Bool {
        entries[userId] != nil
    }

    /// Whether anything asked for `userId`'s client or token gate this
    /// launch, including a sign-in still writing its first token.
    func hasSeen(userId: String) -> Bool {
        gates[userId] != nil
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
        let providerLink = TokenProviderLink()
        let tokenStore = LifecycleGuardedTokenStore(
            base: baseStore,
            lifecycle: lifecycle,
            gate: tokenGate(forUserId: userId),
            providerLink: providerLink
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
            isLive: { signal.hasActiveSessions(forAccount: userId) }
        )
        providerLink.attach(client.auth.tokenProvider)
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
        let gate = tokenGate(forUserId: userId)
        try await gate.withLock {
            // The old client stays cached (retired) during the write, so
            // nothing builds another active client in the meantime.
            entries[userId]?.lifecycle.retire()
            // The new credential isn't ordered against the old client's
            // bridge-issued tokens.
            gate.resetFreshness()
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

    /// Whether `lifecycle` is still `userId`'s cached client and hasn't been
    /// retired. Callers that captured a client before suspending check this
    /// under the account's gate, to tell whether a re-authorization (or
    /// another sign-out) replaced it meanwhile.
    private func isCurrent(_ lifecycle: TwitchClientLifecycle, forUserId userId: String) -> Bool {
        entries[userId]?.lifecycle === lifecycle && lifecycle.current != .retired
    }

    /// Deliberately signs `entry`'s client out: TwitchKit's `logout()`
    /// clears its in-memory token and deletes the stored one. This is the
    /// only delete the guarded store lets through. The client stays cached;
    /// callers `evict` it afterwards.
    ///
    /// Returns `false` without touching anything when `entry` is no longer
    /// `userId`'s client (re-authorized or evicted since the caller captured
    /// it), so a sign-out never starts on the client that replaced it.
    @discardableResult
    func logOut(_ entry: Entry, userId: String) async throws -> Bool {
        // Under the gate, so a save admitted while the client was active
        // finishes first and the delete below comes after it.
        let signingOut = await tokenGate(forUserId: userId).withLock { () -> Bool in
            guard isCurrent(entry.lifecycle, forUserId: userId) else { return false }
            entry.lifecycle.beginSignOut()
            return true
        }
        guard signingOut else { return false }
        try await entry.client.auth.logout()
        return true
    }

    /// Drops and retires `userId`'s cached client if it is still the one
    /// with `lifecycle`, then runs `cleanup`, all in one critical section on
    /// the account's gate. Retiring waits for any write the client was
    /// already admitted for. The next `client(forUserId:)` builds a fresh
    /// client.
    ///
    /// Returns `false` (nothing evicted, `cleanup` not run) when the client
    /// was replaced or evicted since the caller captured it. Checking and
    /// removing under the gate means a re-authorization either finishes
    /// first (and this does nothing) or starts after (and finds the slot
    /// empty). Neither can leave the old client cached-out but still active.
    ///
    /// `cleanup` must be synchronous: it is how a sign-out drops the rest of
    /// the account's session state (refresh-token mirror, selection,
    /// `needsReauth`) atomically with the eviction.
    @discardableResult
    func evict(
        userId: String,
        ifCurrent lifecycle: TwitchClientLifecycle,
        cleanup: () -> Void = {}
    ) async -> Bool {
        let gate = tokenGate(forUserId: userId)
        return await gate.withLock { () -> Bool in
            guard isCurrent(lifecycle, forUserId: userId) else { return false }
            entries.removeValue(forKey: userId)
            lifecycle.retire()
            gate.resetFreshness()
            cleanup()
            return true
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
