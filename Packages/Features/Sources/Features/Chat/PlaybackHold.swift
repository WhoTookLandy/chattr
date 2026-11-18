#if os(iOS)
import Foundation

/// A pause taken with `PlaybackCenter.holdPlayback`.
struct PlaybackHold: Equatable {
    let id: UUID
    let reason: PlaybackHoldReason
    let generation: Int
    /// Decided when the hold began (`PlaybackCenter.resumesOnRelease`).
    let resumeOnRelease: Bool
}
#endif
