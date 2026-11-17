import Foundation

/// What the native player does after a failed resolve or a playback
/// failure: resolve the playlist again and carry on, a few times with a
/// growing wait, before handing the stream to the web player. Twitch's
/// playlist tokens expire and a connection drops for a moment far more
/// often than the native path is actually broken.
///
/// A value type with the clock passed in, so the policy is testable without
/// a player.
struct PlaybackRecovery {
    enum Step: Equatable {
        /// Resolve the playlist again after this long.
        case retry(after: Duration)
        /// Out of tries, or Twitch said no: stop trying natively.
        case giveUp
    }

    static let maxRetries = 3
    /// Failures further apart than this are separate incidents: a stream
    /// that recovered and played on starts from a full set of tries.
    static let quietPeriod: Duration = .seconds(60)
    /// The wait between tries once the quick ones are used up and there is
    /// nothing to fall back to (`staysNative`).
    static let patientDelay: Duration = .seconds(15)

    private(set) var failures = 0
    private var lastFailureAt: ContinuousClock.Instant?

    /// The next step after a failure. `error` is the resolver's or the
    /// player's, nil for a stall that never cleared. `staysNative`: the web
    /// player can't take over right now (audio-only in the background), so
    /// instead of giving up the tries continue, slowly.
    mutating func step(
        after error: (any Error)?,
        staysNative: Bool = false,
        now: ContinuousClock.Instant = ContinuousClock.now
    ) -> Step {
        // Twitch answered, and the answer was no. Asking again won't change it.
        if let refusal = error as? StreamPlaylistError, refusal != .unavailable {
            return .giveUp
        }
        if let lastFailureAt, now - lastFailureAt > Self.quietPeriod {
            failures = 0
        }
        lastFailureAt = now
        failures += 1
        if failures <= Self.maxRetries {
            return .retry(after: Self.delay(forAttempt: failures))
        }
        return staysNative ? .retry(after: Self.patientDelay) : .giveUp
    }

    /// 1 s, 2 s, 4 s.
    static func delay(forAttempt attempt: Int) -> Duration {
        .seconds(1 << max(0, attempt - 1))
    }
}
