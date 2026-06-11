import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Backfill")

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
///     For MVP, backfilled Twitch-native emotes render as plain text;
///     **third-party emotes (7TV/BTTV/FFZ) still resolve correctly**
///     because the Normalizer tokenizes the message text against the
///     emote index regardless of fragment shape.
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
    /// - Returns: Messages in chronological order. Empty array if rustlog
    ///   returned no data or all lines failed to parse (we don't fail
    ///   loudly — chat still works).
    public static func fetchRecentMessages(
        channelLogin: String,
        limit: Int = 150,
        urlSession: URLSession = .shared
    ) async -> [ChatMessage] {
        let url = Endpoints.Rustlog.recentMessages(channelLogin: channelLogin, limit: limit)

        // Backfill is best-effort. If anything in the fetch + parse
        // pipeline fails, log and return empty rather than throwing —
        // the caller (ChannelSession.start) should NEVER fail because
        // backfill failed. Live chat takes priority.
        do {
            let (data, response) = try await urlSession.data(from: url)
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
                IRCMessageParser.parse($0, channelLogin: channelLogin, decoder: messageDecoder)
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
                // Single text fragment for the whole message. The Normalizer
                // will tokenize this against the third-party emote index;
                // Twitch-native emote tags (the `emotes=` IRC tag) are NOT
                // converted to fragments in MVP — backfilled native emotes
                // render as text. Follow-up could parse `emotes=` and
                // construct `.emote` fragments here.
                "fragments": [
                    [
                        "type": "text",
                        "text": messageText,
                    ]
                ],
            ],
            "color": color,
            "badges": badges.map { ["set_id": $0.setId, "id": $0.id, "info": $0.info] },
            "message_type": "text",
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: messageJSON)
            return try decoder.decode(ChatMessage.self, from: data)
        } catch {
            // One line failed to decode — log and skip. Don't fail the
            // whole backfill for one malformed message.
            return nil
        }
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
