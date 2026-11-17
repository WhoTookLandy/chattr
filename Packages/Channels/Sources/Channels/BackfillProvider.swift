import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Backfill")

/// One history line: the message plus when it was originally sent.
///
/// `TwitchKit.ChatMessage` has no timestamp field (EventSub's payload carries
/// none — the time lives on the envelope), so the IRC `tmi-sent-ts` tag rides
/// alongside instead of being lost in the JSON round-trip.
public struct BackfillMessage: Sendable {
    public let message: ChatMessage
    /// The `tmi-sent-ts` tag, when the line carried a parseable one.
    public let sentAt: Date?

    public init(message: ChatMessage, sentAt: Date?) {
        self.message = message
        self.sentAt = sentAt
    }
}

/// Fetches recent chat history from rustlog when a user joins a channel,
/// so chat isn't empty for the first minute.
///
/// ## What rustlog is
///
/// A community-run service (recent-messages.robotty.de) that archives
/// Twitch chat 24/7 by joining channels via IRC and storing the last few
/// hundred messages per channel. Twitch's own API does NOT expose chat
/// history — rustlog is the standard solution every Twitch client uses
/// (BetterTTV's site, 7TV's extension, Chatterino, etc.).
///
/// ## Trade-offs
///
///   - **Reliability**: rustlog is community-run. If it's down, backfill
///     fails — but channel join still works (we just see no history).
///     Failures are logged as warnings and swallowed.
///   - **Format mismatch**: rustlog returns raw IRC tag-format strings,
///     not EventSub-shaped JSON. We parse the IRC format and reconstruct
///     a `ChatMessage` value per line.
///   - **Twitch-native emotes**: IRC encodes emotes via the `emotes` tag
///     in a different format from EventSub's pre-tokenized `fragments`.
///     The parser converts the tag's code-point ranges into interleaved
///     text/emote fragments, so backfilled native emotes render the same
///     as live ones; third-party emotes (7TV/BTTV/FFZ) resolve via the
///     Normalizer tokenizing text fragments against the emote index.
///
/// ## Concurrency
///
/// `enum` with static methods — no per-instance state, no actor
/// isolation. Caller passes in URLSession; default is `.shared`. Safe
/// to call from any async context.
public enum BackfillProvider {

