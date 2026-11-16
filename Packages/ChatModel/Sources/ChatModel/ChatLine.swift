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
/// ## Why `Equatable + Identifiable` (and not `Hashable`)
///
/// `ForEach(chatLines) { line in ... }` needs `Identifiable` for stable
/// row identity (we provide `id` via `messageId`), and `Equatable` lets
/// SwiftUI skip diffs when nothing changed. `Hashable` is intentionally
/// omitted — `LineRun.twitchEmote` carries a `TwitchKit.EmoteReference`
/// which is `Equatable` but not `Hashable`, blocking synthesis; `ForEach`
/// keys rows off `id`, so hashing is never needed.
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

    /// True when `authorDisplayName` is a genuinely localized variant of
    /// `authorUserLogin` (differs by more than capitalization) — i.e. the
    /// row should annotate the name with its login. Precomputed at init from
    /// the two name fields so the renderer's per-`body` username path skips
    /// the `displayName.lowercased() != login.lowercased()` comparison (two
    /// heap allocations) on the common case where they match. Mirrors the
    /// trigger in `ChatAppearance.loginAnnotation`; the renderer still calls
    /// that for the rare localized case to pick the display order.
    public let hasLocalizedDisplayName: Bool

    /// The ordered runs that compose the message body. Empty for system
    /// kinds (sub bubble, raid bubble, etc.) where the visual is generated
    /// from the kind payload, not from text content.
    public let runs: [LineRun]

    /// True when this line is "highlighted" — currently:
    ///   - any `LineRun.mention(isMe: true)` in `runs`, OR
    ///   - any text run contains a configured highlight keyword
    ///     (case-insensitive substring; see `HighlightMatcher`).
    ///
    /// Drives the visual emphasis on the row (background tint, accent
    /// border, optional sound — none of that here, just the flag).
    ///
    /// `var` (like `kind` / `isHistorical`) because the two halves are
    /// computed in different places: the channel session normalizes once
    /// for every tab and can only know the self-mention half (its account's
    /// login), while each transcript layers its own viewer-configured
    /// keywords on top without a full memberwise copy.
    public var isHighlighted: Bool

    /// When the message was sent: the IRC `tmi-sent-ts` for history, the
    /// session's receipt time (captured once, then stored with the line) for
    /// live events — TwitchKit doesn't surface EventSub's envelope time.
    /// Used for relative-timestamp formatting and for tie-breaking in any
    /// future "merge two channels in one tab" sorted-merge logic.
    ///
    /// Producers always pass it explicitly; the init's `.now` default is a
    /// convenience for fixtures and previews only — a line rebuilt from the
    /// same message must carry the same timestamp or it compares unequal.
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
    ///   - `.sending` — optimistic row inserted by `ChatTranscriptModel.send`,
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
    /// Named as a participle (`markingDeleted`, like `strippingNewlines`)
    /// because it's nonmutating — call sites read as a pipeline:
    /// `buffer.mutateAll { $0.markingDeleted() }`.
    ///
    /// Idempotent: deleting a deleted line is a no-op (same returned value).
    /// `.newMessagesDivider` rows are also a no-op — the divider isn't a
    /// message, so a chat-clear (which calls this on every line) must leave
    /// the rule intact rather than render it as struck-through nothing.
    public func markingDeleted() -> ChatLine {
        if case .newMessagesDivider = kind { return self }
        // Copy-and-flip rather than a memberwise rebuild: a chat-clear runs
        // this on every line in the window, and the init would recompute
        // `hasLocalizedDisplayName` for each one. Everything else carries
        // over as-is — content stays for the strikethrough, `deliveryState`
        // survives (a `.failed` row a mod deleted stays failed, though the
        // strikethrough takes visual priority), a deleted backfill row stays
        // dimmed, and a deleted reply still belongs to its thread.
        var deleted = self
        deleted.kind = .deletedPlaceholder
        deleted.isHighlighted = false   // deleted messages aren't highlighted
        return deleted
    }

    /// Returns a copy in `deliveryState` — and, when `id` is given, re-keyed
    /// to that id. The optimistic-send lifecycle uses it: a send that fails
    /// keeps its `pending-…` id and flips to `.failed`; a send whose echo
    /// never arrived settles as `.delivered` under its server-issued id.
    /// Everything else (content, author styling, timestamp, provenance,
    /// thread membership) carries over unchanged.
    ///
    /// A state-only change is a copy-and-set; a re-key needs the memberwise
    /// init because `id` is a `let` (identity changes are rare — once per
    /// stuck send — so the extra `hasLocalizedDisplayName` recompute is moot).
    public func with(deliveryState: DeliveryState, id newId: String? = nil) -> ChatLine {
        guard let newId, newId != id else {
            var copy = self
            copy.deliveryState = deliveryState
            return copy
        }
        return ChatLine(
            id: newId,
            kind: kind,
            authorBadges: authorBadges,
            originalBadges: originalBadges,
            authorUserId: authorUserId,
            authorDisplayName: authorDisplayName,
            authorUserLogin: authorUserLogin,
            authorColor: authorColor,
            runs: runs,
            isHighlighted: isHighlighted,
            timestamp: timestamp,
            deliveryState: deliveryState,
            isHistorical: isHistorical,
            replyParent: replyParent
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
        // Precompute the localized-name flag once — see the property doc.
        self.hasLocalizedDisplayName = Self.isLocalized(
            displayName: authorDisplayName,
            login: authorUserLogin
        )
        self.runs = runs
        self.isHighlighted = isHighlighted
        self.timestamp = timestamp
        self.deliveryState = deliveryState
        self.isHistorical = isHistorical
        self.replyParent = replyParent
    }

    /// `displayName.lowercased() != login.lowercased()`, without the two
    /// heap allocations on the common path. Logins are ASCII and most display
    /// names are their login re-capitalized, so an ASCII-only pair is
    /// compared byte-wise with ASCII case folding (identical to `lowercased()`
    /// for ASCII); anything non-ASCII takes the original allocating path so
    /// Unicode case mapping is unchanged.
    static func isLocalized(displayName: String, login: String) -> Bool {
        guard !displayName.isEmpty, !login.isEmpty else { return false }
        let display = displayName.utf8
        let loginBytes = login.utf8
        let isASCII = !display.contains { $0 >= 0x80 } && !loginBytes.contains { $0 >= 0x80 }
        guard isASCII else {
            return displayName.lowercased() != login.lowercased()
        }
        guard display.count == loginBytes.count else { return true }
        for (a, b) in zip(display, loginBytes) where asciiLowercase(a) != asciiLowercase(b) {
            return true
        }
        return false
    }

    private static func asciiLowercase(_ byte: UInt8) -> UInt8 {
        // "A"..."Z" → "a"..."z"; every other ASCII byte is its own lowercase.
        (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
    }
}
