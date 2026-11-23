import Foundation
import EmoteSources
import TwitchKit

/// Pure (sync, stateless) normalization of `TwitchKit.ChatMessage` →
/// `ChatLine`. Caller passes in the EmoteIndex snapshot, current user
/// login, and any highlight keywords; the function returns a fully
/// display-ready `ChatLine` value.
///
/// ## Why this is not an instance / not an actor
///
/// The function has no per-instance state — every call is determined
/// entirely by its inputs. Making it a static free function:
///
///   - Removes the temptation to thread an instance through every view
///     layer that needs to renormalize.
///   - Keeps the test surface tiny: each test is a one-liner with
///     fixture-in / expectation-out.
///   - Sidesteps the actor-isolation question. The caller (usually a
///     `@MainActor @Observable` view model) reads `EmoteIndex.snapshot()`
///     *once* before calling, then passes the resulting `[String: Emote]`
///     dictionary in. No actor hop on the chat hot path.
///
/// ## Why it takes a `snapshot: [String: Emote]` not the EmoteIndex actor
///
/// Two reasons:
///
///   1. Decoupling. `Normalizer` shouldn't know about actors. By taking
///      a plain dictionary, this function compiles even in contexts that
///      can't `await` an actor read (e.g., a synchronous SwiftUI
///      `.onChange` handler). The caller is responsible for fetching a
///      fresh snapshot when they want one.
///
///   2. Snapshot stability. Even if the underlying EmoteIndex updates
///      mid-message, all tokens in one `normalize(...)` call see the
///      same snapshot. No "first half of message saw old emotes, second
///      half saw new emotes" inconsistency.
public enum Normalizer {

    /// Normalize one `ChatMessage` into a `ChatLine`.
    ///
    /// - Parameters:
    ///   - message: The TwitchKit chat message as received from EventSub.
    ///   - emoteSnapshot: The current emote name → Emote map. Typically
    ///     `await EmoteIndex.snapshot()` (or its nonisolated `snapshot()`
    ///     for hot paths). An empty map disables third-party rendering
    ///     gracefully — all tokens stay as plain text runs.
    ///   - currentUserLogin: The signed-in user's lowercase login.
    ///     Used to flag `.mention(isMe: true)` on self-mentions.
    ///   - timestamp: When the message was sent — `tmi-sent-ts` for IRC
    ///     history, the receipt time captured once for live events. Required
    ///     (no `.now` default): normalizing the same message twice must yield
    ///     equal lines, so the caller owns the clock.
    ///   - highlightKeywords: Case-insensitive substrings that highlight
    ///     a message. Empty array disables keyword highlighting. Hot paths
    ///     that apply keywords separately use a prebuilt `HighlightMatcher`.
    ///   - badges: Pre-resolved `AuthorBadge`s — caller does the lookup
    ///     via `ChatBadgeStore.entries(for:)` and hands them in.
    /// - Returns: A fully tokenized, display-ready `ChatLine`.
    public static func normalize(
        message: ChatMessage,
        emoteSnapshot: [String: Emote],
        currentUserLogin: String,
        timestamp: Date,
        highlightKeywords: [String] = [],
        badges: [ChatLine.AuthorBadge] = []
    ) -> ChatLine {
        // Walk Twitch's pre-tokenized fragments, expanding each one into
        // zero-or-more LineRuns.
        let tokenized = tokenizeFragments(
            message.message.fragments,
            emoteSnapshot: emoteSnapshot,
            currentUserLogin: currentUserLogin
        )
        var runs = tokenized.runs
        let sawSelfMention = tokenized.sawSelfMention

        // Twitch's IRC convention prefixes reply bodies with
        // "@parentLogin " so legacy chat clients see who's being replied
        // to even without UI support. We render the quoted-parent block
        // separately above the message body now, so that leading
        // mention is redundant + visually noisy. Strip it here so the
        // body reads as just the user's actual reply text.
        //
        // We only strip when the runs START with the matching mention —
        // keeps the strip surgical instead of removing every leading @
        // in any reply.
        if message.reply != nil {
            runs = Self.stripLeadingReplyMention(
                runs: runs,
                parentLogin: message.reply?.parentUserLogin ?? ""
            )
        }

        // Highlight detection — message is highlighted if it mentions me
        // OR if any contiguous span of text words contains a configured
        // keyword (case-insensitive substring match; phrases match across
        // word runs). The keyword check is bypassed when the keyword
        // list is empty, which is the common case.
        let isHighlighted = sawSelfMention
            || (!highlightKeywords.isEmpty && HighlightMatcher(keywords: highlightKeywords).matches(runs))

        // Extract reply metadata if Twitch tagged this message as a reply.
        // Stored on the ChatLine so the renderer can show a quoted-preview
        // block above the message body AND so the thread-view sheet
        // (`viewThread`) can filter lines by `threadRootMessageId`.
        let replyParent = message.reply.map { reply in
            ChatLine.ReplyParent(
                parentMessageId: reply.parentMessageId,
                parentAuthorDisplayName: reply.parentUserName,
                parentBody: reply.parentMessageBody,
                threadRootMessageId: reply.threadMessageId
            )
        }

        return ChatLine(
            id: message.messageId,
            kind: .message,
            authorBadges: badges,
            originalBadges: message.badges,
            authorUserId: message.chatterUserId,
            authorDisplayName: message.chatterUserName,
            authorUserLogin: message.chatterUserLogin,
            authorColor: message.color,
            runs: runs,
            isHighlighted: isHighlighted,
            timestamp: timestamp,
            replyParent: replyParent
        )
    }

