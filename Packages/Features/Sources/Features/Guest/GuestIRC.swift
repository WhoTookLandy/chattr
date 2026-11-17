import Foundation
import ChatModel
import EmoteSources
import TwitchKit
import os

/// One guest chat message as IRC delivered it. Kept beside its built
/// `ChatLine` so the line can be rebuilt when the emote table arrives.
struct GuestChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    /// Twitch user id (`user-id` tag) — for `CLEARCHAT` of one user.
    let userId: String?
    let author: String
    /// `#RRGGBB` from the user's chat color, if they set one.
    let color: String?
    let text: String
    let isAction: Bool
    /// Sender login (for the row's localized-name display).
    var login: String = ""
    /// Twitch emotes from the `emotes` tag: unicode-scalar ranges.
    var twitchEmotes: [GuestEmoteSpan] = []
    /// When Twitch sent it (`tmi-sent-ts`), else when it arrived. Fixed
    /// per message so a rebuilt line keeps the row's timestamp.
    var timestamp: Date = .now
}

/// `emotes=25:0-4,12-16/1902:6-10` → one span per occurrence.
struct GuestEmoteSpan: Equatable, Sendable {
    let id: String
    /// Inclusive unicode-scalar offsets into the message text.
    let start: Int
    let end: Int
}

/// IRC line → `ChatLine` for guest chat. Pure and nonisolated, so the
/// connection runs it off the main actor.
enum GuestIRC {

    /// `@tags :nick!nick@nick.tmi.twitch.tv PRIVMSG #channel :text`
    static func parsePrivmsg(_ line: String) -> GuestChatMessage? {
        guard let irc = IRCLine(line), irc.command == "PRIVMSG" else { return nil }
        return message(from: irc)
    }

    static func message(from irc: IRCLine) -> GuestChatMessage? {
        guard var text = irc.trailing else { return nil }
        let login = irc.source.split(separator: "!").first.map(String.init) ?? irc.source

        // /me messages: \u{1}ACTION text\u{1}
        var isAction = false
        if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") {
            isAction = true
            text = String(text.dropFirst(8).dropLast())
        }

