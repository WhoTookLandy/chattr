import Foundation
import Accounts
import ChatModel
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
/// That iterator runs in a detached task — never on the main actor — and
/// only hands each event to `ChannelEventRouter`, which drops it into the
/// owning session's own inbox without waiting. A slow channel (or a slow
/// subscriber of one) therefore can't hold up the socket's other channels,
/// and a busy main thread can't hold up the socket at all.
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
/// only stores/dispenses them and keeps the router's table in step with
/// their lifecycle. No event passes through the main actor on its way in.
///
/// ## Layout
///
/// This file holds the state and the session lifecycle (construction,
/// coalescing, acquire / release / releaseAll, teardown). Sibling files:
/// `ChannelSessionRegistry+Stores.swift` (per-channel emote indexes and badge
/// stores, connection-status stores, the moderated-channels cache) and
/// `ChannelSessionRegistry+EventDispatch.swift` (per-account dispatcher and
/// connection pump, reconnect resync, cold-start zombie cleanup). State those
/// files touch is `internal` rather than `private`; it's all main-actor
/// isolated.
@MainActor
public final class ChannelSessionRegistry {

    /// Everything the registry needs from outside to build, start and stop a
    /// session. Production wires it to `AccountStore` + the real
    /// `ChannelSession.start()` / `stop()` (see `init(accountStore:)`); tests
    /// inject controllable start/stop closures so the acquire/release races
    /// can be driven deterministically without a network or SwiftData.
    struct Dependencies {
        /// The account's shared `TwitchClient`.
        var client: @MainActor (_ accountUserId: String) -> TwitchClient
        /// Bridge token refresh, handed to each session for the
        /// EventSub-unauthorized retry path.
        var refreshTokens: @Sendable (_ accountUserId: String, _ accountLogin: String) async throws -> Void
        /// "Is any channel open?" signal driving EventSub reconnect policy.
        var sessionActivity: SessionActivitySignal
        var startSession: @Sendable (ChannelSession) async throws -> Void
        var stopSession: @Sendable (ChannelSession) async -> Void
    }

    let dependencies: Dependencies

    /// An in-flight `start()`: the session being started plus the Task every
    /// caller for the key awaits. The session reference is the identity token
    /// — a construction may only commit to `sessions`, or clean up after
    /// itself, while `inFlight[key]` still holds ITS session. A `release`
    /// (or `releaseAll`) that ends the key's lifetime mid-start removes the
    /// entry and cancels the Task, so a late-finishing start can never
    /// install a zombie session or clobber a newer acquire's state.
    private struct PendingStart {
        let session: ChannelSession
        let task: Task<ChannelSession, Error>
    }

    /// A teardown that has been detached from the maps but may still be
    /// unsubscribing on Twitch's side. `id` lets the Task clear its own
    /// entry without clobbering a later teardown for the same key.
    private struct PendingStop {
        let id: UInt64
        let task: Task<Void, Never>
    }

    /// Active sessions, keyed by composite "accountUserId/channelId".
    ///
    /// A key appears here only AFTER `session.start()` succeeds — this map is
    /// both the fast-path cache and the "ready to hand to a tab" set. Keeping
    /// it post-start is what guarantees no tab can `subscribe(_:)` to a session
    /// mid-startup (the "expose-late" half of option 2's backfill buffering).
    var sessions: [String: ChannelSession] = [:]

    /// Event-routing targets, keyed the same way as `sessions`. A session is
    /// registered here BEFORE `start()` runs, so the shared dispatcher can
    /// deliver live events to `handle(event:)` (which buffers them) during the
    /// subscribe + backfill window. Without this, the router would drop those
    /// events because the session isn't in `sessions` yet.
    ///
    /// Distinct from `sessions` on purpose: routing must begin early, but
    /// exposure (fast-path + coalescing result) must stay late. Conflating them
    /// would let a concurrent caller grab a not-yet-started session. Cleared on
    /// teardown and on failed start.
    ///
    /// Mirrored into `router` (which the off-main dispatcher reads): every
    /// write here is paired with a `router.register` / `router.unregister`.
    var dispatchTargets: [String: ChannelSession] = [:]

    /// The off-main routing table the per-account dispatchers deliver
    /// through. See `ChannelEventRouter`.
    let router = ChannelEventRouter()

    /// In-flight session-construction Tasks, keyed the same way as `sessions`.
    /// Two views opening the same channel concurrently each see no entry in
    /// `sessions` (because the first caller's `start()` hasn't returned yet),
    /// and without coalescing they would both construct a session and both
    /// call `start()` — the second `subscribe` then races Twitch's "already
    /// subscribed" rejection. Storing the in-flight Task here lets the second
    /// caller await the first's result instead.
    private var inFlight: [String: PendingStart] = [:]