    // MARK: - System notifications → ChatLine bubbles

    /// Convert a `channel.chat.notification` EventSub payload into a
    /// `ChatLine` with one of the bubble `Kind` cases. Returns nil for
    /// notification types we don't yet render (kept narrow on purpose —
    /// it's better to skip an unknown notice than render a half-formed
    /// row).
    ///
    /// ## Notice-type dispatch
    ///
    /// `EventSubChatNotification.noticeType` is a string like "sub",
    /// "resub", "sub_gift", "raid", "announcement", "charity_donation",
    /// etc. Different optional fields are populated depending on the
    /// type — we read whichever is present.
    ///
    /// `timestamp` is the receipt time the caller captured for the event
    /// (the payload carries no send time).
    public static func line(
        from notification: EventSubChatNotification,
        emoteSnapshot: [String: Emote] = [:],
        currentUserLogin: String = "",
        timestamp: Date
    ) -> ChatLine? {
        // Dispatch on noticeType to find the right payload and build the
        // matching bubble kind.
        let kind: ChatLine.Kind
        var runs: [LineRun] = []
        var isHighlighted = false

        switch notification.noticeType {
        case "sub":
            // First-time sub. The `sub` optional carries tier + duration.
            guard let sub = notification.sub else { return nil }
            kind = .subBubble(.init(
                chatterDisplayName: notification.chatterUserName,
                tier: tier(from: sub.subTier, isPrime: sub.isPrime),
                monthsCount: sub.durationMonths,
                isResub: false,
                isGift: false,
                isPrime: sub.isPrime,
                systemMessage: notification.systemMessage,
                userMessage: nil
            ))

        case "resub":
            guard let resub = notification.resub else { return nil }
            // Resubs sometimes carry the user's accompanying text in
            // `message.text` (the part after the cumulative-months
            // template). We pass it through as `userMessage` so the
            // renderer can show it under the system text.
            let userMsg = notification.message.text.isEmpty ? nil : notification.message.text
            kind = .subBubble(.init(
                chatterDisplayName: notification.chatterUserName,
                tier: tier(from: resub.subTier, isPrime: resub.isPrime),
                monthsCount: resub.cumulativeMonths,
                isResub: true,
                isGift: resub.isGift,
                isPrime: resub.isPrime,
                systemMessage: notification.systemMessage,
                userMessage: userMsg
            ))

        case "sub_gift":
            guard let gift = notification.subGift else { return nil }
            kind = .subBubble(.init(
                chatterDisplayName: notification.chatterUserName,
                tier: tier(from: gift.subTier, isPrime: false),
                monthsCount: gift.durationMonths,
                isResub: false,
                isGift: true,
                isPrime: false,
                systemMessage: notification.systemMessage,
                userMessage: nil
            ))

        case "community_sub_gift":
            // Community gift: "X gifted N subs to the community" — no
            // individual recipient to call out. Treat as a generic sub
            // bubble using the community payload.
            guard let community = notification.communitySubGift else { return nil }
            kind = .subBubble(.init(
                chatterDisplayName: notification.chatterUserName,
                tier: tier(from: community.subTier, isPrime: false),
                monthsCount: nil,
                isResub: false,
                isGift: true,
                isPrime: false,
                systemMessage: notification.systemMessage,
                userMessage: nil
            ))

        case "raid":
            // Raid coming IN to the channel via the notification topic.
            // (The separate channel.raid topic also exists — same data
            // in a different shape; we render either as a raidBubble.)
            guard let raid = notification.raid else { return nil }
            kind = .raidBubble(.init(
                fromBroadcasterDisplayName: raid.userName,
                viewers: raid.viewerCount
            ))

        case "announcement":
            // Twitch sends an empty `system_message` on chat announcements and
            // puts the actual announcement copy (with Twitch emote/mention
            // fragments) in `message`. Tokenize through the same fragment +
            // third-party emote pipeline as regular chat messages so Twitch,
            // 7TV, BTTV, and FFZ emotes all render inline.
            if !notification.message.fragments.isEmpty {
                let tokenized = tokenizeFragments(
                    notification.message.fragments,
                    emoteSnapshot: emoteSnapshot,
                    currentUserLogin: currentUserLogin
                )
                runs = tokenized.runs
                isHighlighted = tokenized.sawSelfMention
            } else {
                let fallbackText = notification.message.text.isEmpty
                    ? notification.systemMessage
                    : notification.message.text
                runs = wordRuns(text: fallbackText, emoteSnapshot: emoteSnapshot)
            }
            guard !runs.isEmpty else { return nil }
            kind = .announcementBubble(.init(
                color: .init(twitchColor: notification.announcement?.color)
            ))

        case "charity_donation", "bits_badge_tier",
             "prime_paid_upgrade", "gift_paid_upgrade", "pay_it_forward":
            // Unstructured-but-still-visible notices. Render the
            // Twitch-formatted text in a generic system bubble.
            kind = .systemBubble(text: notification.systemMessage)

        default:
            // Unknown / future notice types — skip rather than render
            // half-formed. Worth logging in the caller.
            return nil
        }

        return ChatLine(
            id: notification.messageId,
            kind: kind,
            originalBadges: notification.badges,
            authorUserId: notification.chatterUserId,
            authorDisplayName: notification.chatterUserName,
            authorUserLogin: notification.chatterUserLogin,
            authorColor: notification.color ?? "",
            runs: runs,
            isHighlighted: isHighlighted,
            timestamp: timestamp
        )
    }

