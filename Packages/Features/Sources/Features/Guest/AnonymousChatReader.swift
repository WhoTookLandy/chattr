import Foundation
import Observation
import ChatModel
import EmoteSources
import TwitchKit

/// Read-only Twitch chat without an account — the same anonymous IRC login
/// (`justinfan…`) twitch.tv itself uses for logged-out viewers. Used by the
/// signed-out "just looking" mode; signed-in chat goes through EventSub.
///
/// Messages become regular `ChatLine`s (rendered by `ChatRow`) with
/// Twitch emotes from IRC's `emotes` tag (images are public, no token)
/// and 7TV / BTTV / FFZ emotes from `EmoteIndex` (public APIs, keyed by
/// the channel id IRC sends in ROOMSTATE). No badges: their images need an
/// authenticated Helix call. Handles
/// moderation (`CLEARMSG` / `CLEARCHAT`) so removed messages disappear,
/// and reconnects with backoff after a drop or a server `RECONNECT`.
@MainActor
@Observable
final class AnonymousChatReader {
    struct Message: Identifiable, Equatable {
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
        var twitchEmotes: [TwitchEmoteSpan] = []
    }

    /// `emotes=25:0-4,12-16/1902:6-10` → one span per occurrence.
    struct TwitchEmoteSpan: Equatable {
        let id: String
        /// Inclusive unicode-scalar offsets into the message text.
        let start: Int
        let end: Int
    }

    /// 7TV / BTTV / FFZ emotes for this channel (global + channel), by name.
    /// Loaded once IRC tells us the channel id; until then, words stay text.
    private(set) var thirdPartyEmotes: [String: Emote] = [:]
    private let emoteIndex = EmoteIndex()
    private var emotesRequested = false

    enum Status: Equatable {
        case connecting
        case connected
        /// Lost the connection; a reconnect is scheduled.
        case reconnecting
    }

    private(set) var messages: [Message] = []
    private(set) var status: Status = .connecting

    private let channel: String
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Set by `start()`, cleared by `stop()` — reconnects only while wanted.
    private var isRunning = false
    private var failedAttempts = 0
    private static let maxMessages = 300

    init(channel: String) {
        self.channel = channel.lowercased().trimmingCharacters(in: .whitespaces)
    }

    func start() {
        isRunning = true
        connect()
    }

    func stop() {
        isRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnect()
    }

    // MARK: - Connection

    private func connect() {
        guard isRunning, task == nil, let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        let nick = "justinfan\(Int.random(in: 10_000...99_999))"
        for line in [
            "CAP REQ :twitch.tv/tags twitch.tv/commands",
            "PASS SCHMOOPIIE",
            "NICK \(nick)",
            "JOIN #\(channel)",
        ] {
            send(line)
        }
        receiveLoop = Task { [weak self] in
            await self?.receive(on: socket)
        }
    }

    private func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Drop the socket and try again after a backoff (1s, 2s, 4s… max 30s).
    private func scheduleReconnect() {
        disconnect()
        guard isRunning else { return }
        status = messages.isEmpty ? .connecting : .reconnecting
        let delay = min(30, 1 << min(failedAttempts, 5))
        failedAttempts += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func send(_ line: String) {
        task?.send(.string(line)) { _ in }
    }

    private func receive(on socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message else { continue }
                for line in text.split(whereSeparator: \.isNewline) {
                    handle(String(line))
                }
            } catch {
                if !Task.isCancelled, task === socket { scheduleReconnect() }
                return
            }
        }
    }

    // MARK: - Lines

    private func handle(_ line: String) {
        if line.hasPrefix("PING") {
            send("PONG" + line.dropFirst(4))
            return
        }
        guard let irc = IRCLine(line) else { return }
        switch irc.command {
        case "PRIVMSG":
            guard let message = Self.message(from: irc) else { return }
            markConnected()
            messages.append(message)
            if messages.count > Self.maxMessages {
                messages.removeFirst(messages.count - Self.maxMessages)
            }
        case "CLEARMSG":
            // One message deleted by a moderator.
            if let id = irc.tags["target-msg-id"] {
                messages.removeAll { $0.id == id }
            }
        case "CLEARCHAT":
            // A user timed out / banned (target-user-id), or the whole chat cleared.
            if let userId = irc.tags["target-user-id"] {
                messages.removeAll { $0.userId == userId }
            } else {
                messages.removeAll()
            }
        case "RECONNECT":
            // Twitch is about to restart this server: hop to a fresh one.
            scheduleReconnect()
        case "ROOMSTATE":
            markConnected()
            if let roomId = irc.tags["room-id"], !roomId.isEmpty {
                loadThirdPartyEmotes(channelId: roomId)
            }
        case "366", "JOIN":
            markConnected()
        default:
            break
        }
    }

    private func markConnected() {
        status = .connected
        failedAttempts = 0
    }

    /// `@tags :nick!nick@nick.tmi.twitch.tv PRIVMSG #channel :text`
    static func parsePrivmsg(_ line: String) -> Message? {
        guard let irc = IRCLine(line), irc.command == "PRIVMSG" else { return nil }
        return message(from: irc)
    }

    private static func message(from irc: IRCLine) -> Message? {
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
        return Message(
            id: id,
            userId: userId,
            author: displayName,
            color: color,
            text: text,
            isAction: isAction,
            login: login,
            // A /me body is offset by the ACTION wrapper in the raw text;
            // positions are only reliable for plain messages.
            twitchEmotes: isAction ? [] : Self.parseEmoteSpans(irc.tags["emotes"] ?? "")
        )
    }

    static func parseEmoteSpans(_ tag: String) -> [TwitchEmoteSpan] {
        var spans: [TwitchEmoteSpan] = []
        for entry in tag.split(separator: "/") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let id = String(parts[0])
            for range in parts[1].split(separator: ",") {
                let bounds = range.split(separator: "-")
                guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start <= end else { continue }
                spans.append(TwitchEmoteSpan(id: id, start: start, end: end))
            }
        }
        return spans.sorted { $0.start < $1.start }
    }

    // MARK: - Rendering

    private func loadThirdPartyEmotes(channelId: String) {
        guard !emotesRequested else { return }
        emotesRequested = true
        let index = emoteIndex
        let login = channel
        Task { [weak self] in
            await index.load(broadcasterId: channelId, broadcasterLogin: login)
            self?.thirdPartyEmotes = index.snapshot()
        }
    }

    /// The message as a regular chat line: Twitch emotes at their tagged
    /// positions, 7TV / BTTV / FFZ emotes matched by word.
    func chatLine(for message: Message) -> ChatLine {
        ChatLine(
            id: message.id,
            authorUserId: message.userId ?? "",
            authorDisplayName: message.author,
            authorUserLogin: message.login,
            authorColor: message.color ?? "",
            runs: Self.runs(text: message.text, spans: message.twitchEmotes, emotes: thirdPartyEmotes)
        )
    }

    static func runs(text: String, spans: [TwitchEmoteSpan], emotes: [String: Emote]) -> [LineRun] {
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

    /// `EmoteReference` has no public initializer; it decodes from the
    /// EventSub JSON shape (snake_case), so build it that way. Static
    /// format only: IRC doesn't say whether an emote is animated, and
    /// requesting the animated variant of a static emote 404s.
    private static let referenceDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func twitchEmoteReference(id: String) -> EmoteReference? {
        let json: [String: Any] = ["id": id, "emote_set_id": "", "format": ["static"]]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? referenceDecoder.decode(EmoteReference.self, from: data)
    }
}

/// One IRC line: `[@tags] [:source] COMMAND [params] [:trailing]`.
struct IRCLine {
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
                tags[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
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