    /// Teardowns still in progress, keyed the same way as `sessions`. The
    /// key's maps are cleared synchronously when its lifetime ends, so a
    /// re-acquire during the teardown builds a NEW session rather than
    /// receiving the stopping one — but that new session's `start()` first
    /// awaits the entry here. Otherwise its subscribe could hit Twitch's 409
    /// "already subscribed" (capturing no subscription id) and the old
    /// session's unsubscribe would then delete the topic out from under it.
    private var stopping: [String: PendingStop] = [:]

    /// Lifetime token per key, minted when the refcount goes 0 → 1 and
    /// dropped when it returns to 0. `acquire` only rolls back its own
    /// increment on failure if the lifetime it incremented is still current
    /// — if a `release` already ended that lifetime, the release consumed
    /// the increment (refcount AND `sessionActivity`), and rolling back again
    /// would steal a newer holder's refcount.
    private var lifetimes: [String: UInt64] = [:]

    /// Monotonic source for `lifetimes` and `PendingStop.id`.
    private var lastToken: UInt64 = 0

    /// Shared event-dispatcher Tasks, one per accountUserId. Each owns the
    /// single iterator on its account's `client.eventSub.events` stream and
    /// routes each event to the matching session's inbox via `router`.
    /// Detached (never main-actor). Started lazily on first session creation
    /// for an account and kept for that client's lifetime.
    var eventDispatchTasks: [String: Task<Void, Never>] = [:]

    /// Per-account connection-state mirrors, keyed by `accountUserId`. One per
    /// account because the EventSub socket is per account.
    var connectionStatusStores: [String: ConnectionStatusStore] = [:]

    /// Per-account tasks consuming `client.eventSub.connectionState`. Started
    /// alongside the event dispatcher and, like it, kept for the client's
    /// lifetime (see `ensureEventDispatch`).
    var connectionDispatchTasks: [String: Task<Void, Never>] = [:]

    /// The client each account's dispatcher consumes, held weakly so the
    /// registry never keeps an evicted client alive. Lets
    /// `ensureEventDispatch` tell "already consuming this client" from "the
    /// account got a new client" without a reused-address false match.
    var dispatchClients: [String: WeakClient] = [:]

    final class WeakClient {
        weak var client: TwitchClient?
        init(_ client: TwitchClient) { self.client = client }
    }

    /// Per-account moderated-channel fetches, keyed by `accountUserId`. The
    /// value is the fetch Task rather than the resolved set so concurrent
    /// channel-opens for the same account coalesce on a single Helix call —
    /// same pattern as `inFlight` for session construction. `nil` inside the
    /// Task's result means the fetch FAILED (as opposed to "user moderates
    /// no channels", which is a successful empty set).
    ///
    /// Entry lifetime: a successful fetch is cached for the registry's
    /// lifetime — being modded mid-run is covered by the badge-observation
    /// upgrade in `ChatTranscriptModel.apply`, so staleness here only delays the
    /// affordance, never breaks it. A FAILED fetch is evicted on completion
    /// so the next channel-open retries: failure is usually a pre-scope
    /// token (heals on re-sign-in, which can happen mid-run) or a transient
    /// network error.
    var moderatedChannelsTasks: [String: Task<Set<String>?, Never>] = [:]

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
    // LazyHStack inside ChatPagerScreen — when the user swipes off-screen,
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

    var emoteIndexes: [String: EmoteIndex] = [:]
    var badgeStores: [String: ChatBadgeStore] = [:]

    /// Ring capacity handed to each NEWLY constructed `ChannelSession` —
    /// the user's Chat History setting. Kept in sync by `RootView` (set at
    /// launch and on setting changes). Existing sessions keep the capacity
    /// they were built with; the new value applies when a channel tab is
    /// next opened fresh.
    public var chatHistoryLimit: Int = 500

