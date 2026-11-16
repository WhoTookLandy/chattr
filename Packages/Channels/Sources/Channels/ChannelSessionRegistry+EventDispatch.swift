import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Registry")

extension ChannelSessionRegistry {

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
    func stopDispatcherIfIdle(accountUserId: String) {
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
    func ensureEventDispatch(client: TwitchClient, accountUserId: String) {
        guard eventDispatchTasks[accountUserId] == nil else { return }

        // ONE iterator on the client's event stream — that's the whole point
        // of this Task. Detached so the loop never runs on (or waits for) the
        // main actor; it touches only the Sendable router, whose `route` is a
        // lock-protected lookup + non-blocking inbox yield. Nothing here
        // awaits a session or a subscriber.
        let router = self.router
        eventDispatchTasks[accountUserId] = Task.detached(priority: .userInitiated) {
            for await event in client.eventSub.events {
                guard !Task.isCancelled else { return }
                router.route(event, accountUserId: accountUserId)
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
            connectionDispatchTasks[accountUserId] = Task { @MainActor [weak self] in
                // Track the previous state so a RECOVERY (reconnecting →
                // connected) is distinguishable from the cold-start connect
                // (connecting → connected, which the join backfill covers).
                var previous: ConnectionState = .connecting
                for await state in client.eventSub.connectionState {
                    guard !Task.isCancelled else { return }
                    store.update(state)
                    if Self.isReconnectRecovery(from: previous, to: state) {
                        self?.resyncSessionsAfterReconnect(accountUserId: accountUserId)
                    }
                    previous = state
                }
            }
        }
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
    private func resyncSessionsAfterReconnect(accountUserId: String) {
        let prefix = "\(accountUserId)/"
        let accountSessions = sessions.filter { $0.key.hasPrefix(prefix) }.map(\.value)
        guard !accountSessions.isEmpty else { return }
        logger.info("EventSub reconnected for account \(accountUserId, privacy: .public) — resyncing \(accountSessions.count) session(s)")
        for session in accountSessions {
            // Weak-capture: if the tab is closed (and the session released)
            // between this reconnect and the gap-fill running, the session must
            // be free to deallocate rather than be pinned by a best-effort Task.
            Task { [weak session] in
                await session?.resyncAfterReconnect()
            }
        }
    }

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
