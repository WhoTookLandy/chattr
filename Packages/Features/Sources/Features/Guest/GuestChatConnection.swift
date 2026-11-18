import Foundation
import Core
import ChatModel
import EmoteSources
import os

private let logger = AppLogger.make("Features.GuestChat")

/// Where the guest chat connection stands, as the view shows it.
enum GuestChatStatus: Equatable, Sendable {
    case connecting
    case connected
    /// Lost the connection; a reconnect is scheduled.
    case reconnecting
}

/// How long to wait before the next connection attempt: 1s, 2s, 4s… capped
/// at 30s. The ladder only starts over once a connection has stayed up for
/// `stableAfter`. A server that accepts the join and drops it a moment later
/// would otherwise be retried every second, forever.
struct GuestReconnectPolicy: Sendable {
    static let stableAfter: Duration = .seconds(30)

    private(set) var failedAttempts = 0

    /// The delay, in seconds, after a connection that was joined for
    /// `connectedFor` (`nil`: it never got as far as joining).
    mutating func nextDelay(connectedFor: Duration?) -> Int {
        if let connectedFor, connectedFor >= Self.stableAfter {
            failedAttempts = 0
        }
        let delay = min(30, 1 << min(failedAttempts, 5))
        failedAttempts += 1
        return delay
    }
}

