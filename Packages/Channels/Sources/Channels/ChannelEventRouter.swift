import Foundation
import TwitchKit
import os

/// Routes an account's EventSub events to the channel sessions they belong
/// to — entirely off the main actor, and without ever waiting on a session.
///
/// ## Shape
///
/// A lock-protected table from `RouteKey` (a plain struct — no per-event
/// string building) to a per-channel **inbox**: an unbounded `AsyncStream`
/// drained by one task that feeds the session's `handle(event:)` in arrival
/// order. The account's dispatcher only does `route(_:accountUserId:)` — a
/// table lookup plus a non-blocking `yield` — so:
///
///   - the dispatcher never runs on, or hops to, the main actor;
///   - a channel that is slow to process (or a subscriber that is slow to
///     drain) only backs up its OWN inbox; every other channel on the same
///     socket keeps flowing.
///
/// Ordering is per channel, which is the only ordering events have ever had:
/// one inbox per session, drained by one task.
///
/// The inbox is unbounded because its consumer does bounded CPU work per
/// event (translate + normalize + append), never I/O — and dropping an
/// event here would silently lose a message or a moderation action.
///
/// The table is also the registry's only record of which session receives a
/// key's events (`session(for:)`, `keys(forAccountUserId:)`, `sessions`):
/// the registry keeps no second copy that could drift from what the
/// dispatcher actually delivers to.
final class ChannelEventRouter: Sendable {

    /// One account × channel. Also the key of everything
    /// `ChannelSessionRegistry` holds per session.
    struct RouteKey: Hashable, Sendable, CustomStringConvertible {
        let accountUserId: String
        let channelId: String

        /// "accountUserId/channelId", for log lines.
        var description: String { "\(accountUserId)/\(channelId)" }
    }

    private struct Route: Sendable {
        let session: ChannelSession
        let inbox: AsyncStream<EventSubEvent>.Continuation
    }

    private let routes = OSAllocatedUnfairLock<[RouteKey: Route]>(initialState: [:])

    /// Starts routing `key`'s events to `session`, replacing (and closing the
    /// inbox of) any session previously registered for it.
    func register(_ session: ChannelSession, for key: RouteKey) {
        let (inbox, continuation) = AsyncStream.makeStream(
            of: EventSubEvent.self,
            bufferingPolicy: .unbounded
        )
        let route = Route(session: session, inbox: continuation)
        let replaced = routes.withLock { routes -> Route? in
            let previous = routes[key]
            routes[key] = route
            return previous
        }
        replaced?.inbox.finish()

        // The drain task holds the session only until the inbox finishes
        // (`unregister` / replacement), then exits.
        Task {
            for await event in inbox {
                await session.handle(event: event)
            }
        }
    }

    /// Stops routing to `session` wherever it is registered. Identity-based,
    /// so a stale teardown can never unroute a newer session that took over
    /// the same key. Buffered events still in its inbox are delivered first.
    func unregister(_ session: ChannelSession) {
        let removed = routes.withLock { routes -> [Route] in
            let keys = routes.compactMap { $0.value.session === session ? $0.key : nil }
            return keys.compactMap { routes.removeValue(forKey: $0) }
        }
        for route in removed {
            route.inbox.finish()
        }
    }

    /// Stops routing `key`, whichever session holds it. Buffered events
    /// still in that session's inbox are delivered first.
    func unregister(key: RouteKey) {
        let removed = routes.withLock { routes -> Route? in
            routes.removeValue(forKey: key)
        }
        removed?.inbox.finish()
    }

    /// The session `key`'s events are delivered to, if any.
    func session(for key: RouteKey) -> ChannelSession? {
        routes.withLock { $0[key]?.session }
    }

    /// The keys routed for one account.
    func keys(forAccountUserId accountUserId: String) -> [RouteKey] {
        routes.withLock { routes -> [RouteKey] in
            routes.keys.filter { $0.accountUserId == accountUserId }
        }
    }

    /// Every session currently routed to, in no particular order.
    var sessions: [ChannelSession] {
        routes.withLock { routes -> [ChannelSession] in
            routes.values.map { $0.session }
        }
    }

    /// Hands one event to its channel's inbox. Synchronous: never suspends,
    /// never waits on the session. Events for channels with no route (none
    /// open, or torn down while the event was in flight) are dropped.
    func route(_ event: EventSubEvent, accountUserId: String) {
        guard let channelId = ChannelSession.broadcasterUserId(from: event) else { return }
        let key = RouteKey(accountUserId: accountUserId, channelId: channelId)
        let inbox = routes.withLock { $0[key]?.inbox }
        inbox?.yield(event)
    }

    /// Test hook: whether `key` currently routes anywhere.
    func isRouted(_ key: RouteKey) -> Bool {
        routes.withLock { $0[key] != nil }
    }
}
