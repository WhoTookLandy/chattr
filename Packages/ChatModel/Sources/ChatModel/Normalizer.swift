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
        let coalesced = Self.coalesceAdjacentText(runs)

        // Highlight detection — message is highlighted if it mentions me
        // OR if any text run contains a configured keyword (case-insensitive
        // substring match). The keyword check is bypassed when the keyword
        // list is empty, which is the common case.
        let isHighlighted = sawSelfMention || Self.containsHighlight(
            runs: coalesced,
            keywords: highlightKeywords
        )

        return ChatLine(
            id: message.messageId,
            kind: .message,
            authorBadges: badges,
            originalBadges: message.badges,
            authorDisplayName: message.chatterUserName,
            authorColor: message.color,
            runs: coalesced,
            isHighlighted: isHighlighted
        )
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
