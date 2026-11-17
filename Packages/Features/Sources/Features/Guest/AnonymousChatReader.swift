import Foundation
import Observation

/// Read-only Twitch chat without an account — the same anonymous IRC login
/// (`justinfan…`) twitch.tv itself uses for logged-out viewers. Used by the
/// signed-out "just looking" mode; signed-in chat goes through EventSub.
///
/// Plain text only: no badges, emotes render as their names. Enough to
/// follow a chat before deciding to sign in.
@MainActor
@Observable
final class AnonymousChatReader {
    struct Message: Identifiable, Equatable {
        let id: String
        let author: String
        /// `#RRGGBB` from the user's chat color, if they set one.
        let color: String?
        let text: String
        let isAction: Bool
    }

    enum Status: Equatable {
        case connecting
        case connected
        case failed
    }

    private(set) var messages: [Message] = []
    private(set) var status: Status = .connecting

    private let channel: String
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private static let maxMessages = 300

    init(channel: String) {
        self.channel = channel.lowercased().trimmingCharacters(in: .whitespaces)
    }

    func start() {
        guard task == nil, let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
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

    func stop() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
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
                if !Task.isCancelled { status = .failed }
                return
            }
        }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("PING") {
            send("PONG" + line.dropFirst(4))
            return
        }
        guard let parsed = Self.parsePrivmsg(line) else {
            if line.contains(" 366 ") || line.contains(" JOIN #") { status = .connected }
            return
        }
        status = .connected
        messages.append(parsed)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    /// `@tags :nick!nick@nick.tmi.twitch.tv PRIVMSG #channel :text`
    static func parsePrivmsg(_ line: String) -> Message? {
        var rest = Substring(line)
        var tags: [String: String] = [:]
        if rest.hasPrefix("@"), let space = rest.firstIndex(of: " ") {
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { tags[String(parts[0])] = String(parts[1]) }
            }
            rest = rest[rest.index(after: space)...]
        }
        guard rest.hasPrefix(":"),
              let command = rest.range(of: " PRIVMSG #"),
              let textStart = rest[command.upperBound...].range(of: " :")
        else { return nil }

        let prefix = rest[rest.index(after: rest.startIndex)..<command.lowerBound]
        let login = prefix.split(separator: "!").first.map(String.init) ?? String(prefix)
        var text = String(rest[textStart.upperBound...])

        // /me messages: \u{1}ACTION text\u{1}
        var isAction = false
        if text.hasPrefix("\u{1}ACTION "), text.hasSuffix("\u{1}") {
            isAction = true
            text = String(text.dropFirst(8).dropLast())
        }

        let displayName = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login
        let color = tags["color"].flatMap { $0.isEmpty ? nil : $0 }
        let id = tags["id"] ?? UUID().uuidString
        return Message(id: id, author: displayName, color: color, text: text, isAction: isAction)
    }
}
