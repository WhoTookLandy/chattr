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

    /// User ID of the author. Used to match against
    /// `clear_user_messages` events (mod timeouts/bans hide all messages
    /// from one user at once). Empty for `.systemBubble` lines that don't
    /// have a single author (charity events, etc.).
    public let authorUserId: String

    /// User-display name (the capitalization the user picked at signup —
    /// "xQc" not "xqc"). Already de-decorated of any IRC-era affectations.
    public let authorDisplayName: String

    /// The chatter's lowercase login ("derek"), the unique handle used for
    /// @-mentions and Helix lookups. Distinct from `authorDisplayName`,
    /// which may be a localized non-Latin name ("デレク") or just a
    /// capitalization variant. Empty for system/bubble lines that have no
    /// single inline author. The renderer uses it to annotate localized
    /// names — see `ChatAppearance.loginAnnotation`.
    public let authorUserLogin: String

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

    /// True when this line arrived via a rustlog history fetch (join
    /// backfill or reconnect gap-fill) rather than live over EventSub.
    /// The renderer dims historical rows slightly so it's immediately
    /// legible which part of the transcript the user actually witnessed
    /// — everything above a "New" divider reads as history at a glance.
    /// `var` (like `kind` / `deliveryState`) so the ingest path can stamp
    /// it after normalization without a full memberwise copy.
    public var isHistorical: Bool

    /// Reply attachment, populated when this message is itself a reply
    /// to another message. The renderer uses it to draw a quoted
    /// preview above the message body (similar to Twitch web's
    /// threaded display); `viewThread` machinery uses
    /// `threadRootMessageId` to group lines by thread.
    ///
    /// `nil` for non-reply messages (the vast majority of chat) and
    /// for the `.subBubble` / `.raidBubble` / `.systemBubble` /
    /// `.deletedPlaceholder` kinds. Renderers should treat the field
    /// as purely informational — no behavior depends on it being set
    /// or unset for any specific kind.
    public let replyParent: ReplyParent?

    /// Twitch reply metadata: which message this is responding to AND
    /// what thread it belongs to. Twitch distinguishes between the
    /// immediate parent (the line you tapped Reply on) and the thread
    /// root (the message that started the whole thread). For
    /// A → B → C, B's parent is A and C's parent is B; both B and C
    /// share thread-root A.
    public struct ReplyParent: Sendable, Equatable, Hashable {
        /// The message ID of the immediate parent — the one whose
        /// "Reply" button the sender tapped. Used for rendering "in
        /// reply to <X>" context AND for opening the thread view at
        /// the right scroll position.
        public let parentMessageId: String

        /// Display name of the parent message's author.
        public let parentAuthorDisplayName: String

        /// The parent message's body text (Twitch sends a plain-text
        /// excerpt — we render it as-is in the quoted preview without
        /// re-tokenizing through the Normalizer).
        public let parentBody: String

        /// The thread's root message ID. Equal to `parentMessageId`
        /// when this is a direct reply to a non-reply; differs when
        /// it's a reply-to-a-reply. Used by `viewThread` to group all
        /// messages in the same chain.
        public let threadRootMessageId: String

        public init(
            parentMessageId: String,
            parentAuthorDisplayName: String,
            parentBody: String,
            threadRootMessageId: String
        ) {
            self.parentMessageId = parentMessageId
            self.parentAuthorDisplayName = parentAuthorDisplayName
            self.parentBody = parentBody
            self.threadRootMessageId = threadRootMessageId
        }
    }

    /// Per-line delivery lifecycle. Received messages are always
    /// `.delivered` (the default — all existing Normalizer call sites
    /// produce delivered lines without any code change). The other two
    /// states only apply to messages WE sent:
    ///
    ///   - `.sending` — optimistic row inserted by `TabChatModel.send`,
    ///     waiting for Twitch to broadcast the canonical echo.
    ///   - `.failed` — Helix returned `isSent=false` or threw; the row
    ///     stays on screen with a red treatment + tap-to-retry instead
    ///     of vanishing. Carries the reason text (for the inline label)
    ///     and the original draft text (so retry doesn't require
    ///     remembering what was typed).
    ///
    /// Stored as a separate axis from `kind` because they're orthogonal:
    /// you can in principle have a `.sending .subBubble` (we don't today,
    /// but the type doesn't prevent it) and a `.failed .message` is the
    /// common case for the retry UI.
    public var deliveryState: DeliveryState

    /// Three-state delivery lifecycle. See `deliveryState` for the
    /// semantics; renderers can switch on this to produce dimmed/error
    /// treatments without inspecting any other field.
    public enum DeliveryState: Sendable, Equatable, Hashable {
        case delivered
        case sending
        case failed(reason: String, retryText: String)
    }

    /// What types of line we can render. The renderer dispatches on this
    /// to choose between an inline chat row and a styled bubble row.
    ///
    /// Adding a new case here is a load-bearing change — the renderer's
    /// `switch` becomes non-exhaustive and Swift refuses to compile until
    /// the case is wired up visually. That's intentional: new system-message
    /// types should never silently fall back to "looks like a chat row."
    public enum Kind: Sendable, Equatable, Hashable {
        /// Regular chat message — render `authorBadges`, `authorDisplayName`,
        /// and `runs` inline.
        case message

        /// A sub/resub/gift-sub/Prime/announcement notification. Renders
        /// as a tinted bubble row with a Twitch-formatted system message
        /// and (for resubs with a user message) the user's text below.
        case subBubble(SubBubble)

        /// Someone raided this channel. Renders as a tinted bubble row
        /// with the raider's name + viewer count.
        case raidBubble(RaidBubble)

        /// An unstructured system notice (announcement, pay-it-forward,
        /// charity donation, bits-badge-tier, etc.). Renders as a plain
        /// tinted bubble with the Twitch-formatted system message —
        /// distinct treatment isn't worth the per-case carry today.
        case systemBubble(text: String)

        /// A message was deleted (moderation action). The original
        /// content stays in `runs` but the renderer strikethroughs and
        /// dims it. Mutation in place — we don't drop the row because
        /// the user is mid-scroll and a vanishing row is disorienting.
        case deletedPlaceholder

        /// The red "New" rule separating messages from before the user
        /// was watching (rustlog backfill on join, or a reconnect gap-fill)
        /// from live messages. Carries no content — the row is purely the
        /// line + caption; `runs` is empty and author fields are blank.
        case newMessagesDivider
    }

    /// Payload for a `.subBubble` line: a sub, resub, gift sub, prime
    /// upgrade, or community gift. Drives a tinted bubble row that shows
    /// "X subscribed at Tier Y for Z months" plus an optional user message
    /// (for resubs that include text).
    ///
    /// Twitch produces a pre-formatted `systemMessage` for every
    /// notification — we keep it on the bubble as the canonical text.
    /// The other fields (chatterDisplayName, tier, etc.) are there for
    /// custom layouts or analytics, but the MVP just renders
    /// `systemMessage` directly.
    public struct SubBubble: Sendable, Equatable, Hashable {
        public let chatterDisplayName: String
        public let tier: Tier
        public let monthsCount: Int?         // resub cumulative months; nil for first sub
        public let isResub: Bool
        public let isGift: Bool
        public let isPrime: Bool
        public let systemMessage: String     // Twitch-formatted, ready to render
        public let userMessage: String?      // Resub text (e.g., "thanks for the stream!"); nil otherwise

        public enum Tier: String, Sendable, Hashable {
            case prime
            case t1
            case t2
            case t3
        }

        public init(
            chatterDisplayName: String,
            tier: Tier,
            monthsCount: Int?,
            isResub: Bool,
            isGift: Bool,
            isPrime: Bool,
            systemMessage: String,
            userMessage: String?
        ) {
            self.chatterDisplayName = chatterDisplayName
            self.tier = tier
            self.monthsCount = monthsCount
            self.isResub = isResub
            self.isGift = isGift
            self.isPrime = isPrime
            self.systemMessage = systemMessage
            self.userMessage = userMessage
        }
    }

    /// Payload for a `.raidBubble`: someone raided this channel, bringing
    /// N viewers with them. Drives a tinted bubble row.
    public struct RaidBubble: Sendable, Equatable, Hashable {
        public let fromBroadcasterDisplayName: String
        public let viewers: Int

        public init(fromBroadcasterDisplayName: String, viewers: Int) {
            self.fromBroadcasterDisplayName = fromBroadcasterDisplayName
            self.viewers = viewers
        }
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

    /// Returns a copy with `kind` flipped to `.deletedPlaceholder`. Used
    /// when a `channel.chat.message_delete` / `channel.chat.clear` /
    /// `channel.chat.clear_user_messages` event arrives — we DON'T remove
    /// the row (vanishing mid-scroll is disorienting), we flip it. The
    /// renderer reads the kind and strikethroughs the content.
    ///
    /// Idempotent: deleting a deleted line is a no-op (same returned value).
    /// `.newMessagesDivider` rows are also a no-op — the divider isn't a
    /// message, so a chat-clear (which calls this on every line) must leave
    /// the rule intact rather than render it as struck-through nothing.
    public func withDeletedPlaceholder() -> ChatLine {
        if case .newMessagesDivider = kind { return self }
        return ChatLine(
            id: id,
            kind: .deletedPlaceholder,
            authorBadges: authorBadges,
            originalBadges: originalBadges,
            authorUserId: authorUserId,
            authorDisplayName: authorDisplayName,
            authorUserLogin: authorUserLogin,
            authorColor: authorColor,
            runs: runs,                       // keep content for strikethrough display
            isHighlighted: false,             // deleted messages aren't highlighted
            timestamp: timestamp,
            deliveryState: deliveryState,    // preserve send-state across delete
                                              // (a row that was .failed when a mod
                                              // deleted it stays failed — though
                                              // the strikethrough takes visual
                                              // priority over the retry icon)
            isHistorical: isHistorical,       // a deleted backfill row stays dimmed
            replyParent: replyParent          // preserve thread membership too —
                                              // a deleted reply still belongs to
                                              // its thread for view-thread purposes
        )
    }

    public init(
        id: String,
        kind: Kind = .message,
        authorBadges: [AuthorBadge] = [],
        originalBadges: [ChatBadge] = [],
        authorUserId: String = "",
        authorDisplayName: String,
        authorUserLogin: String = "",
        authorColor: String = "",
        runs: [LineRun],
        isHighlighted: Bool = false,
        timestamp: Date = .now,
        deliveryState: DeliveryState = .delivered,
        isHistorical: Bool = false,
        replyParent: ReplyParent? = nil
    ) {
        self.id = id
        self.kind = kind
        self.authorBadges = authorBadges
        self.originalBadges = originalBadges
        self.authorUserId = authorUserId
        self.authorDisplayName = authorDisplayName
        self.authorUserLogin = authorUserLogin
        self.authorColor = authorColor
        self.runs = runs
        self.isHighlighted = isHighlighted
        self.timestamp = timestamp
        self.deliveryState = deliveryState
        self.isHistorical = isHistorical
        self.replyParent = replyParent
    }
}