    /// Convert a `channel.raid` EventSub event (someone raiding INTO the
    /// channel we're watching) into a raidBubble `ChatLine`. Distinct
    /// from the `raid` notice inside `EventSubChatNotification` —
    /// channel.raid is the dedicated topic with simpler payload.
    ///
    /// The payload has no message id, so the caller mints one — once, when
    /// the event arrives (see `raidLineID`) — and stores the resulting line.
    /// Minting it here from the clock gave the same raid a new row identity
    /// every time it was re-normalized (each tab re-prime).
    public static func line(from raid: EventSubRaid, id: String, timestamp: Date) -> ChatLine {
        ChatLine(
            id: id,
            kind: .raidBubble(.init(
                fromBroadcasterDisplayName: raid.fromBroadcasterUserName,
                viewers: raid.viewers
            )),
            authorUserId: raid.fromBroadcasterUserId,
            authorDisplayName: raid.fromBroadcasterUserName,
            runs: [],
            timestamp: timestamp
        )
    }

    /// Row id for a `channel.raid` event received at `receivedAt`: the
    /// raider plus the arrival millisecond. Call once per event.
    public static func raidLineID(fromBroadcasterUserId: String, receivedAt: Date) -> String {
        "raid-\(fromBroadcasterUserId)-\(Int(receivedAt.timeIntervalSince1970 * 1000))"
    }

