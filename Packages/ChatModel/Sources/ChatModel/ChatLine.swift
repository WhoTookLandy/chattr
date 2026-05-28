import Foundation
import TwitchKit

// TwitchKit imported for `ChatBadge` — we carry the original (unresolved)
// badge array on the line so consumers with a badge resolver in scope
// (chattr's `ChatBadgeStore` lookup) can map setId/id → CDN URL on the
// rendering side. Keeping the raw badges here (vs pre-resolving them into
// `AuthorBadge`) means the Normalizer doesn't have to know about
// `ChatBadgeStore`, preserving the "ChatModel doesn't depend on Features"
// invariant.

/// One display-ready line of chat. The Normalizer produces these from
/// `TwitchKit.ChatMessage`; the renderer (`ChatRow` in the Features
/// package) consumes them.
///
/// ## Why duplicate `TwitchKit.ChatMessage`
///
/// A `ChatMessage` is *what the server sent*; a `ChatLine` is *what we
/// want to render*. They have very different shapes once we factor in:
///
///   - 3rd-party emote resolution (text tokens upgraded to `.emote` runs)
///   - System messages (subs/raids/deletes → bubble kinds, no fragments)
///   - Highlighting (mention-of-me / keyword match → visual emphasis)
///   - Localization-ready badges (each `ChatBadge.setId/id` resolved to
///     a name + URL via `ChatBadgeStore` upstream)
///
/// Keeping these layers separate means the renderer has a stable input
/// shape and the data layer can evolve without churning every view file.
///
/// ## Why `Hashable + Equatable`
///
/// `ForEach(chatLines) { line in ... }` needs `Identifiable` for stable
/// row identity (we provide `id` via `messageId`), and `Equatable` for
/// SwiftUI to skip diffs when nothing changed. Free-default `Hashable`
/// conformance also makes ChatLine usable as a key/value type if a future
/// commit needs that.
// `Hashable` is intentionally omitted — `LineRun.twitchEmote` carries a
// `TwitchKit.EmoteReference` which is `Equatable` but not `Hashable`,
// blocking synthesis. SwiftUI's `ForEach` uses `Identifiable.id` for
// stable row identity, so `Hashable` isn't needed.
public struct ChatLine: Sendable, Equatable, Identifiable {

    /// The Twitch `message_id`. Stable across the lifetime of the message,
    /// including any future "this message was deleted" mutation — when a
    /// delete event arrives, we mutate the line's `kind` in place rather
    /// than removing it, so the user sees the strikethrough placeholder
    /// in context.
    public let id: String

    /// What this line represents. `.message` is the common case (a chat
    /// message). The other cases are reserved for Phase 2.3 (sub/raid
    /// bubbles, delete placeholders) and added incrementally — the
    /// renderer's `switch` will fail to compile when they land,
    /// forcing the new visual treatment to be wired up.
    public var kind: Kind

    /// Resolved chat badges (broadcaster, mod, VIP, sub tier, etc.) —
    /// pre-mapped from `ChatBadge.setId/id` → `(title, url)`. Populated
    /// by callers who have a badge resolver in scope (chattr's
    /// `ChatBadgeStore`). Empty when the resolver isn't available — the
    /// `originalBadges` field below is the unresolved fallback.
    public let authorBadges: [AuthorBadge]

    /// The raw (unresolved) badges from the source `ChatMessage.badges`,
    /// passed through verbatim. Consumers with a badge resolver can map
    /// these to renderable shapes at render time; consumers without one
    /// (e.g., logging, testing) still have the structured info.
    ///
    /// Why both this AND `authorBadges`: the resolver might be loading
    /// asynchronously when the Normalizer runs (badges fetched via
    /// Helix, can race the EmoteIndex). Carrying the raw set lets a
    /// later resolver fill in `authorBadges` retroactively without
    /// losing data.
    public let originalBadges: [ChatBadge]

    /// User-display name (the capitalization the user picked at signup —
    /// "xQc" not "xqc"). Already de-decorated of any IRC-era affectations.
    public let authorDisplayName: String

    /// User-picked color, as a `#RRGGBB` hex. Empty when the user hasn't
    /// picked one — the renderer falls back to `.primary` in that case.
    public let authorColor: String

    /// The ordered runs that compose the message body. Empty for system
    /// kinds (sub bubble, raid bubble, etc.) where the visual is generated
    /// from the kind payload, not from text content.
    public let runs: [LineRun]

    /// True when this line is "highlighted" — currently:
    ///   - any `LineRun.mention(isMe: true)` in `runs`, OR
    ///   - any text run contains a configured highlight keyword
    ///     (case-insensitive substring; configured per-user later).
    ///
    /// Drives the visual emphasis on the row (background tint, accent
    /// border, optional sound — none of that here, just the flag).
    public let isHighlighted: Bool

    /// When the message arrived. Used for relative-timestamp formatting
    /// and for tie-breaking in any future "merge two channels in one tab"
    /// sorted-merge logic.
    public let timestamp: Date

    /// What types of line we can render. Extensible enum — new bubble
    /// types added here don't break the renderer's call sites (the
    /// `switch` becomes non-exhaustive and demands attention).
    public enum Kind: Sendable, Equatable, Hashable {
        /// Regular chat message — render `authorBadges`, `authorDisplayName`,
        /// and `runs` inline.
        case message
        // Future (Phase 2.3 Task 17-19):
        // case subBubble(SubBubble)
        // case raidBubble(RaidBubble)
        // case deletedPlaceholder
    }

    /// A badge resolved to renderable shape. Mirrors what
    /// `ChatBadgeStore.entries(for:)` already returns in the Features
    /// layer; lifted here so ChatLine is self-contained.
    public struct AuthorBadge: Sendable, Equatable, Hashable {
        public let setId: String     // e.g. "moderator", "subscriber"
        public let title: String     // e.g. "Moderator", "12-Month Subscriber"
        public let imageURL: URL     // CDN URL for the 2x size

        public init(setId: String, title: String, imageURL: URL) {
            self.setId = setId
            self.title = title
            self.imageURL = imageURL
        }
    }

    public init(
        id: String,
        kind: Kind = .message,
        authorBadges: [AuthorBadge] = [],
        originalBadges: [ChatBadge] = [],
        authorDisplayName: String,
        authorColor: String = "",
        runs: [LineRun],
        isHighlighted: Bool = false,
        timestamp: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.authorBadges = authorBadges
        self.originalBadges = originalBadges
        self.authorDisplayName = authorDisplayName
        self.authorColor = authorColor
        self.runs = runs
        self.isHighlighted = isHighlighted
        self.timestamp = timestamp
    }
}
