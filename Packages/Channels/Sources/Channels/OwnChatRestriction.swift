import Foundation

/// Why the SIGNED-IN user can't (or may not be able to) chat in a channel —
/// the top-of-chat banner and the compose bar's disabled state.
///
/// Twitch gives a viewer no dedicated "you were timed out" event, so this is
/// assembled from the two signals that do reach us:
///   - `channel.chat.clear_user_messages` targeting our own account (a mod
///     timed us out or banned us; the event carries no duration) →
///     `.removedByModerator`.
///   - a Send Chat Message drop reason / 403 (`msg_timedout` "You are timed
///     out for 597 more seconds.", `msg_banned`, warnings) → the precise
///     case, including the timeout's end for the countdown.
public enum OwnChatRestriction: Sendable, Equatable {
    /// Timed out. `until` is nil when Twitch didn't say for how long.
    case timedOut(until: Date?)
    /// Permanently banned from this chat.
    case banned
    /// A moderator warned us; Twitch blocks chatting until the warning is
    /// acknowledged (on twitch.tv — Helix has no acknowledge endpoint).
    case warned(reason: String?)
    /// Our messages were cleared by a moderator: a timeout or ban of
    /// unknown length. Upgraded to a precise case by the next send attempt.
    case removedByModerator

    /// Whether the compose bar should refuse to send. Only the cases where
    /// Twitch is certain to drop the message: a timeout we know is still
    /// running, or a ban. Warned / removed stay sendable — a send attempt is
    /// cheap and its drop reason refines the state (or proves it's lifted).
    public func blocksSending(at now: Date = .now) -> Bool {
        switch self {
        case .timedOut(let until?): return until > now
        case .banned: return true
        case .timedOut(.none), .warned, .removedByModerator: return false
        }
    }

    /// Parses a Send Chat Message drop reason (or a 403's message). Returns
    /// nil for drops that aren't about OUR standing in the channel (slow
    /// mode, duplicate, AutoMod, followers-only …).
    ///
    /// Matches on the code first and the human message second, because
    /// Twitch's code vocabulary for these isn't fully documented and a
    /// 403 carries only a message.
    public init?(dropCode: String?, message: String?, now: Date = .now) {
        let code = (dropCode ?? "").lowercased()
        let text = message ?? ""
        let lowered = text.lowercased()

        if code.contains("timedout") || code.contains("timed_out") || lowered.contains("timed out") {
            self = .timedOut(until: Self.remainingSeconds(in: text).map { now.addingTimeInterval(TimeInterval($0)) })
        } else if code.contains("banned") || lowered.contains("banned from") || lowered.contains("are banned") {
            self = .banned
        } else if code.contains("warn") || lowered.contains("warning") || lowered.contains("warned") {
            self = .warned(reason: nil)
        } else {
            return nil
        }
    }

    /// "You are timed out for 597 more seconds." → 597. The first integer
    /// that's followed by a "second" word; nil when there isn't one.
    static func remainingSeconds(in message: String) -> Int? {
        let words = message.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" })
        for (index, word) in words.enumerated() {
            guard let value = Int(word.trimmingCharacters(in: .punctuationCharacters)), value > 0 else { continue }
            // Allow one word between the number and the unit ("597 more seconds").
            let following = words.dropFirst(index + 1).prefix(2).map { $0.lowercased() }
            if following.contains(where: { $0.hasPrefix("second") }) {
                return value
            }
        }
        return nil
    }
}
