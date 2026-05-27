import Foundation
import Accounts
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
    private var sessions: [String: ChannelSession] = [:]

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

    public init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    /// Returns (creating if needed) the session for the given account × channel
    /// pair. The session is `start()`ed automatically on first access, and the
    /// shared event-dispatcher for the account's client is started lazily on
    /// the same path. Concurrent callers for the same key share a single
    /// construction Task.
    public func session(account: Account, channelId: String, channelLoginName: String) async throws -> ChannelSession {
        let key = Self.key(accountUserId: account.userId, channelId: channelId)

        // Fast path — already created.
        if let existing = sessions[key] {
            return existing
        }
        // Slow path with a peer already mid-creation — share its result.
        if let pending = inFlight[key] {
            return try await pending.value
        }

        let client = accountStore.client(for: account)
        // Capture stable String values rather than the non-Sendable `Account`
        // model so the @Sendable closure compiles under Swift 6 strict concurrency.
        let capturedUserId = account.userId
        let capturedLogin = account.login
        let session = ChannelSession(
            client: client,
            channelId: channelId,
            channelLoginName: channelLoginName,
            accountUserId: capturedUserId,
            refreshTokenHandler: { [weak accountStore] in
                guard let accountStore else { throw AppError(message: "AccountStore deallocated during refresh") }
                try await accountStore.refreshTokens(userId: capturedUserId, login: capturedLogin)
            }
        )

        let task = Task<ChannelSession, Error> { [session] in
            try await session.start()
            return session
        }
        inFlight[key] = task
        do {
            let started = try await task.value
            sessions[key] = started
            inFlight[key] = nil
            // Kick the shared event dispatcher for this account if it isn't
            // already running. Idempotent — multiple session(...) calls for
            // the same account spin up at most one dispatcher Task.
            ensureEventDispatch(client: client, accountUserId: capturedUserId)
            logger.info("Created session for @\(capturedLogin)/#\(channelLoginName)")
            return started
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    /// Stops and removes the session for the given pair. Also cancels any
    /// in-flight creation Task — if another caller is currently awaiting
    /// `session(...)` for this same key, their await will throw
    /// `CancellationError` (ChatScreen already silently absorbs that).
    public func leave(accountUserId: String, channelId: String) async {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let task = inFlight[key] {
            task.cancel()
            inFlight[key] = nil
        }
        if let session = sessions[key] {
            await session.stop()
            sessions[key] = nil
            logger.info("Left session \(key)")
        }
    }

    // MARK: - Event dispatch

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
        logger.info("Started event dispatcher for account \(accountUserId)")
    }

    /// Routes a single event to the session whose `channelId` matches the
    /// event's broadcaster. Drops events for channels with no active session
    /// (briefly possible during close-X — event in flight while we tear down).
    private func dispatch(event: EventSubEvent, accountUserId: String) async {
        guard let broadcasterId = ChannelSession.broadcasterUserId(from: event) else {
            return
        }
        let key = Self.key(accountUserId: accountUserId, channelId: broadcasterId)
        guard let session = sessions[key] else {
            return
        }
        await session.handle(event: event)
    }

    // MARK: - Helpers

    private static func key(accountUserId: String, channelId: String) -> String {
        "\(accountUserId)/\(channelId)"
    }
}