    public convenience init(accountStore: AccountStore) {
        self.init(dependencies: Dependencies(
            client: { accountStore.client(forUserId: $0) },
            refreshTokens: { [weak accountStore] userId, login in
                guard let accountStore else { throw AppError(message: "AccountStore deallocated during refresh") }
                try await accountStore.refreshTokens(userId: userId, login: login)
            },
            sessionActivity: accountStore.sessionActivity,
            startSession: { try await $0.start() },
            stopSession: { await $0.stop() }
        ))
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
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
        // Every awaiter gets the SAME outcome: the commit-or-abandon decision
        // is made inside the Task itself, not by whichever caller created it.
        if let pending = inFlight[key] {
            return try await pending.task.value
        }

        // `client(forUserId:)` reconstructs the tokenNamespace from userId
        // — stable across launches, identical to what `client(for: account)`
        // would have produced.
        let client = dependencies.client(accountUserId)
        let refreshTokens = dependencies.refreshTokens
        let session = ChannelSession(
            client: client,
            channelId: channelId,
            channelLoginName: channelLoginName,
            accountUserId: accountUserId,
            accountLogin: accountLogin,
            ringCapacity: chatHistoryLimit,
            // The same registry-owned index the channel's ChatScreen loads —
            // the session normalizes against it (lock-protected snapshot, no
            // actor hop), so every tab shares one emote-resolved row.
            emoteIndex: emoteIndex(forAccountUserId: accountUserId, channelId: channelId),
            refreshTokenHandler: {
                try await refreshTokens(accountUserId, accountLogin)
            }
        )

        // Register for event routing + ensure the shared dispatcher is live
        // BEFORE start(), so live events arriving during subscribe/backfill are
        // delivered to handle() (which buffers them) instead of being dropped.
        // `sessions[key]` stays unset until start() succeeds, so this does NOT
        // expose the session to the fast path or to subscribers yet.
        // Idempotent: ensureEventDispatch spins up at most one Task per account.
        dispatchTargets[key] = session
        router.register(session, for: .init(accountUserId: accountUserId, channelId: channelId))
        ensureEventDispatch(client: client, accountUserId: accountUserId)

        // A previous session for this key may still be unsubscribing (it was
        // released and then re-acquired before its stop() finished). Start
        // only after it's gone — see `stopping`.
        let priorTeardown = stopping[key]?.task
        let start = dependencies.startSession
        let stop = dependencies.stopSession
        // MainActor-isolated: the commit/abandon bookkeeping below touches the
        // registry's maps. `start` / `stop` hop off-main to the session actor.
        let task = Task<ChannelSession, Error> { @MainActor in
            if let priorTeardown {
                await priorTeardown.value
            }
            do {
                try Task.checkCancellation()
                try await start(session)
                // `start()` deliberately swallows enrichment-subscribe errors
                // and an empty backfill, so a `release` that cancelled us
                // mid-start would otherwise go unnoticed and we'd install a
                // session nobody holds. Re-check before committing.
                try Task.checkCancellation()
            } catch {
                // Our own start failed, or a release cancelled us. Either way
                // this session is never handed out: detach whatever of it is
                // still ours, then unsubscribe anything it did manage to
                // create on Twitch's side.
                self.abandonStart(key: key, session: session, accountUserId: accountUserId)
                // Fresh unstructured Task: THIS Task may be cancelled, and a
                // cancelled context would abort stop()'s Helix unsubscribe
                // requests — leaving exactly the zombie subscriptions this
                // path exists to remove.
                await Task { await stop(session) }.value
                throw error
            }
            // Identity is the source of truth for "still current": release /
            // releaseAll remove the entry (and cancel) when they end the key's
            // lifetime. Unreachable without a cancel today, but never commit
            // a session that isn't the one this key is waiting on.
            guard self.inFlight[key]?.session === session else {
                self.abandonStart(key: key, session: session, accountUserId: accountUserId)
                await Task { await stop(session) }.value
                throw CancellationError()
            }
            self.inFlight[key] = nil
            self.sessions[key] = session
            // .notice: session creation is a boundary event — when this fires
            // we just opened a new WebSocket subscription to Twitch.
            logger.notice("Created session for @\(accountLogin, privacy: .public)/#\(channelLoginName, privacy: .public)")
            return session
        }
        // Set before this function's next suspension point, so the Task (which
        // is MainActor-isolated and can't run until we suspend) always finds
        // its own entry.
        inFlight[key] = PendingStart(session: session, task: task)
        return try await task.value
    }

