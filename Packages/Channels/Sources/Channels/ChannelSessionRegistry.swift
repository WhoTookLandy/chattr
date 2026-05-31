import Foundation
import Accounts
import EmoteSources
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Registry")

/// Owns active `ChannelSession` instances and dispatches EventSub events to
/// them. Keys by (accountUserId, channelId).
///
/// ## Why centralized event dispatch
///
/// `TwitchClient.eventSub.events` is a single-consumer `AsyncStream`. If every
/// `ChannelSession` started its own `for await event in client.eventSub.events`
/// loop, the events would get split unpredictably across iterators — each
/// session would filter `broadcasterUserId == channelId` and drop the rest,
/// so with N open channels each one would silently lose ~(N-1)/N of its own
/// messages. To make multi-channel chat work, the registry holds ONE shared
/// iterator per client and routes each event to the session whose channel ID
/// matches the event's broadcaster.
///
/// ## Why coalesce concurrent calls
///
/// `session(...)` is `@MainActor`-isolated but contains a suspension point at
/// `try await session.start()`. Without coalescing, two concurrent callers
/// (e.g. rapid tap-then-tap on Follows) for the same key would both see an
/// empty cache, both create new `ChannelSession` objects, and both subscribe
/// to the same EventSub topic. The `inFlight` map ensures only one creation
/// runs per key — subsequent callers await the same Task.
///
/// Isolation: `@MainActor` rather than `actor`. The registry receives `Account`
/// instances (non-Sendable `@Model` classes) as parameters from `@MainActor`
/// SwiftUI views — an `actor` boundary here would require those `Account`s to
/// be `Sendable`, which they aren't. `@MainActor` keeps them inside their
/// native isolation domain. The contained `ChannelSession` instances are
/// themselves `actor`s; their internal work happens off-main and the registry
/// only stores/dispenses them and hops to call `handle(event:)`.
@MainActor
public final class ChannelSessionRegistry {
    private let accountStore: AccountStore

    /// Active sessions, keyed by composite "accountUserId/channelId".
    ///
    /// A key appears here only AFTER `session.start()` succeeds — this map is
    /// both the fast-path cache and the "ready to hand to a tab" set. Keeping
    /// it post-start is what guarantees no tab can `subscribe(_:)` to a session
    /// mid-startup (the "expose-late" half of option 2's backfill buffering).
    private var sessions: [String: ChannelSession] = [:]

    /// Event-routing targets, keyed the same way as `sessions`. A session is
    /// registered here BEFORE `start()` runs, so the shared dispatcher can
    /// deliver live events to `handle(event:)` (which buffers them) during the
    /// subscribe + backfill window. Without this, `dispatch(event:)` would drop
    /// those events because the session isn't in `sessions` yet.
    ///
    /// Distinct from `sessions` on purpose: routing must begin early, but
    /// exposure (fast-path + coalescing result) must stay late. Conflating them
    /// would let a concurrent caller grab a not-yet-started session. Cleared on
    /// teardown and on failed start.
    private var dispatchTargets: [String: ChannelSession] = [:]

    /// In-flight session-construction Tasks, keyed the same way as `sessions`.
    /// Two views opening the same channel concurrently each see no entry in
    /// `sessions` (because the first caller's `start()` hasn't returned yet),
    /// and without coalescing they would both construct a session and both
    /// call `start()` — the second `subscribe` then races Twitch's "already
    /// subscribed" rejection. Storing the in-flight Task here lets the second
    /// caller await the first's result instead.
    private var inFlight: [String: Task<ChannelSession, Error>] = [:]

    /// Shared event-dispatcher Tasks, one per accountUserId. Each owns the
    /// single iterator on its account's `client.eventSub.events` stream and
    /// routes each event to the matching session via `handle(event:)`.
    /// Started lazily on first session creation for an account.
    private var eventDispatchTasks: [String: Task<Void, Never>] = [:]

    /// Per-account connection-state mirrors, keyed by `accountUserId`. One per
    /// account because the EventSub socket is per account.
    private var connectionStatusStores: [String: ConnectionStatusStore] = [:]

