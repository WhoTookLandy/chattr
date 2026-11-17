import Foundation
import Observation

/// Read-only Twitch chat without an account — the same anonymous IRC login
/// (`justinfan…`) twitch.tv itself uses for logged-out viewers. Used by the
/// signed-out "just looking" mode; signed-in chat goes through EventSub.
///
/// Plain text only: no badges, emotes render as their names. Handles
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
    }

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
        case "366", "JOIN", "ROOMSTATE":
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
        return Message(id: id, userId: userId, author: displayName, color: color, text: text, isAction: isAction)
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
