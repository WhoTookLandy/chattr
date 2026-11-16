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
final class ChannelEventRouter: Sendable {

    struct RouteKey: Hashable, Sendable {
        let accountUserId: String
        let channelId: String
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