    /// Map TwitchKit's `SubscriptionTier` enum + `isPrime` flag → our
    /// internal `Tier`. The `isPrime` flag wins over the tier value when
    /// set, because Twitch reports Prime subs as Tier 1 via the tier
    /// value alone (the prime designation is carried separately).
    /// `.unknown` falls back to `.t1` — better to render *something*
    /// than skip the bubble entirely.
    private static func tier(from twitchTier: SubscriptionTier, isPrime: Bool) -> ChatLine.SubBubble.Tier {
        if isPrime { return .prime }
        switch twitchTier {
        case .tier1: return .t1
        case .tier2: return .t2
        case .tier3: return .t3
        case .prime: return .prime
        case .unknown: return .t1
        }
    }

    // MARK: - Tokenization

    /// Expand Twitch's pre-tokenized fragments into word-level `LineRun`s,
    /// upgrading matching words against `emoteSnapshot` and flagging any
    /// self-mention against `currentUserLogin`.
    ///
    /// Text content is NOT tokenized per fragment: adjacent text-ish
    /// fragments are buffered into `pendingText` and tokenized as one
    /// stream when a non-text fragment (or end of message) is hit.
    /// Word boundaries come from whitespace in the content, never
    /// from fragment seams — a word Twitch splits across two text
    /// fragments must reassemble, not render as two half-words.
    private static func tokenizeFragments(
        _ fragments: [ChatFragment],
        emoteSnapshot: [String: Emote],
        currentUserLogin: String
    ) -> (runs: [LineRun], sawSelfMention: Bool) {
        var runs: [LineRun] = []
        var sawSelfMention = false
        var pendingText = ""

        func flushPendingText() {
            guard !pendingText.isEmpty else { return }
            tokenizeWords(text: pendingText, emoteSnapshot: emoteSnapshot, into: &runs)
            pendingText = ""
        }

        for fragment in fragments {
            switch fragment.type {
            case .text:
                pendingText += fragment.text

            case .emote:
                // Twitch-native emote, pre-resolved by Twitch's event.
                if let ref = fragment.emote {
                    flushPendingText()
                    runs.append(.twitchEmote(reference: ref, displayName: fragment.text))
                } else {
                    // Defensive: if Twitch ever sends a .emote fragment
                    // without an EmoteReference (shouldn't happen, but
                    // future schema changes could), fall back to text.
                    pendingText += fragment.text
                }

            case .mention:
                // Twitch already resolved @username for us — extract the
                // login from the reference, mark `isMe` if it matches.
                if let mention = fragment.mention {
                    let isMe = !currentUserLogin.isEmpty
                        && mention.userLogin.caseInsensitiveCompare(currentUserLogin) == .orderedSame
                    if isMe { sawSelfMention = true }
                    flushPendingText()
                    runs.append(.mention(login: mention.userLogin, isMe: isMe))
                } else {
                    pendingText += fragment.text
                }

            case .cheermote:
                if let cheer = fragment.cheermote {
                    flushPendingText()
                    runs.append(.cheermote(prefix: cheer.prefix, bits: cheer.bits, tier: cheer.tier))
                } else {
                    pendingText += fragment.text
                }

            case .unknown:
                // Future Twitch fragment types we don't yet handle —
                // render the surface text rather than dropping content.
                pendingText += fragment.text
            }
        }
        flushPendingText()
        return (runs, sawSelfMention)
    }

    /// Tokenize a plain string into word-level runs. Public entry point
    /// for callers that have raw text rather than a `ChatMessage` —
    /// e.g. `ChatTranscriptModel`'s optimistic-send row.
    public static func wordRuns(
        text: String,
        emoteSnapshot: [String: Emote] = [:]
    ) -> [LineRun] {
        var runs: [LineRun] = []
        tokenizeWords(text: text, emoteSnapshot: emoteSnapshot, into: &runs)
        return runs
    }

