#if os(iOS)
import Foundation

/// A per-slot hold record owned inside a `PlaybackSlot`.
struct SlotHold: Equatable, Sendable {
    let id: UUID
    let reason: PlaybackHoldReason
    let generation: Int
    /// Decided when the hold began (`PlaybackCenter.resumesOnRelease`).
    let resumeOnRelease: Bool
}

/// A pause token returned by `PlaybackCenter.holdPlayback(_:)`.
///
/// Carries the generation of every slot (`primary` + `pinnedAudio`) that the
/// hold targeted when acquired, so releasing the token resumes each surviving
/// slot independently and ignores any slot that was stopped or changed channel.
struct PlaybackHold: Equatable, Sendable {
    let id: UUID
    let reason: PlaybackHoldReason
    /// `slot.id` → `slot.generation` captured when the hold was acquired.
    var slotGenerations: [UUID: Int]
}
#endif
