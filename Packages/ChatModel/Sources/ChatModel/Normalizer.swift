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
    ///   - highlightKeywords: Case-insensitive substrings that highlight
    ///     a message. Empty array disables keyword highlighting.
    ///   - badges: Pre-resolved `AuthorBadge`s — caller does the lookup
    ///     via `ChatBadgeStore.entries(for:)` and hands them in.
    /// - Returns: A fully tokenized, display-ready `ChatLine`.
    public static func normalize(
        message: ChatMessage,
        emoteSnapshot: [String: Emote],
        currentUserLogin: String,
        highlightKeywords: [String] = [],
        badges: [ChatLine.AuthorBadge] = []
    ) -> ChatLine {
        // Walk Twitch's pre-tokenized fragments, expanding each one into
        // zero-or-more LineRuns. Accumulate into a working array so we
        // can coalesce adjacent text runs at the end.
        var runs: [LineRun] = []
        var sawSelfMention = false

        for fragment in message.message.fragments {
            switch fragment.type {
            case .text:
                // Plain text — split into whitespace-delimited tokens,
                // resolving each against the emote snapshot. Whitespace
                // *between* tokens is preserved in the output (otherwise
                // "lul Kappa w" would render as "lulKappaw" — no spaces).
                tokenize(
                    text: fragment.text,
                    emoteSnapshot: emoteSnapshot,
                    into: &runs
                )

            case .emote:
                // Twitch-native emote, pre-resolved by Twitch's event.
                if let ref = fragment.emote {
                    runs.append(.twitchEmote(reference: ref, displayName: fragment.text))
                } else {
                    // Defensive: if Twitch ever sends a .emote fragment
                    // without an EmoteReference (shouldn't happen, but
                    // future schema changes could), fall back to text.
                    runs.append(.text(fragment.text))
                }

            case .mention:
                // Twitch already resolved @username for us — extract the
                // login from the reference, mark `isMe` if it matches.
                if let mention = fragment.mention {
                    let isMe = mention.userLogin.caseInsensitiveCompare(currentUserLogin) == .orderedSame
                    if isMe { sawSelfMention = true }
                    runs.append(.mention(login: mention.userLogin, isMe: isMe))
                } else {
                    runs.append(.text(fragment.text))
                }

            case .cheermote:
                if let cheer = fragment.cheermote {
                    runs.append(.cheermote(prefix: cheer.prefix, bits: cheer.bits, tier: cheer.tier))
                } else {
                    runs.append(.text(fragment.text))
                }

            case .unknown:
                // Future Twitch fragment types we don't yet handle —
                // render the surface text rather than dropping content.
                runs.append(.text(fragment.text))
            }
        }

        // Coalesce adjacent text runs so the renderer makes one Text view
        // per text-chunk, not one per word. Improves baseline alignment
        // when text/emote sequences mix (each Text view has its own
        // baseline anchor — fewer Text views = fewer anchor adjustments).
        var coalesced = Self.coalesceAdjacentText(runs)

        // Twitch's IRC convention prefixes reply bodies with
        // "@parentLogin " so legacy chat clients see who's being replied
        // to even without UI support. We render the quoted-parent block
        // separately above the message body now, so that leading
        // mention is redundant + visually noisy. Strip it here so the
        // body reads as just the user's actual reply text.
        //
        // We only strip when the runs START with the matching mention
        // (followed optionally by a space-only text run) — keeps the
        // strip surgical instead of removing every leading @ in any
        // reply.
        if message.reply != nil {
            coalesced = Self.stripLeadingReplyMention(
                runs: coalesced,
                parentLogin: message.reply?.parentUserLogin ?? ""
            )
        }

        // Highlight detection — message is highlighted if it mentions me
        // OR if any text run contains a configured keyword (case-insensitive
        // substring match). The keyword check is bypassed when the keyword
        // list is empty, which is the common case.
        let isHighlighted = sawSelfMention || Self.containsHighlight(
            runs: coalesced,
            keywords: highlightKeywords
        )

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
            authorColor: message.color,
            runs: coalesced,
            isHighlighted: isHighlighted,
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
    public static func line(
        from notification: EventSubChatNotification
    ) -> ChatLine? {
        // Dispatch on noticeType to find the right payload and build the
        // matching bubble kind.
        let kind: ChatLine.Kind

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

        case "announcement", "charity_donation", "bits_badge_tier",
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
            authorUserId: notification.chatterUserId,
            authorDisplayName: notification.chatterUserName,
            authorColor: notification.color ?? "",
            runs: []   // bubbles render from `kind`, not `runs`
        )
    }

    /// Convert a `channel.raid` EventSub event (someone raiding INTO the
    /// channel we're watching) into a raidBubble `ChatLine`. Distinct
    /// from the `raid` notice inside `EventSubChatNotification` —
    /// channel.raid is the dedicated topic with simpler payload.
    public static func line(from raid: EventSubRaid) -> ChatLine {
        ChatLine(
            id: "raid-\(raid.fromBroadcasterUserId)-\(Int(Date().timeIntervalSince1970 * 1000))",
            kind: .raidBubble(.init(
                fromBroadcasterDisplayName: raid.fromBroadcasterUserName,
                viewers: raid.viewers
            )),
            authorUserId: raid.fromBroadcasterUserId,
            authorDisplayName: raid.fromBroadcasterUserName,
            runs: []
        )
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

    /// Split a string into whitespace-delimited tokens, emit `.emote` for
    /// any token that resolves in the snapshot, `.text` for everything
    /// else. Whitespace between tokens is appended back to the preceding
    /// text run so rendering preserves the original spacing.
    ///
    /// Implementation chooses a manual character walk over `String.split`
    /// because `split` discards the original whitespace bytes — we'd have
    /// to fake the spaces back, and they might not be exactly the same
    /// (e.g., tabs collapse to spaces). Walking character-by-character
    /// preserves exactly what was there.
    private static func tokenize(
        text: String,
        emoteSnapshot: [String: Emote],
        into runs: inout [LineRun]
    ) {
        // Buffers for the current word and the current whitespace span.
        // We flush the word when we hit whitespace; we flush the whitespace
        // when we start a new word.
        var currentWord = ""
        var pendingText = ""  // text accumulator for the next .text run

        // Walk characters once. Each iteration either:
        //   - extends `currentWord` (non-whitespace),
        //   - or flushes `currentWord` (whitespace transition).
        for ch in text {
            if ch.isWhitespace {
                if !currentWord.isEmpty {
                    // Word complete — try to resolve as an emote.
                    if let emote = emoteSnapshot[currentWord] {
                        // Flush any pending text *before* the emote, then
                        // emit the emote. Subsequent whitespace will start
                        // the next text run.
                        if !pendingText.isEmpty {
                            runs.append(.text(pendingText))
                            pendingText = ""
                        }
                        runs.append(.emote(emote))
                    } else {
                        // Not an emote — fold the word into pendingText
                        // so consecutive non-emote words stay one text run.
                        pendingText += currentWord
                    }
                    currentWord = ""
                }
                // The whitespace character itself belongs in pendingText
                // so the next text run preserves the original spacing.
                pendingText += String(ch)
            } else {
                currentWord += String(ch)
            }
        }

        // End-of-fragment cleanup: flush any trailing word/text.
        if !currentWord.isEmpty {
            if let emote = emoteSnapshot[currentWord] {
                if !pendingText.isEmpty {
                    runs.append(.text(pendingText))
                    pendingText = ""
                }
                runs.append(.emote(emote))
            } else {
                pendingText += currentWord
            }
        }
        if !pendingText.isEmpty {
            runs.append(.text(pendingText))
        }
    }

    // MARK: - Post-processing

    /// Merge consecutive `.text(...)` runs into a single run. Other run
    /// kinds (emote, mention, etc.) act as barriers and stay distinct.
    ///
    /// This matters because the tokenizer emits one text run per
    /// non-emote-broken segment, and a fragment-level walk can produce
    /// adjacent text runs across fragment boundaries (e.g., a `.text`
    /// fragment followed by a `.text` fragment for some reason).
    /// If `runs` starts with a `.mention` of the parent's login (Twitch's
    /// legacy "@parentLogin " prefix that backs up the reply metadata for
    /// clients without UI support), strip it — including a single
    /// trailing whitespace text run, so the user-facing body starts
    /// at the actual response text.
    ///
    /// Examples (parentLogin = "xqc"):
    ///   [.mention("xqc"), .text(" hello there")]  → [.text("hello there")]
    ///   [.mention("xqc"), .text(" "), .emote(...)] → [.emote(...)]
    ///   [.text("hey "), .mention("xqc"), ...]      → unchanged (mention isn't leading)
    ///   [.mention("ninja"), .text(" hi")]          → unchanged (mention isn't the parent)
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
        var trimmed = Array(runs.dropFirst())
        // Drop the leading-whitespace text run that follows the mention
        // (Twitch always inserts one). If the FIRST remaining run is a
        // text run consisting only of whitespace, drop it; otherwise
        // strip leading whitespace from it.
        if case .text(let body) = trimmed.first {
            let lstripped = String(body.drop(while: { $0.isWhitespace }))
            if lstripped.isEmpty {
                trimmed.removeFirst()
            } else {
                trimmed[0] = .text(lstripped)
            }
        }
        return trimmed
    }

    private static func coalesceAdjacentText(_ runs: [LineRun]) -> [LineRun] {
        var result: [LineRun] = []
        result.reserveCapacity(runs.count)
        for run in runs {
            if case .text(let next) = run,
               case .text(let prev) = result.last {
                result[result.count - 1] = .text(prev + next)
            } else {
                result.append(run)
            }
        }
        return result
    }

    /// Returns true when any text run contains any of the (non-empty)
    /// keywords as a case-insensitive substring. Empty keyword list
    /// short-circuits — no allocation, immediate false.
    private static func containsHighlight(
        runs: [LineRun],
        keywords: [String]
    ) -> Bool {
        guard !keywords.isEmpty else { return false }
        for run in runs {
            guard case .text(let body) = run else { continue }
            for keyword in keywords where !keyword.isEmpty {
                if body.range(of: keyword, options: .caseInsensitive) != nil {
                    return true
                }
            }
        }
        return false
    }
}