    /// Fetch the most recent ~150 messages for a channel. Returns
    /// messages in chronological order (oldest first) — same order the
    /// existing `lines` ring buffer expects.
    ///
    /// - Parameters:
    ///   - channelLogin: Twitch channel login (lowercase username).
    ///   - limit: Number of messages to fetch (rustlog caps at 800; we
    ///     default to 150 for a "comfortable scrollback" without UI lag).
    ///   - urlSession: URLSession to use. Defaults to `.shared`; tests
    ///     inject a mocked session.
    /// - Returns: Messages in chronological order, each with its
    ///   `tmi-sent-ts`. Empty array if rustlog returned no data or all lines
    ///   failed to parse (we don't fail loudly — chat still works).
    ///
    /// The request carries its own short timeout (`requestTimeout`): history
    /// is enrichment, and URLSession's 60s default let a hung history host
    /// keep the fetch (and the session that awaited it) pending for a
    /// minute. `ChannelSession` separately stops *waiting* after ~3s and
    /// merges anything later in place.
    public static func fetchRecentMessages(
        channelLogin: String,
        limit: Int = 150,
        urlSession: URLSession = .shared
    ) async -> [BackfillMessage] {
        let url = Endpoints.Rustlog.recentMessages(channelLogin: channelLogin, limit: limit)
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout

        // Backfill is best-effort. If anything in the fetch + parse
        // pipeline fails, log and return empty rather than throwing —
        // the caller (ChannelSession.start) should NEVER fail because
        // backfill failed. Live chat takes priority.
        do {
            let (data, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.warning("rustlog returned HTTP \(http.statusCode) for \(channelLogin, privacy: .public); skipping backfill")
                return []
            }
            let body = try JSONDecoder().decode(RustlogResponse.self, from: data)
            if let error = body.error, !error.isEmpty {
                logger.warning("rustlog error for \(channelLogin, privacy: .public): \(error, privacy: .public)")
                return []
            }
            // Parse each IRC line. Lines that fail to parse are skipped,
            // not thrown — a few malformed lines shouldn't break the
            // whole backfill.
            let messageDecoder = IRCMessageParser.makeDecoder()
            let messages = body.messages.compactMap {
                IRCMessageParser.parseRecord($0, channelLogin: channelLogin, decoder: messageDecoder)
            }
            logger.info("Backfilled \(messages.count) message(s) for #\(channelLogin, privacy: .public)")
            return messages
        } catch is CancellationError {
            // Expected if the caller's Task is cancelled mid-fetch.
            // Silent — not an error.
            return []
        } catch {
            logger.warning("Backfill failed for \(channelLogin, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Per-request timeout for the history fetch: generous next to the
    /// session's ~3s wait (a late answer still merges in), far below
    /// URLSession's 60s default.
    static let requestTimeout: TimeInterval = 10

    // MARK: - Wrapper response shape

    /// rustlog wraps the message list in a small JSON envelope:
    /// `{ "messages": [String], "error": String? }`. The strings are
    /// raw IRC tag-format lines.
    private struct RustlogResponse: Decodable {
        let messages: [String]
        let error: String?
    }
}

// MARK: - IRC tag-format parser

/// Parses a Twitch IRC PRIVMSG line into a `TwitchKit.ChatMessage`.
///
/// ## IRC line format
///
/// ```
/// @tags :nick!user@host PRIVMSG #channel :message text
/// ```
///
/// Where:
///   - `@tags` is `;`-separated `key=value` pairs (display-name, badges,
///     emotes, color, id, user-id, room-id, etc.)
///   - `nick` is the IRC nickname (== Twitch login, lowercase)
///   - `#channel` is the target channel
///   - `:message text` is the chat message body
///
/// ## Why we reconstruct via JSON encode + decode
///
/// `TwitchKit.ChatMessage` only exposes the synthesized `Decodable`
/// initializer publicly. To construct one, we build a JSON dict that
/// matches the EventSub `channel.chat.message` shape and decode it.
/// Clunky but the only public-API path; matches the pattern used in
/// the Normalizer tests.
internal enum IRCMessageParser {

    /// A decoder configured for the EventSub `ChatMessage` shape. The
    /// backfill hot path creates ONE and reuses it across all ~150 lines —
    /// `JSONDecoder` allocates non-trivial internal state per instance, so
    /// per-line construction was pure churn on the session-open path.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// Parse one IRC line into a `ChatMessage`, or return nil if the
    /// line doesn't match the PRIVMSG shape (e.g., JOIN/PART/NOTICE
    /// lines, which rustlog occasionally includes).
    ///
    /// The defaulted `decoder` keeps one-off call sites (tests) unchanged;
    /// batch callers pass a shared instance.
    static func parse(_ line: String, channelLogin: String, decoder: JSONDecoder = makeDecoder()) -> ChatMessage? {
        parseRecord(line, channelLogin: channelLogin, decoder: decoder)?.message
    }

    /// `parse`, keeping the line's `tmi-sent-ts` (epoch milliseconds) as the
    /// message's send time.
    static func parseRecord(_ line: String, channelLogin: String, decoder: JSONDecoder = makeDecoder()) -> BackfillMessage? {
        // 1. Tag block: starts with '@', ends at first space.
        guard line.hasPrefix("@") else { return nil }
        let afterTags = line.dropFirst()  // strip leading '@'
        guard let firstSpace = afterTags.firstIndex(of: " ") else { return nil }
        let tagsString = afterTags[..<firstSpace]
        let rest = afterTags[afterTags.index(after: firstSpace)...]

        let tags = parseTags(String(tagsString))

        // 2. Source: ":nick!user@host", ends at next space.
        guard rest.hasPrefix(":"),
              let nextSpace = rest.firstIndex(of: " ") else { return nil }
        let sourceString = rest[rest.index(after: rest.startIndex)..<nextSpace]
        let afterSource = rest[rest.index(after: nextSpace)...]
        // nick is the part before '!'
        guard let bang = sourceString.firstIndex(of: "!") else { return nil }
        let nick = String(sourceString[..<bang])

        // 3. Verb + channel + message: e.g. "PRIVMSG #xqc :hello world"
        //    Split on the first " :" to isolate the message text from
        //    the command head.
        let afterSourceStr = String(afterSource)
        guard let separatorRange = afterSourceStr.range(of: " :") else { return nil }
        let head = afterSourceStr[..<separatorRange.lowerBound]
        let messageText = String(afterSourceStr[separatorRange.upperBound...])

        // head is "PRIVMSG #channel"
        let headParts = head.split(separator: " ", maxSplits: 1)
        guard headParts.count == 2,
              headParts[0] == "PRIVMSG",
              headParts[1].hasPrefix("#") else { return nil }

        // 4. Build an EventSub-shaped JSON dict and decode into ChatMessage.
        //    Required fields per ChatMessage's Codable shape:
        //      message_id, broadcaster_user_id/login/name,
        //      chatter_user_id/login/name, message (text+fragments),
        //      color, badges, message_type.
        //    Missing fields (cheer, reply, channel_points_*) are optional.

        let displayName = tags["display-name"] ?? nick
        let userId = tags["user-id"] ?? ""
        let roomId = tags["room-id"] ?? ""
        let color = tags["color"] ?? ""
        let messageId = tags["id"] ?? UUID().uuidString
        let badges = parseBadgesTag(tags["badges"] ?? "")

        let messageJSON: [String: Any] = [
            "message_id": messageId,
            "broadcaster_user_id": roomId,
            "broadcaster_user_login": channelLogin,
            "broadcaster_user_name": channelLogin,  // We don't have display name in IRC tags.
            "chatter_user_id": userId,
            "chatter_user_login": nick,
            "chatter_user_name": displayName,
            "message": [
                "text": messageText,
                // Interleaved text + emote fragments from the `emotes=` IRC
                // tag, matching EventSub's pre-tokenized shape. The Normalizer
                // tokenizes the text fragments against the third-party emote
                // index and passes emote fragments through as native emotes.
                "fragments": makeFragments(messageText: messageText, emotesTag: tags["emotes"]),
            ],
            "color": color,
            "badges": badges.map { ["set_id": $0.setId, "id": $0.id, "info": $0.info] },
            "message_type": "text",
        ]

        let sentAt: Date? = tags["tmi-sent-ts"]
            .flatMap { Double($0) }
            .map { Date(timeIntervalSince1970: $0 / 1000) }

        do {
            let data = try JSONSerialization.data(withJSONObject: messageJSON)
            return BackfillMessage(
                message: try decoder.decode(ChatMessage.self, from: data),
                sentAt: sentAt
            )
        } catch {
            // One line failed to decode — log and skip. Don't fail the
            // whole backfill for one malformed message. The log line is
            // load-bearing: this hand-built dict must track TwitchKit's
            // `ChatMessage` Codable shape by hand, so a TwitchKit bump that
            // adds a required field makes EVERY line fail here — without
            // telemetry that regression presents as "chat opens empty."
            logger.warning("Backfill line failed to decode as ChatMessage: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Build the EventSub-shaped `fragments` array from the message text
    /// and the `emotes=` IRC tag (`emoteId:start-end,start-end/emoteId:...`).
    ///
    /// The tag's offsets count Unicode code points (scalars) of the message
    /// text — not UTF-16 code units, and not Characters — and the end offset
    /// is inclusive, so slicing goes through the scalar view. Either other
    /// unit misaligns on a message with a non-BMP scalar (most emoji: one
    /// code point, two UTF-16 units) or a multi-scalar Character before an
    /// emote.
    private static func makeFragments(messageText: String, emotesTag: String?) -> [[String: Any]] {
        let scalars = Array(messageText.unicodeScalars)
        let occurrences = parseEmotesTag(emotesTag, scalarCount: scalars.count)
        guard !occurrences.isEmpty else {
            return [["type": "text", "text": messageText]]
        }

        func text(_ slice: ArraySlice<Unicode.Scalar>) -> String {
            String(String.UnicodeScalarView(slice))
        }
        var fragments: [[String: Any]] = []
        var cursor = 0
        for occurrence in occurrences {
            if cursor < occurrence.start {
                fragments.append([
                    "type": "text",
                    "text": text(scalars[cursor..<occurrence.start]),
                ])
            }
            fragments.append([
                "type": "emote",
                "text": text(scalars[occurrence.start...occurrence.end]),
                // IRC doesn't carry emote_set_id (EventSub does); the
                // renderer only needs the id to build the CDN URL.
                "emote": ["id": occurrence.id, "emote_set_id": ""],
            ])
            cursor = occurrence.end + 1
        }
        if cursor < scalars.count {
            fragments.append([
                "type": "text",
                "text": text(scalars[cursor...]),
            ])
        }
        return fragments
    }

    /// Parse the `emotes=` tag into occurrences sorted by message position.
    /// Offsets are Unicode code points; `end` is inclusive. Entries with
    /// malformed or out-of-bounds ranges are dropped (rustlog occasionally
    /// relays lines whose ranges don't fit the text), as are overlaps,
    /// so the caller can always emit contiguous fragments.
    private static func parseEmotesTag(
        _ tag: String?,
        scalarCount: Int
    ) -> [(start: Int, end: Int, id: String)] {
        guard let tag, !tag.isEmpty else { return [] }

        var occurrences: [(start: Int, end: Int, id: String)] = []
        for entry in tag.split(separator: "/") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            let emoteId = String(parts[0])
            for range in parts[1].split(separator: ",") {
                let bounds = range.split(separator: "-")
                guard bounds.count == 2,
                      let start = Int(bounds[0]),
                      let end = Int(bounds[1]),
                      start >= 0, start <= end, end < scalarCount
                else { continue }
                occurrences.append((start: start, end: end, id: emoteId))
            }
        }

        // Ranges arrive grouped by emote id, not by position.
        occurrences.sort { $0.start < $1.start }
        var nonOverlapping: [(start: Int, end: Int, id: String)] = []
        for occurrence in occurrences {
            if let last = nonOverlapping.last, occurrence.start <= last.end { continue }
            nonOverlapping.append(occurrence)
        }
        return nonOverlapping
    }

    /// Parse `@key1=value1;key2=value2;...` into `[String: String]`.
    /// IRC tag values use `\:` for `;`, `\s` for ` `, `\\` for `\`, `\r`
    /// for `\r`, `\n` for `\n` — we unescape these so the decoded
    /// strings match what was originally sent.
    private static func parseTags(_ tagsString: String) -> [String: String] {
        var tags: [String: String] = [:]
        for pair in tagsString.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            tags[String(kv[0])] = unescape(String(kv[1]))
        }
        return tags
    }

    /// Reverse the IRC tag escaping. Per IRCv3 spec.
    private static func unescape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "\\", s.index(after: i) < s.endIndex {
                let next = s[s.index(after: i)]
                switch next {
                case ":":  result.append(";")
                case "s":  result.append(" ")
                case "\\": result.append("\\")
                case "r":  result.append("\r")
                case "n":  result.append("\n")
                default:   result.append(next)
                }
                i = s.index(i, offsetBy: 2)
            } else {
                result.append(ch)
                i = s.index(after: i)
            }
        }
        return result
    }

    /// Parse `badges=subscriber/12,moderator/1,...` into our internal
    /// badge representation. Each entry is `<set_id>/<id>`; the `info`
    /// field comes from `badge-info` (sub tenure for subscribers); for
    /// MVP we leave `info` empty.
    private static func parseBadgesTag(_ tag: String) -> [(setId: String, id: String, info: String)] {
        guard !tag.isEmpty else { return [] }
        return tag.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (setId: String(parts[0]), id: String(parts[1]), info: "")
        }
    }
}
