import Observation
import TwitchKit

/// Registry-owned, per-account mirror of the EventSub WebSocket's
/// `ConnectionState`. `@Observable` so a `ChatScreen` reading it re-renders its
/// connection pill when the socket drops or recovers.
///
/// Keyed per *account* (not per channel) because one WebSocket per account is
/// shared by all that account's open channels — they all reflect the same
/// connection state. Lifetime matches the account's event dispatcher: created
/// with the first session for the account and kept for as long as the
/// account's client lives (the dispatcher's streams can't be re-consumed, so
/// it isn't torn down with the last session).
@MainActor
@Observable
public final class ConnectionStatusStore {
    /// Latest state from `EventSubClient.connectionState`. Starts optimistic at
    /// `.connecting` (matches what the client emits on its initial connect),
    /// so the pill stays hidden on a normal cold start.
    public private(set) var state: ConnectionState = .connecting

    public init() {}

    func update(_ newState: ConnectionState) {
        state = newState
    }
}
