import Foundation
import TwitchKit
import ChatModel
import os

/// One item of a channel's display stream — what `ChannelSession` keeps in
/// its ring and delivers to subscribers.
///
/// Rows arrive already normalized: the session runs the `Normalizer` once per
/// event, off the main actor, and every tab showing the channel shares the
/// result. Subscribers only decide what to do with a row (dedup, echo
/// reconciliation, block filtering, keyword highlighting), never how to build
/// it.
public enum ChannelUpdate: Sendable {
    /// A chat message: the display line plus the raw payload it came from.
    /// The payload rides along because subscribers still need fields the
    /// line doesn't carry (message text for send-echo matching and command
    /// filtering, sender badges for mod detection).
    case message(NormalizedMessage)

    /// A rendered non-message row: a sub / raid / system bubble, or the
    /// "New" divider. Ids and timestamps were minted once when the session
    /// produced the row, so every replay of the ring yields the same row.
    case row(ChatLine)

    /// A moderator deleted one message — flip that row to a placeholder.
    case messageDeleted(targetMessageId: String)

    /// The whole chat was cleared — flip every message row.
    case chatCleared

    /// A user was timed out / banned — flip every row they authored.
    case messagesClearedFromUser(targetUserId: String)

    /// Chat settings changed (slow mode, followers-only, …). No row.
    case restrictionsUpdated(ChatRestrictions)

    /// The session account's mod status changed mid-session. No row.
    case moderationStatusChanged(canModerate: Bool)

    /// Rebuild your view of the channel from this snapshot, exactly as at
    /// subscribe time. Never stored in the ring; the session sends it when
    /// the ring changed in a way that isn't a tail append (late join history
    /// merged ABOVE the live rows) or when a subscriber fell so far behind
    /// that replaying its backlog would cost more than starting over.
    case reprime([ChannelUpdate])

    /// A message normalized with no third-party emotes. For previews and
    /// tests, which have no session to normalize for them; production rows
    /// come from `ChannelSession`.
    public static func normalizedMessage(
        _ message: ChatMessage,
        isHistorical: Bool = false,
        timestamp: Date,
        currentUserLogin: String = ""
    ) -> ChannelUpdate {
        var line = Normalizer.normalize(
            message: message,
            emoteSnapshot: [:],
            currentUserLogin: currentUserLogin,
            timestamp: timestamp
        )
        line.isHistorical = isHistorical
        return .message(NormalizedMessage(message: message, line: line))
    }
}

/// A chat message and its display line, normalized once by the session.
///
/// `line.isHighlighted` covers self-mentions only (the session knows its
/// account's login); viewer-configured keywords are layered on by each
/// subscriber with a `HighlightMatcher`.
///
/// A final class rather than a struct: the payload plus line is ~700 bytes
/// with a couple of dozen refcounted fields, and it is handed on by value
/// into the ring, every subscriber mailbox, each pattern-match extraction
/// and every ring snapshot (a tab attach copies all retained rows). As a
/// class each of those is one retain. Every field is an immutable `let`.
public final class NormalizedMessage: Sendable {
    public let message: ChatMessage
    public let line: ChatLine

    /// `EmoteIndex.generation` of the emote table `line` was built against.
    /// When the table has since been republished (typically: history that
    /// was normalized before the channel's 7TV/BTTV/FFZ set loaded), the
    /// session re-normalizes the row the next time a tab subscribes.
    let emoteGeneration: Int

    public convenience init(message: ChatMessage, line: ChatLine) {
        self.init(message: message, line: line, emoteGeneration: 0)
    }

    init(message: ChatMessage, line: ChatLine, emoteGeneration: Int) {
        self.message = message
        self.line = line
        self.emoteGeneration = emoteGeneration
    }
}
