import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Registry")

extension ChannelSessionRegistry {

    // MARK: - Event dispatch

    /// Starts the single event-dispatch loop for this account's client if it
    /// isn't already running for THIS client. A call with the same client is
    /// a no-op; a call with a different client (the account was removed and
    /// re-added, so the cache built a new one) replaces the old consumers.
    ///
    /// Lifetime: the consumers are deliberately NOT cancelled when the
    /// account's last session closes. `client.eventSub.events` and
    /// `.connectionState` are single-consumer `AsyncStream`s created ONCE per
    /// `EventSubClient`, and cancelling the Task iterating one terminates the
    /// stream for good. The client is cached and reused, so a cancelled
    /// consumer meant every later session for the account (close the last
    /// tab, then reopen a channel) got history but no live events. Iterating
    /// the streams never kept the WebSocket open either — the socket belongs
    /// to the `EventSubClient` — so cancelling bought nothing.
    ///
    /// Instead the consumers live exactly as long as their client: they
    /// capture only the streams, never the client, so when an evicted client
    /// deallocates its `deinit` finishes both streams and the loops exit.
    /// That is the only way the streams end on their own (TwitchKit finishes
    /// them nowhere else), and every session retains its client — so a
    /// stream can't end under an open session, and there is nothing to
    /// restart: the ended dispatcher just clears its account's entries
    /// (`eventStreamDidFinish`). Note a client whose socket ever connected
    /// only deallocates after `eventSub.disconnect()`: its own receive and
    /// keepalive tasks retain it until then.
    func ensureEventDispatch(client: TwitchClient, accountUserId: String) {
        if eventDispatchTasks[accountUserId] != nil,
           let current = dispatchClients[accountUserId]?.client,
           current === client {
            return
        }
        // Consumers left over from a previous (or deallocated) client. Their
        // streams belong to a client nobody uses any more, so cancelling them
        // is safe — and the new client needs its own consumers.
        eventDispatchTasks[accountUserId]?.cancel()
        connectionDispatchTasks[accountUserId]?.cancel()
        dispatchClients[accountUserId] = WeakClient(client)
        let generation = nextToken()
        dispatchGenerations[accountUserId] = generation

        // ONE iterator on the client's event stream — that's the whole point
        // of this Task. Detached so the loop never runs on (or waits for) the
        // main actor; it touches only the Sendable router, whose `route` is a
        // lock-protected lookup + non-blocking inbox yield. Nothing here
        // awaits a session or a subscriber. Captures the stream, NOT the
        // client, so the client can deallocate (which finishes the stream).
        let router = self.router
        let events = client.eventSub.events
        eventDispatchTasks[accountUserId] = Task.detached(priority: .userInitiated) { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                router.route(event, accountUserId: accountUserId)
            }
            // Cancelled: replaced by newer consumers, which own the entries.
            guard !Task.isCancelled else { return }
            await self?.eventStreamDidFinish(accountUserId: accountUserId, generation: generation)
        }
        logger.info("Started event dispatcher for account \(accountUserId, privacy: .public)")