        let displayName = irc.tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login
        let color = irc.tags["color"].flatMap { $0.isEmpty ? nil : $0 }
        let userId = irc.tags["user-id"].flatMap { $0.isEmpty ? nil : $0 }
        let id = irc.tags["id"] ?? UUID().uuidString
        return GuestChatMessage(
            id: id,
            userId: userId,
            author: displayName,
            color: color,
            text: text,
            isAction: isAction,
            login: login,
            // A /me body is offset by the ACTION wrapper in the raw text;
            // positions are only reliable for plain messages.
            twitchEmotes: isAction ? [] : parseEmoteSpans(irc.tags["emotes"] ?? ""),
            timestamp: irc.tags["tmi-sent-ts"].flatMap(Double.init)
                .map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        )
    }

    static func parseEmoteSpans(_ tag: String) -> [GuestEmoteSpan] {
        var spans: [GuestEmoteSpan] = []
        for entry in tag.split(separator: "/") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let id = String(parts[0])
            for range in parts[1].split(separator: ",") {
                let bounds = range.split(separator: "-")
                guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start <= end else { continue }
                spans.append(GuestEmoteSpan(id: id, start: start, end: end))
            }
        }
        return spans.sorted { $0.start < $1.start }
    }

    /// Reverses IRCv3 tag-value escaping: `\:` → `;`, `\s` → space, `\\` →
    /// `\`, `\r` / `\n` → CR / LF; any other escaped character stands for
    /// itself. Same table as the history parser (`BackfillProvider`), so a
    /// display name with a space reads the same here and in signed-in
    /// backfill.
    static func unescapeTagValue(_ value: Substring) -> String {
        guard value.contains("\\") else { return String(value) }
        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            index = value.index(after: index)
            guard character == "\\", index < value.endIndex else {
                result.append(character)
                continue
            }
            switch value[index] {
            case ":": result.append(";")
            case "s": result.append(" ")
            case "\\": result.append("\\")
            case "r": result.append("\r")
            case "n": result.append("\n")
            default: result.append(value[index])
            }
            index = value.index(after: index)
        }
        return result
    }

    // MARK: - Lines

    /// The message as a regular chat line: Twitch emotes at their tagged
    /// positions, 7TV / BTTV / FFZ emotes matched by word.
    static func chatLine(for message: GuestChatMessage, emotes: [String: Emote]) -> ChatLine {
        ChatLine(
            id: message.id,
            authorUserId: message.userId ?? "",
            authorDisplayName: message.author,
            authorUserLogin: message.login,
            authorColor: message.color ?? "",
            runs: runs(text: message.text, spans: message.twitchEmotes, emotes: emotes),
            timestamp: message.timestamp
        )
    }

    static func runs(text: String, spans: [GuestEmoteSpan], emotes: [String: Emote]) -> [LineRun] {
        // The common message has no Twitch emotes: skip the scalar array.
        guard !spans.isEmpty else {
            return ChatModel.Normalizer.wordRuns(text: text, emoteSnapshot: emotes)
        }
        let scalars = Array(text.unicodeScalars)
        func words(_ range: Range<Int>) -> [LineRun] {
            guard !range.isEmpty else { return [] }
            let piece = String(String.UnicodeScalarView(scalars[range]))
            return ChatModel.Normalizer.wordRuns(text: piece, emoteSnapshot: emotes)
        }
        var runs: [LineRun] = []
        var cursor = 0
        for span in spans where span.start >= cursor && span.end < scalars.count {
            runs += words(cursor..<span.start)
            let name = String(String.UnicodeScalarView(scalars[span.start...span.end]))
            if let reference = twitchEmoteReference(id: span.id) {
                runs.append(.twitchEmote(reference: reference, displayName: name))
            } else {
                runs += words(span.start..<(span.end + 1))
            }
            cursor = span.end + 1
        }
        runs += words(cursor..<scalars.count)
        return runs
    }

    // MARK: - Twitch emote references

    /// References already built, by emote id. A busy chat repeats the same
    /// few emotes thousands of times; each used to cost a JSON round trip.
    private static let references = OSAllocatedUnfairLock<[String: EmoteReference]>(initialState: [:])

    /// Enough for any one channel's emotes; past it the cache starts over
    /// rather than growing for as long as the app runs.
    private static let referenceCacheLimit = 4_096

    /// `EmoteReference` has no public initializer; it decodes from the
    /// EventSub JSON shape (snake_case), so build it that way, once per id.
    /// Static format only: IRC doesn't say whether an emote is animated,
    /// and requesting the animated variant of a static emote 404s.
    static func twitchEmoteReference(id: String) -> EmoteReference? {
        if let cached = references.withLock({ $0[id] }) {
            return cached
        }
        let json: [String: Any] = ["id": id, "emote_set_id": "", "format": ["static"]]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reference = try? decoder.decode(EmoteReference.self, from: data) else { return nil }
        references.withLock { cache in
            if cache.count >= referenceCacheLimit {
                cache.removeAll(keepingCapacity: true)
            }
            cache[id] = reference
        }
        return reference
    }
}

/// One IRC line: `[@tags] [:source] COMMAND [params] [:trailing]`. Tag
/// values are unescaped.
struct IRCLine: Sendable {
    var tags: [String: String] = [:]
    var source = ""
    var command = ""
    var params: [String] = []
    var trailing: String?

    init?(_ line: String) {
        var rest = Substring(line)
        if rest.hasPrefix("@") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(parts[0])] = parts.count == 2 ? GuestIRC.unescapeTagValue(parts[1]) : ""
            }
            rest = rest[rest.index(after: space)...]
        }
        if rest.hasPrefix(":") {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            source = String(rest[rest.index(after: rest.startIndex)..<space])
            rest = rest[rest.index(after: space)...]
        }
        if let trailingStart = rest.range(of: " :") {
            trailing = String(rest[trailingStart.upperBound...])
            rest = rest[..<trailingStart.lowerBound]
        }
        let words = rest.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        command = first
        params = Array(words.dropFirst())
    }
}
