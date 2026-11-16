import Foundation
import TwitchKit
import ChatModel

/// The signed-in user as one transcript knows them: identity from attach,
/// plus the name colour and badge set learned along the way — everything an
/// optimistic send row needs to render fully styled before its echo lands,
/// instead of flashing plain for the ~0.5s round-trip.
struct SelfChatter {
    /// Twitch user id. Recognizes our own messages in the echo stream.
    var userId = ""
    /// Lowercase login, so a localized (non-Latin) display name renders as
    /// "name (login)" immediately rather than flipping when the echo lands.
    var login = ""
    /// Display name as capitalized at signup.
    var displayName = ""

    /// Chat name colour ("#FF69B4"). Seeded from GET /chat/color at attach
    /// (fire-and-forget), then refreshed from each own echo — the echo wins,
    /// since it reflects mid-session colour changes.
    var color = ""

    /// Badge set in THIS channel (mod / sub / VIP …) from the most recent own
    /// echo. Empty until the session's first echo — there's no cheap Helix
    /// endpoint for "my badges in channel X", so the first message renders
    /// badge-less and every one after is styled.
    var badges: [ChatBadge] = []

    /// Whether the signed-in user wrote `message`.
    func wrote(_ message: ChatMessage) -> Bool {
        message.chatterUserId == userId
    }

    /// Keeps the colour and badges current from an own echo, which carries
    /// Twitch's authoritative styling for this channel.
    mutating func learnStyle(fromOwnEcho message: ChatMessage) {
        if !message.color.isEmpty { color = message.color }
        if !message.badges.isEmpty { badges = message.badges }
    }

    /// The row shown the instant the user sends `text`, dimmed as `.sending`
    /// until its echo (or the stuck-send fallback) settles it. Word-level
    /// runs (FlowLayout wraps between runs) but no emote resolution — the
    /// echo replaces it with the session's fully normalized row.
    func optimisticLine(
        id: String,
        text: String,
        replyingTo reply: ChatTranscriptModel.ReplyContext?
    ) -> ChatLine {
        ChatLine(
            id: id,
            kind: .message,
            authorBadges: [],
            originalBadges: badges,
            authorUserId: userId,
            authorDisplayName: displayName.isEmpty ? login : displayName,
            authorUserLogin: login,
            authorColor: color,
            runs: Normalizer.wordRuns(text: text),
            isHighlighted: false,
            timestamp: .now,
            deliveryState: .sending,
            replyParent: reply?.replyParent
        )
    }
}