    /// Per-account tasks consuming `client.eventSub.connectionState`. Started
    /// alongside the event dispatcher; cancelled in `stopDispatcherIfIdle`.
    private var connectionDispatchTasks: [String: Task<Void, Never>] = [:]

    /// Reference counts per session key. Each `acquire(...)` increments;
    /// each `release(...)` decrements. When a count hits 0, the underlying
    /// `ChannelSession` is stopped and removed.
    ///
    /// The refcount tracks *intent to keep alive* — typically one increment
    /// per `ChatTab` that contains the channel. It is intentionally
    /// independent from `session(...)` (which is a pure lookup-or-create and
    /// doesn't affect lifecycle), so view code that needs the session for
    /// rendering can call `session(...)` repeatedly without inflating the
    /// count.
    private var refCounts: [String: Int] = [:]

    // MARK: - Per-channel view stores (T11)
    //
    // EmoteIndex and ChatBadgeStore live HERE (registry-owned) instead of as
    // `@State` on `ChatScreen`. The reason: ChatScreen is in a paged
    // LazyHStack inside ChatTabsScreen — when the user swipes off-screen,
    // the ChatScreen unmounts and its `@State` properties (and any in-flight
    // loads / cached data inside them) die. Re-mounting the screen would
    // re-fetch the 6 emote-provider HTTPS calls + 2 Helix-badge calls,
    // every time.
    //
    // Putting these stores on the registry — which has the same lifetime
    // as the `ChannelSession` (created on acquire, destroyed on the last
    // release) — means:
    //   - Multiple ChatScreen mounts for the same channel SHARE the same
    //     loaded store. Re-mount cost drops from "6 HTTPS calls" to "0."
    //   - When the user finally closes the channel tab (refcount hits 0),
    //     all per-channel state goes away together — no memory leak.
    //   - Re-opening the same channel later starts fresh (correct).
    //
    // Loads themselves are now idempotent (see EmoteIndex.load,
    // ChatBadgeStore.load) — multiple callers asking for "load this
    // channel" trigger network work only once.

    private var emoteIndexes: [String: EmoteIndex] = [:]
    private var badgeStores: [String: ChatBadgeStore] = [:]

    public init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    /// Returns (creating if needed) the session for the given account × channel
    /// pair. The session is `start()`ed automatically on first access, and the
    /// shared event-dispatcher for the account's client is started lazily on
    /// the same path. Concurrent callers for the same key share a single
    /// construction Task.
    ///
    /// **Signature uses `accountUserId`/`accountLogin` strings, not `Account`.**
    /// The original API took the SwiftData `@Model` Account directly, which
    /// forced strong captures of a non-Sendable type in long-stored
    /// closures (e.g. `ChatTabsModel.onOpen` on AppShell). String-only
    /// inputs let those closures capture stable values instead — see
    /// `AppShell.onOpen` for the call site.
    public func session(
        accountUserId: String,
        accountLogin: String,
        channelId: String,
        channelLoginName: String
    ) async throws -> ChannelSession {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)

        // Fast path — already created.
        if let existing = sessions[key] {
            return existing
        }
        // Slow path with a peer already mid-creation — share its result.
        if let pending = inFlight[key] {
            return try await pending.value
        }

        // `client(forUserId:)` reconstructs the tokenNamespace from userId
        // — stable across launches, identical to what `client(for: account)`
        // would have produced.
        let client = accountStore.client(forUserId: accountUserId)
        let session = ChannelSession(
            client: client,
            channelId: channelId,
            channelLoginName: channelLoginName,
            accountUserId: accountUserId,
            refreshTokenHandler: { [weak accountStore] in
                guard let accountStore else { throw AppError(message: "AccountStore deallocated during refresh") }
                try await accountStore.refreshTokens(userId: accountUserId, login: accountLogin)
            }
        )

        // Register for event routing + ensure the shared dispatcher is live
        // BEFORE start(), so live events arriving during subscribe/backfill are
        // delivered to handle() (which buffers them) instead of being dropped.
        // `sessions[key]` stays unset until start() succeeds, so this does NOT
        // expose the session to the fast path or to subscribers yet.
        // Idempotent: ensureEventDispatch spins up at most one Task per account.
        dispatchTargets[key] = session
        ensureEventDispatch(client: client, accountUserId: accountUserId)