        // Per-account connection-state pump. Consumes the single-consumer
        // `connectionState` stream and mirrors it into the @Observable store the
        // ChatScreen reads. Started here (with the event dispatcher) so it begins
        // before connect() and observes the initial .connecting/.connected
        // transitions — the stream has no value replay for late subscribers.
        let store = connectionStatus(forAccountUserId: accountUserId)
        let states = client.eventSub.connectionState
        connectionDispatchTasks[accountUserId] = Task { @MainActor [weak self] in
            // Track the previous state so a RECOVERY (reconnecting →
            // connected) is distinguishable from the cold-start connect
            // (connecting → connected, which the join backfill covers).
            var previous: ConnectionState = .connecting
            // When the socket was first seen down, until it is back: the
            // gap-fill takes nothing sent before the drop.
            var droppedAt: Date?
            for await state in states {
                guard !Task.isCancelled else { return }
                store.update(state)
                if previous == .connected, state != .connected, droppedAt == nil {
                    droppedAt = Date()
                }
                if Self.isReconnectRecovery(from: previous, to: state) {
                    self?.resyncSessionsAfterReconnect(accountUserId: accountUserId, droppedAt: droppedAt)
                }
                if state == .connected {
                    droppedAt = nil
                }
                previous = state
            }
        }
    }

    /// The account's event stream ended by itself — its client is gone
    /// (evicted or replaced, then deallocated). Drops the dispatch state
    /// that belonged to that client, unless newer consumers took over.
    func eventStreamDidFinish(accountUserId: String, generation: UInt64) {
        guard dispatchGenerations[accountUserId] == generation else { return }
        dispatchGenerations[accountUserId] = nil
        eventDispatchTasks[accountUserId] = nil
        // Its stream ended with the same client; cancelling is a formality.
        connectionDispatchTasks[accountUserId]?.cancel()
        connectionDispatchTasks[accountUserId] = nil
        dispatchClients[accountUserId] = nil
        connectionStatusStores[accountUserId] = nil
        logger.info("Event stream ended for account \(accountUserId, privacy: .public); dropped its dispatcher state")
    }

    /// True when a state transition means "the socket was down and is back" —
    /// the trigger for the reconnect gap-fill. `.connecting → .connected` is
    /// the initial cold-start connect (rustlog join-backfill covers it), and
    /// `.disconnected` is an explicit teardown that only comes back through a
    /// fresh `start()` — neither resyncs.
    static func isReconnectRecovery(from previous: ConnectionState, to current: ConnectionState) -> Bool {
        guard current == .connected else { return false }
        switch previous {
        case .reconnecting, .waitingForNetwork: return true
        case .connecting, .connected, .disconnected: return false
        }
    }

    /// Kick a gap-fill on every STARTED session for the account. Fire-and-
    /// forget per session — the resync is best-effort (rustlog may be down)
    /// and must never block the connection pump's stream consumption.
    /// Sessions mid-`start()` are skipped: their initial backfill is already
    /// fetching against the post-reconnect subscription.
    ///
    /// With several channels open each fetch starts after its own short
    /// random delay, so one reconnect isn't N requests to the history
    /// service in the same instant.
    private func resyncSessionsAfterReconnect(accountUserId: String, droppedAt: Date?) {
        let prefix = "\(accountUserId)/"
        let accountSessions = sessions.filter { $0.key.hasPrefix(prefix) }.map(\.value)
        guard !accountSessions.isEmpty else { return }
        logger.info("EventSub reconnected for account \(accountUserId, privacy: .public) — resyncing \(accountSessions.count) session(s)")
        for session in accountSessions {
            let jitter: Duration = accountSessions.count > 1
                ? .milliseconds(Int.random(in: 0..<Self.resyncJitterMilliseconds))
                : .zero
            // Weak-capture: if the tab is closed (and the session released)
            // between this reconnect and the gap-fill running, the session must
            // be free to deallocate rather than be pinned by a best-effort Task.
            Task { [weak session] in
                try? await Task.sleep(for: jitter)
                await session?.resyncAfterReconnect(droppedAt: droppedAt)
            }
            // Live-event banners: a poll / prediction / train that began,
            // ended or resolved while the socket was down has no EventSub
            // event coming, so re-read them from Helix. A no-op except on
            // the account's own channel. Separate task: it must not wait
            // behind the rustlog gap-fill.
            Task { [weak session] in
                await session?.reconcileLiveEvents()
            }
        }
    }

    /// Upper bound of the per-session delay before a reconnect gap-fill.
    private static let resyncJitterMilliseconds = 2_000

    /// Test hook: whether the off-main router currently delivers this
    /// account × channel's events anywhere. Routing starts BEFORE `start()`
    /// (so events during subscribe + backfill are buffered, not dropped) and
    /// ends synchronously when the key's lifetime does.
    func isRouted(accountUserId: String, channelId: String) -> Bool {
        router.isRouted(.init(accountUserId: accountUserId, channelId: channelId))
    }

    // MARK: - Cold-start zombie cleanup

    /// Reaps dead EventSub subscriptions left behind by a previous
    /// crash/force-quit. WebSocket subscriptions are session-bound: when the app
    /// is killed and the socket isn't resumed in time, Twitch marks them
    /// `websocket_disconnected` (and similar) and auto-removes them within ~1h —
    /// but they count against the per-app subscription quota until then. This
    /// frees that quota immediately on launch.
    ///
    /// Deletes every subscription whose status is **not** `.enabled`. For a
    /// websocket-only client `enabled` is the only live status, so this can never
    /// remove a subscription we're actually using — even if it races session
    /// startup (a fresh subscribe produces an `.enabled` sub this skips). Covers
    /// every dead status without enumerating them, and is future-proof.
    ///
    /// Best-effort: any error (list or delete) is logged and swallowed. Never
    /// blocks or fails chat startup.
    public func cleanupDisconnectedSubscriptions(forAccountUserId accountUserId: String) async {
        let client = dependencies.client(accountUserId)
        do {
            var reaped = 0
            for try await record in client.api.eventSubSubscriptions() {
                if case .enabled = record.status { continue }   // keep live subs
                try? await client.api.deleteEventSubSubscription(id: record.id)
                reaped += 1
            }
            if reaped > 0 {
                logger.notice("Reaped \(reaped) dead EventSub subscription(s) for account \(accountUserId, privacy: .public)")
            }
        } catch {
            // Listing failed (auth/network). Cleanup is best-effort — Twitch's
            // own auto-removal is the backstop.
            logger.debug("EventSub zombie cleanup skipped for \(accountUserId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