/// The guest chat socket and everything fed by it, off the main actor: the
/// IRC read loop, parsing, building each message's `ChatLine` once, the
/// 300-message buffer, moderation removals, reconnects and the liveness
/// watchdog. `AnonymousChatReader` only receives finished snapshots.
///
/// Snapshots are coalesced: the first change after a quiet spell is
/// published at once, further changes at most every `flushInterval`. The
/// stream keeps only the newest one (each is the whole transcript), so a
/// main actor that falls behind skips frames instead of queueing them.
actor GuestChatConnection {
    typealias Status = GuestChatStatus

    /// What the view shows. `revision` changes whenever `lines` does.
    struct Snapshot: Sendable {
        let lines: [ChatLine]
        let revision: Int
        let status: Status
    }

    /// Minimum spacing of snapshots while messages keep arriving.
    static let flushInterval: Duration = .milliseconds(50)
    /// How often the watchdog looks, and how long a silence it answers
    /// with a ping.
    static let pingInterval: Duration = .seconds(15)
    /// Silence after which the socket is taken for dead. Twitch answers a
    /// ping at once, so two unanswered ones are enough.
    static let idleDeadline: Duration = .seconds(40)

    private let channel: String
    private let emoteIndex: EmoteIndex?
    private let clock = ContinuousClock()

    private var buffer = GuestChatBuffer()
    private var status: Status = .connecting
    private var updates: AsyncStream<Snapshot>.Continuation?
    private var published: (revision: Int, status: Status)?

    /// The newest start/stop request seen. Requests are numbered on the
    /// main actor and hop here in separate tasks, so they can arrive out
    /// of order; an older one is ignored.
    private var latestRequest = 0
    private var runTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var lastReceived: ContinuousClock.Instant
    /// When the current connection was confirmed joined; nil until then.
    private var joinedAt: ContinuousClock.Instant?
    private var emotesRequested = false

    private var flushScheduled = false
    private var lastFlush: ContinuousClock.Instant?

    init(channel: String) {
        self.channel = channel
        // Only the sources the user left on (Settings → Chat → Emotes),
        // read once like a signed-in channel's index.
        var providers: [any EmoteProvider] = []
        if EmoteSourceSettings.sevenTVEnabled() { providers.append(SevenTVProvider()) }
        if EmoteSourceSettings.bttvEnabled() { providers.append(BTTVProvider()) }
        if EmoteSourceSettings.ffzEnabled() { providers.append(FFZProvider()) }
        emoteIndex = providers.isEmpty ? nil : EmoteIndex(providers: providers, globalCatalog: .shared)
        lastReceived = ContinuousClock.now
    }

    // MARK: - Lifecycle

    /// Starts (or keeps) the connection and sends snapshots to `updates`.
    func start(request: Int, updates newUpdates: AsyncStream<Snapshot>.Continuation) {
        guard request > latestRequest else {
            newUpdates.finish()
            return
        }
        latestRequest = request
        updates?.finish()
        updates = newUpdates
        published = nil
        if runTask == nil {
            status = buffer.isEmpty ? .connecting : .reconnecting
            runTask = Task { await self.run() }
        }
        publish()
    }

    /// Closes the socket and stops reconnecting. The buffer is kept, so a
    /// later `start` carries on below the messages already shown.
    func stop(request: Int) {
        guard request > latestRequest else { return }
        latestRequest = request
        runTask?.cancel()
        runTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        updates?.finish()
        updates = nil
    }

    // MARK: - Connection

    private func run() async {
        var policy = GuestReconnectPolicy()
        while !Task.isCancelled {
            let connectedFor = await runConnection()
            guard !Task.isCancelled else { return }
            setStatus(buffer.isEmpty ? .connecting : .reconnecting)
            let delay = policy.nextDelay(connectedFor: connectedFor)
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// One socket, from login to its end (error, server `RECONNECT`, or the
    /// watchdog giving up on it). Returns how long it was joined, if it was.
    private func runConnection() async -> Duration? {
        let socket = URLSession.shared.webSocketTask(with: Endpoints.TwitchIRC.webSocket)
        self.socket = socket
        joinedAt = nil
        lastReceived = clock.now
        socket.resume()
        let nick = "justinfan\(Int.random(in: 10_000...99_999))"
        for line in [
            "CAP REQ :twitch.tv/tags twitch.tv/commands",
            "PASS SCHMOOPIIE",
            "NICK \(nick)",
            "JOIN #\(channel)",
        ] {
            send(line, on: socket)
        }
        let watchdog = Task { await self.watch(socket) }

        receiving: while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                lastReceived = clock.now
                guard case .string(let text) = message else { continue }
                var serverAskedToReconnect = false
                for line in text.split(whereSeparator: \.isNewline) {
                    if handle(line, on: socket) {
                        serverAskedToReconnect = true
                    }
                }
                scheduleFlush()
                if serverAskedToReconnect { break receiving }
            } catch {
                break receiving
            }
        }

        watchdog.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        if self.socket === socket {
            self.socket = nil
        }
        return joinedAt.map { clock.now - $0 }
    }

    /// A half-open connection never errors: it just goes quiet, and the
    /// chat would sit frozen under a "connected" status. So a silence gets
    /// a ping (Twitch answers `PONG` at once), and a silence that outlasts
    /// `idleDeadline` ends the socket, which sends the read loop to
    /// reconnect.
    private func watch(_ socket: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pingInterval)
            guard !Task.isCancelled, self.socket === socket else { return }
            let silence = clock.now - lastReceived
            if silence >= Self.idleDeadline {
                logger.notice("Guest chat for #\(self.channel, privacy: .public) went silent; reconnecting")
                socket.cancel(with: .goingAway, reason: nil)
                return
            }
            if silence >= Self.pingInterval {
                send("PING :tmi.twitch.tv", on: socket)
            }
        }
    }

    private func send(_ line: String, on socket: URLSessionWebSocketTask) {
        socket.send(.string(line)) { _ in }
    }

    // MARK: - Lines

    /// Applies one IRC line. Returns true when the server asked for a
    /// reconnect.
    private func handle(_ line: Substring, on socket: URLSessionWebSocketTask) -> Bool {
        if line.hasPrefix("PING") {
            send("PONG" + line.dropFirst(4), on: socket)
            return false
        }
        guard let irc = IRCLine(String(line)) else { return false }
        switch irc.command {
        case "PRIVMSG":
            guard let message = GuestIRC.message(from: irc) else { return false }
            markJoined()
            buffer.append(message)
        case "CLEARMSG":
            // One message deleted by a moderator.
            if let id = irc.tags["target-msg-id"] {
                buffer.removeMessage(id: id)
            }
        case "CLEARCHAT":
            // A user timed out / banned (target-user-id), or the whole chat cleared.
            if let userId = irc.tags["target-user-id"] {
                buffer.removeMessages(fromUserId: userId)
            } else {
                buffer.removeAll()
            }
        case "RECONNECT":
            // Twitch is about to restart this server: hop to a fresh one.
            return true
        case "ROOMSTATE":
            markJoined()
            if let roomId = irc.tags["room-id"], !roomId.isEmpty {
                loadThirdPartyEmotes(channelId: roomId)
            }
        case "366", "JOIN":
            markJoined()
        default:
            break
        }
        return false
    }

    private func markJoined() {
        status = .connected
        if joinedAt == nil {
            joinedAt = clock.now
        }
    }

    private func setStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        scheduleFlush()
    }

    /// 7TV / BTTV / FFZ emotes for this channel (global + channel), loaded
    /// once IRC tells us the channel id. Lines built before the table lands
    /// are rebuilt with it.
    private func loadThirdPartyEmotes(channelId: String) {
        guard !emotesRequested, let emoteIndex else { return }
        emotesRequested = true
        let login = channel
        Task {
            await emoteIndex.load(broadcasterId: channelId, broadcasterLogin: login)
            self.buffer.setEmotes(emoteIndex.snapshot())
            self.scheduleFlush()
        }
    }

    // MARK: - Publishing

    /// Publishes now when the last snapshot is at least `flushInterval`
    /// old, otherwise once it is.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        let now = clock.now
        if let lastFlush, now - lastFlush < Self.flushInterval {
            flushScheduled = true
            let wait = Self.flushInterval - (now - lastFlush)
            Task {
                try? await Task.sleep(for: wait)
                self.flush()
            }
        } else {
            flush()
        }
    }

    private func flush() {
        flushScheduled = false
        lastFlush = clock.now
        publish()
    }

    private func publish() {
        guard let updates else { return }
        if let published, published.revision == buffer.revision, published.status == status {
            return
        }
        published = (buffer.revision, status)
        updates.yield(Snapshot(lines: buffer.lines, revision: buffer.revision, status: status))
    }
}