        let task = Task<ChannelSession, Error> { [session] in
            try await session.start()
            return session
        }
        inFlight[key] = task
        do {
            let started = try await task.value
            sessions[key] = started
            inFlight[key] = nil
            // .notice: session creation is a boundary event — when this fires
            // we just opened a new WebSocket subscription to Twitch.
            logger.notice("Created session for @\(accountLogin, privacy: .public)/#\(channelLoginName, privacy: .public)")
            return started
        } catch {
            inFlight[key] = nil
            // Failed start: stop routing to this session and tear down the
            // dispatcher if it now has nothing to serve (it may have been
            // started just above for this very session).
            dispatchTargets[key] = nil
            stopDispatcherIfIdle(accountUserId: accountUserId)
            throw error
        }
    }

    // MARK: - Reference counting

    /// Increment the reference count for a session and construct it if not
    /// yet alive. Use this at the boundaries where a session's *lifetime*
    /// changes — typically when a `ChatTab` opens. Pair with `release(...)`
    /// when that tab closes.
    ///
    /// Returns the live session so the caller can begin using it
    /// immediately. Multiple acquires for the same key share the same
    /// session object (deduplicated via the existing `session(...)` cache
    /// + in-flight coalescing).
    ///
    /// Idempotency: each call adds exactly 1 to the refcount. A tab that
    /// holds the same channel twice (degenerate but legal) increments
    /// twice and must release twice.
    @discardableResult
    public func acquire(
        accountUserId: String,
        accountLogin: String,
        channelId: String,
        channelLoginName: String
    ) async throws -> ChannelSession {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        refCounts[key, default: 0] += 1
        // Mark the account "live" so its EventSub client reconnects aggressively
        // while this channel is open. Balanced by the decrement in release()
        // (and the rollback below if construction fails).
        accountStore.sessionActivity.increment()
        // .debug: refcount churn is per-tab-open/close — visible in DevLogView
        // only when investigating session lifecycle issues, otherwise hidden.
        logger.debug("acquire \(key, privacy: .public) → refcount \(self.refCounts[key] ?? 0)")
        // Delegate construction to the existing session(...) path. If
        // construction fails, roll the refcount back so a future caller
        // can retry from a clean state — otherwise an orphan refcount
        // would block teardown forever.
        do {
            return try await session(
                accountUserId: accountUserId,
                accountLogin: accountLogin,
                channelId: channelId,
                channelLoginName: channelLoginName
            )
        } catch {
            refCounts[key, default: 1] -= 1
            if refCounts[key] == 0 { refCounts[key] = nil }
            // Roll back the activity increment from the top so a failed acquire
            // doesn't leave the account permanently "live".
            accountStore.sessionActivity.decrement()
            throw error
        }
    }

    /// Decrement the reference count for a session. When the count reaches
    /// zero the session is stopped (EventSub unsubscribe, dispatcher task
    /// continues running for the account but skips this channel) and
    /// removed from the cache.
    ///
    /// Safe to call when no session exists (e.g., release races a failed
    /// acquire) — it just clears any leftover refcount entry.
    public func release(accountUserId: String, channelId: String) async {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        guard let count = refCounts[key], count > 0 else {
            // .warning: double-release is a programming smell. We tolerate
            // it (idempotent), but surface it visibly so it's spotted.
            logger.warning("release \(key, privacy: .public) with no outstanding refcount — likely a double-release; ignoring")
            return
        }
        refCounts[key] = count - 1
        // Balance the increment from acquire(). The early-return guard above
        // (no outstanding refcount) intentionally does NOT decrement — that
        // release has no matching acquire.
        accountStore.sessionActivity.decrement()

        if refCounts[key] == 0 {
            refCounts[key] = nil
            // Cancel any in-flight construction — if a peer is still
            // awaiting acquire's session(...) call, their await throws
            // CancellationError. ChatScreen already absorbs that
            // silently.
            if let task = inFlight[key] {
                task.cancel()
                inFlight[key] = nil
            }
            // Stop routing events to this session regardless of whether it
            // finished starting (it may still be in `dispatchTargets` but not
            // yet in `sessions` if release races a slow start).
            dispatchTargets[key] = nil
            if let session = sessions[key] {
                await session.stop()
                sessions[key] = nil
                // .notice: session teardown is a boundary event — counterpart
                // to the "Created session" notice above.
                logger.notice("release \(key, privacy: .public) → refcount 0; session stopped")
            } else {
                // .debug: rare path (acquire raced release before session()
                // returned). Useful when investigating race conditions but
                // not interesting day-to-day.
                logger.debug("release \(key, privacy: .public) → refcount 0; no session to stop (still constructing or already gone)")
            }
            // T11: per-channel view stores share the session's lifetime.
            // Drop them here so the next acquire for the same channel starts
            // fresh — emote provider catalogs and channel badges might have
            // changed between sessions (broadcaster added a new 7TV emote,
            // promoted a subscriber tier, etc.). Holding stale stores would
            // also waste memory across closed-then-reopened tabs.
            emoteIndexes[key] = nil
            badgeStores[key] = nil
            // After tearing down the session, check if THIS account has
            // any remaining sessions. If not, cancel the shared event
            // dispatcher Task — otherwise the WebSocket stays connected
            // forever (the Task's `for await event in client.eventSub.events`
            // keeps the stream alive even after all sessions are gone).
            //
            // Without this, closing all chat tabs leaves an idle WebSocket
            // consuming socket resources + occasional Twitch heartbeat
            // traffic for the rest of the app's foreground lifetime.
            stopDispatcherIfIdle(accountUserId: accountUserId)
        } else {
            // .debug: refcount decrement when not the last reference.
            // Pairs with the .debug "acquire" log on the opposite side.
            logger.debug("release \(key, privacy: .public) → refcount \(self.refCounts[key] ?? 0)")
        }
    }

    /// Legacy single-owner teardown. Kept as a thin alias for `release(...)`
    /// so call sites that haven't migrated to acquire/release still compile.
    ///
    /// Behavior under refcount semantics: this drops the refcount by 1 just
    /// like `release(...)`. Callers that previously expected unconditional
    /// teardown should migrate to acquire/release pairs.
    @available(*, deprecated, renamed: "release(accountUserId:channelId:)", message: "Use the acquire/release pair for proper reference counting.")
    public func leave(accountUserId: String, channelId: String) async {
        await release(accountUserId: accountUserId, channelId: channelId)
    }

    // MARK: - Per-channel view stores (T11)

    /// Returns the shared `EmoteIndex` for this account × channel pair, creating
    /// it on first access. Survives `ChatScreen` unmount/remount as long as the
    /// registry's refcount for the channel stays > 0 — i.e. as long as any
    /// `ChatTab` is keeping the channel alive.
    ///
    /// Idempotency: returns the same instance for repeated calls with the same
    /// key. Callers can then call `load(...)` on it freely; `EmoteIndex.load`
    /// short-circuits when it's already loaded for the given broadcaster.
    ///
    /// Lifetime: cleaned up automatically in `release(...)` when refcount hits
    /// zero, alongside the underlying `ChannelSession`.
    public func emoteIndex(forAccountUserId accountUserId: String, channelId: String) -> EmoteIndex {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let existing = emoteIndexes[key] {
            return existing
        }
        let new = EmoteIndex()
        emoteIndexes[key] = new
        return new
    }

    /// Returns the shared `ChatBadgeStore` for this account × channel pair,
    /// creating it on first access. Same lifetime semantics as `emoteIndex(...)`.
    ///
    /// `ChatBadgeStore.load(...)` is also idempotent — second-mount cost for the
    /// same channel is a no-op rather than two Helix calls.
    public func badgeStore(forAccountUserId accountUserId: String, channelId: String) -> ChatBadgeStore {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let existing = badgeStores[key] {
            return existing
        }
        let new = ChatBadgeStore()
        badgeStores[key] = new
        return new
    }

    /// Returns (creating if needed) the per-account connection-state store. A
    /// `ChatScreen` observes this to drive its "Reconnecting… / Live again"
    /// pill. Same lifetime as the account's event dispatcher.
    public func connectionStatus(forAccountUserId accountUserId: String) -> ConnectionStatusStore {
        if let existing = connectionStatusStores[accountUserId] {
            return existing
        }
        let new = ConnectionStatusStore()
        connectionStatusStores[accountUserId] = new
        return new
    }

    // MARK: - Event dispatch

    /// Cancel + remove the shared event dispatcher Task for an account if
    /// it has no remaining sessions. The dispatcher's `for await event in
    /// client.eventSub.events` keeps the WebSocket alive — without
    /// cancelling, closing all chat tabs would leave an idle connection.
    ///
    /// Idempotent: calling when there's no dispatcher (or sessions still
    /// exist) is a no-op.
    ///
    /// Implementation note: `sessions` is keyed by "userId/channelId", so
    /// "any session for this account" is detected by a key prefix scan.
    /// O(N) over total sessions, but N is tiny (~tabs the user has open).
    private func stopDispatcherIfIdle(accountUserId: String) {
        let prefix = "\(accountUserId)/"
        // Consider both started sessions AND in-flight routing targets — a
        // session mid-start still needs the dispatcher to deliver (and buffer)
        // its live events, so it must keep the dispatcher alive.
        let hasActiveSessions =
            sessions.keys.contains { $0.hasPrefix(prefix) } ||
            dispatchTargets.keys.contains { $0.hasPrefix(prefix) }
        guard !hasActiveSessions else { return }
        guard let task = eventDispatchTasks[accountUserId] else { return }
        task.cancel()
        eventDispatchTasks[accountUserId] = nil
        // Tear down the connection-state pump + drop the store alongside the
        // event dispatcher — they share the account's lifetime.
        connectionDispatchTasks[accountUserId]?.cancel()
        connectionDispatchTasks[accountUserId] = nil
        connectionStatusStores[accountUserId] = nil
        logger.notice("Stopped event dispatcher for account \(accountUserId, privacy: .public) — no remaining sessions")
    }

    /// Starts the single event-dispatch loop for this account's client if it
    /// isn't already running. Subsequent calls for the same account are no-ops.
    private func ensureEventDispatch(client: TwitchClient, accountUserId: String) {
        guard eventDispatchTasks[accountUserId] == nil else { return }

        eventDispatchTasks[accountUserId] = Task { [weak self] in
            // ONE iterator on the client's event stream — that's the whole
            // point of this Task. All routing happens via `dispatch(event:)`.
            for await event in client.eventSub.events {
                guard let self else { return }
                guard !Task.isCancelled else { return }
                await self.dispatch(event: event, accountUserId: accountUserId)
            }
        }
        logger.info("Started event dispatcher for account \(accountUserId, privacy: .public)")

        // Per-account connection-state pump. Consumes the single-consumer
        // `connectionState` stream and mirrors it into the @Observable store the
        // ChatScreen reads. Started here (with the event dispatcher) so it begins
        // before connect() and observes the initial .connecting/.connected
        // transitions — the stream has no value replay for late subscribers. The
        // inner `== nil` guard keeps the block safe regardless of placement.
        if connectionDispatchTasks[accountUserId] == nil {
            let store = connectionStatus(forAccountUserId: accountUserId)
            connectionDispatchTasks[accountUserId] = Task { @MainActor in
                for await state in client.eventSub.connectionState {
                    guard !Task.isCancelled else { return }
                    store.update(state)
                }
            }
        }
    }

    /// Routes a single event to the session whose `channelId` matches the
    /// event's broadcaster. Drops events for channels with no active session
    /// (briefly possible during close-X — event in flight while we tear down).
    private func dispatch(event: EventSubEvent, accountUserId: String) async {
        guard let broadcasterId = ChannelSession.broadcasterUserId(from: event) else {
            return
        }
        let key = Self.key(accountUserId: accountUserId, channelId: broadcasterId)
        // Route via `dispatchTargets`, not `sessions`: a session is routable
        // (registered here) from before `start()` runs, so events arriving
        // during the subscribe + backfill window reach `handle(event:)` and get
        // buffered rather than dropped.
        guard let session = dispatchTargets[key] else {
            return
        }
        await session.handle(event: event)
    }

    // MARK: - Helpers

    private static func key(accountUserId: String, channelId: String) -> String {
        "\(accountUserId)/\(channelId)"
    }
}