    /// Split a string into whitespace-delimited words: one `.emote` run
    /// per word that resolves in the snapshot, one `.text` run per word
    /// that doesn't. Whitespace is DROPPED — runs never contain spaces.
    ///
    /// Word-level runs are what make chat wrapping work: the renderer's
    /// `FlowLayout` can only wrap *between* runs, so a multi-word run
    /// would wrap as one atomic block (orphaned usernames, giant gaps).
    /// One run per word lets lines break exactly like Twitch web. The
    /// inter-word gap is reconstructed by the layout's `spacing`, which
    /// means consecutive whitespace collapses — same tradeoff Twitch's
    /// own renderer makes.
    ///
    /// Two paths with identical output:
    ///   - **ASCII** (nearly all chat): one pass over UTF-8 bytes, slicing
    ///     each word out of the original string. Every ASCII byte is its own
    ///     grapheme (CR LF is the one multi-scalar ASCII cluster, and both
    ///     halves are whitespace), so byte boundaries ARE Character
    ///     boundaries and the split matches the Character walk exactly.
    ///   - **Anything else**: the Character walk, which is what decides how
    ///     whitespace combines with neighbouring scalars (a space followed by
    ///     a combining mark is one non-splittable grapheme, etc.).
    private static func tokenizeWords(
        text: String,
        emoteSnapshot: [String: Emote],
        into runs: inout [LineRun]
    ) {
        func emit(_ word: String) {
            if let emote = emoteSnapshot[word] {
                runs.append(.emote(emote))
            } else {
                runs.append(.text(word))
            }
        }

        let utf8 = text.utf8
        if !utf8.contains(where: { $0 >= 0x80 }) {
            var wordStart: String.Index?
            var index = utf8.startIndex
            while index != utf8.endIndex {
                if isASCIIWhitespace(utf8[index]) {
                    if let start = wordStart {
                        emit(String(text[start..<index]))
                        wordStart = nil
                    }
                } else if wordStart == nil {
                    wordStart = index
                }
                index = utf8.index(after: index)
            }
            if let start = wordStart {
                emit(String(text[start..<utf8.endIndex]))
            }
            return
        }

        var currentWord = ""
        for ch in text {
            if ch.isWhitespace {
                if !currentWord.isEmpty {
                    emit(currentWord)
                    currentWord = ""
                }
            } else {
                currentWord.append(ch)
            }
        }
        if !currentWord.isEmpty { emit(currentWord) }
    }

    /// The ASCII members of Unicode's White_Space property — exactly the
    /// ASCII scalars `Character.isWhitespace` accepts: TAB, LF, VT, FF, CR,
    /// and SPACE.
    @inline(__always)
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    // MARK: - Post-processing

    /// If `runs` starts with a `.mention` of the parent's login (Twitch's
    /// legacy "@parentLogin " prefix that backs up the reply metadata for
    /// clients without UI support), strip it so the user-facing body
    /// starts at the actual response text. Word-level runs never carry
    /// whitespace, so dropping the mention run is the whole job.
    ///
    /// Examples (parentLogin = "xqc"):
    ///   [.mention("xqc"), .text("hello"), .text("there")] → [.text("hello"), .text("there")]
    ///   [.text("hey"), .mention("xqc"), ...]              → unchanged (mention isn't leading)
    ///   [.mention("ninja"), .text("hi")]                  → unchanged (mention isn't the parent)
    ///
    /// Conservative: only strips when the mention is THE first run
    /// and matches the parent. Avoids accidentally stripping a
    /// deliberate "@someoneElse" the user wrote on purpose.
    private static func stripLeadingReplyMention(runs: [LineRun], parentLogin: String) -> [LineRun] {
        guard !parentLogin.isEmpty,
              let first = runs.first,
              case .mention(let login, _) = first,
              login.caseInsensitiveCompare(parentLogin) == .orderedSame else {
            return runs
        }
        return Array(runs.dropFirst())
    }
}