    /// Undo an uncommitted start's registry state — but only the parts that
    /// still belong to `session`. A `release` + re-acquire during the start
    /// will have replaced both entries with a newer session's; clearing them
    /// unconditionally would orphan that newer acquire.
    private func abandonStart(key: String, session: ChannelSession, accountUserId: String) {
        if inFlight[key]?.session === session {
            inFlight[key] = nil
        }
        if dispatchTargets[key] === session {
            dispatchTargets[key] = nil
        }
        // Identity-based: a no-op if a newer session already took the route.
        router.unregister(session)
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
    ///
    /// Throws `CancellationError` if the key is released (to zero) or
    /// `releaseAll`ed while the session is still starting. That release
    /// already balanced this acquire's refcount + activity increment, so the
    /// caller must NOT release again.
    @discardableResult
    public func acquire(
        accountUserId: String,
        accountLogin: String,
        channelId: String,
        channelLoginName: String
    ) async throws -> ChannelSession {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if refCounts[key, default: 0] == 0 {
            lifetimes[key] = nextToken()
        }
        refCounts[key, default: 0] += 1
        let lifetime = lifetimes[key]
        // Mark the account "live" so its EventSub client reconnects aggressively
        // while this channel is open. Balanced by the decrement in release()
        // (and the rollback below if construction fails).
        dependencies.sessionActivity.increment()
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
            // Only roll back if the lifetime we incremented is still live. If
            // a release / releaseAll ended it while we were suspended, that
            // release already decremented for us — rolling back again would
            // eat a NEWER acquire's refcount and activity mark.
            if let lifetime, lifetimes[key] == lifetime, let count = refCounts[key], count > 0 {
                if count == 1 {
                    refCounts[key] = nil
                    lifetimes[key] = nil
                } else {
                    refCounts[key] = count - 1
                }
                // Roll back the activity increment from the top so a failed
                // acquire doesn't leave the account permanently "live".
                dependencies.sessionActivity.decrement()
            }
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
    ///
    /// Teardown order: everything the registry holds for the key (session,
    /// in-flight start, routing target, per-channel stores) is removed
    /// SYNCHRONOUSLY, before any suspension. Only then is the detached
    /// session's `stop()` awaited. A re-acquire during that await therefore
    /// builds a fresh session (whose start waits for this stop to finish)
    /// instead of being handed the stopping one, and nothing this release
    /// does after the await can wipe the new holder's state.
    public func release(accountUserId: String, channelId: String) async {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        guard let count = refCounts[key], count > 0 else {
            // .warning: double-release is a programming smell. We tolerate
            // it (idempotent), but surface it visibly so it's spotted.
            logger.warning("release \(key, privacy: .public) with no outstanding refcount — likely a double-release; ignoring")
            return
        }
        // Balance the increment from acquire(). The early-return guard above
        // (no outstanding refcount) intentionally does NOT decrement — that
        // release has no matching acquire.
        dependencies.sessionActivity.decrement()

        guard count == 1 else {
            refCounts[key] = count - 1
            // .debug: refcount decrement when not the last reference.
            // Pairs with the .debug "acquire" log on the opposite side.
            logger.debug("release \(key, privacy: .public) → refcount \(count - 1)")
            return
        }

        refCounts[key] = nil
        lifetimes[key] = nil
        let wasStarted = sessions[key] != nil
        let teardown = detach(key: key)
        if wasStarted, let teardown {
            await teardown.value
            // .notice: session teardown is a boundary event — counterpart
            // to the "Created session" notice above.
            logger.notice("release \(key, privacy: .public) → refcount 0; session stopped")
        } else {
            // .debug: rare path (release raced a still-running start, which
            // was cancelled and will stop its own session when start()
            // returns). Not awaited — a slow start must not stall the
            // caller's teardown loop; a re-acquire waits on it via `stopping`.
            logger.debug("release \(key, privacy: .public) → refcount 0; no started session (start cancelled or already gone)")
        }
        // The account's event dispatcher deliberately outlives its last
        // session — its streams are single-use (see `ensureEventDispatch`).
    }

    /// Releases EVERY session for an account at once, regardless of how
    /// many outstanding acquires each has — e.g. on account switch, where
    /// the outgoing account's tabs all go away together.
    ///
    /// Bookkeeping matches calling `release(...)` once per outstanding
    /// acquire: each key's refcount is zeroed and `sessionActivity` is
    /// decremented once per acquire it held. Sessions obtained via
    /// `session(...)` alone (no refcount) are torn down too. In-flight starts
    /// are cancelled; their pending `acquire` calls throw `CancellationError`
    /// and must not release again. Later `release(...)` calls for these keys
    /// are tolerated no-ops (logged as double-release).
    public func releaseAll(forAccountUserId accountUserId: String) async {
        let prefix = "\(accountUserId)/"
        var keys = Set(refCounts.keys.filter { $0.hasPrefix(prefix) })
        keys.formUnion(sessions.keys.filter { $0.hasPrefix(prefix) })
        keys.formUnion(inFlight.keys.filter { $0.hasPrefix(prefix) })
        keys.formUnion(dispatchTargets.keys.filter { $0.hasPrefix(prefix) })
        guard !keys.isEmpty else { return }

        // All synchronous detaching happens before the first await — same
        // ordering guarantee as `release(...)`.
        var startedTeardowns: [Task<Void, Never>] = []
        var releasedRefs = 0
        for key in keys {
            if let count = refCounts.removeValue(forKey: key), count > 0 {
                for _ in 0..<count {
                    dependencies.sessionActivity.decrement()
                }
                releasedRefs += count
            }
            lifetimes[key] = nil
            let wasStarted = sessions[key] != nil
            if let teardown = detach(key: key), wasStarted {
                startedTeardowns.append(teardown)
            }
        }
        for teardown in startedTeardowns {
            await teardown.value
        }
        logger.notice("releaseAll for account \(accountUserId, privacy: .public): \(keys.count) channel(s), \(releasedRefs) ref(s) released, \(startedTeardowns.count) session(s) stopped")
    }

    /// Synchronously removes everything the registry holds for `key` — the
    /// started session or in-flight start, its routing target, and the
    /// per-channel view stores — and returns the Task that finishes tearing
    /// the session down (nil if there was no session at all). The Task is
    /// also recorded in `stopping` so a re-acquire's start waits for it.
    ///
    /// Callers must have already zeroed the key's refcount + lifetime.
    private func detach(key: String) -> Task<Void, Never>? {
        // Stop routing events to this session regardless of whether it
        // finished starting (it may be in `dispatchTargets` but not yet in
        // `sessions` if the release races a slow start).
        if let target = dispatchTargets.removeValue(forKey: key) {
            router.unregister(target)
        }
        // T11: per-channel view stores share the session's lifetime.
        // Drop them here so the next acquire for the same channel starts
        // fresh — emote provider catalogs and channel badges might have
        // changed between sessions (broadcaster added a new 7TV emote,
        // promoted a subscriber tier, etc.). Holding stale stores would
        // also waste memory across closed-then-reopened tabs.
        emoteIndexes[key] = nil
        badgeStores[key] = nil

        let id = nextToken()
        let work: Task<Void, Never>
        if let pending = inFlight.removeValue(forKey: key) {
            // Cancel the in-flight construction. Its Task sees it is no
            // longer current once start() returns, stops its own session
            // and throws CancellationError to every awaiter (ChatScreen
            // already absorbs that silently). Waiting for the Task to finish
            // is therefore waiting for that stop.
            let startTask = pending.task
            startTask.cancel()
            work = Task { @MainActor in
                _ = try? await startTask.value
                self.finishTeardown(key: key, id: id)
            }
        } else if let session = sessions.removeValue(forKey: key) {
            let stop = dependencies.stopSession
            work = Task { @MainActor in
                await stop(session)
                self.finishTeardown(key: key, id: id)
            }
        } else {
            return nil
        }
        // Recorded before our next suspension point, so `work` (MainActor,
        // can't run until we suspend) always finds its own entry.
        stopping[key] = PendingStop(id: id, task: work)
        return work
    }

    /// Clears `stopping[key]` if it is still the teardown identified by `id`.
    private func finishTeardown(key: String, id: UInt64) {
        if stopping[key]?.id == id {
            stopping[key] = nil
        }
    }

    private func nextToken() -> UInt64 {
        lastToken &+= 1
        return lastToken
    }

    /// Test hook: true while a `start()` for this key is in flight (built
    /// but not yet committed or abandoned).
    func isStarting(accountUserId: String, channelId: String) -> Bool {
        inFlight[Self.key(accountUserId: accountUserId, channelId: channelId)] != nil
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

    // MARK: - Helpers

    /// Cache key for everything this registry owns per account × channel
    /// (sessions, emote indexes, badge stores).
    ///
    /// ## Twitch-scoped until sessions are platform-abstracted
    ///
    /// `channelId` here is the BARE Twitch broadcaster id, not the
    /// composite `ChannelDescriptor.ID` ("platform/channelId") that
    /// platform-safe storage (e.g. `DraftStorage`) keys on. That's
    /// deliberate for now: this whole registry is Twitch-coupled
    /// (EventSub subscribe, Helix badge fetch), and acquire / release /
    /// lookup all share THIS one key function — migrating only the
    /// lookup half to composite keys would desync `release(...)`'s
    /// cleanup and leak stores. When a second platform lands, sessions
    /// get platform-abstracted and this key switches to
    /// `ChannelDescriptor.ID` in the same change, keeping all keyed
    /// paths in lockstep.
    static func key(accountUserId: String, channelId: String) -> String {
        "\(accountUserId)/\(channelId)"
    }
}
