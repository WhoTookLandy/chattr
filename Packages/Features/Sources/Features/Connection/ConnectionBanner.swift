import TwitchKit

/// What the channel-header connection pill should show, derived purely from a
/// `ConnectionState` transition. The view owns the auto-dismiss timer for
/// `.liveAgain`; this type owns the *decision*, so it's unit-testable.
enum ConnectionBanner: Equatable {
    case hidden
    case reconnecting
    case liveAgain

    /// Map a state transition to a banner.
    ///
    /// - `.reconnecting` / `.waitingForNetwork` → show "Reconnecting…".
    /// - transition INTO `.connected` FROM a down state → flash "Live again".
    /// - steady `.connected`, initial `.connecting`, intentional `.disconnected`
    ///   → hidden. A first-ever connect (`previous == nil`) must NOT flash, so
    ///   `.liveAgain` requires a genuine prior down state.
    static func next(previous: ConnectionState?, current: ConnectionState) -> ConnectionBanner {
        switch current {
        case .reconnecting, .waitingForNetwork:
            return .reconnecting
        case .connected:
            switch previous {
            case .reconnecting, .waitingForNetwork:
                return .liveAgain
            default:
                return .hidden
            }
        case .connecting, .disconnected:
            return .hidden
        }
    }
}
