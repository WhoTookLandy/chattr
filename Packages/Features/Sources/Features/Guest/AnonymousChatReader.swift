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
/// authenticated Helix call. Handles moderation (`CLEARMSG` / `CLEARCHAT`)
/// so removed messages disappear, and reconnects with backoff after a
/// drop, a silent socket or a server `RECONNECT`.
///
/// This type is only the main-actor face of it: the observed `lines` and
/// `status`. The socket, the parsing and the line building all happen in
/// `GuestChatConnection`, which hands over finished snapshots at most every
/// 50 ms, so a busy channel costs the main actor one array assignment per
/// snapshot rather than work per message.
@MainActor
@Observable
final class AnonymousChatReader {
    typealias Message = GuestChatMessage
    typealias TwitchEmoteSpan = GuestEmoteSpan

    typealias Status = GuestChatStatus

    /// The newest messages (at most `GuestChatBuffer.maxMessages`), oldest
    /// first, ready to render.
    private(set) var lines: [ChatLine] = []
    private(set) var status: Status = .connecting

    private let connection: GuestChatConnection
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// Numbers start/stop requests so the connection can order them.
    @ObservationIgnored private var requests = 0
    @ObservationIgnored private var appliedRevision: Int?

    init(channel: String) {
        connection = GuestChatConnection(
            channel: channel.lowercased().trimmingCharacters(in: .whitespaces)
        )
    }

    deinit {
        // Normally `stop()` already ran (the view's `onDisappear`); this
        // covers a reader dropped while connected. `Int.max` outranks any
        // request still on its way.
        let connection = connection
        Task { await connection.stop(request: .max) }
    }

    func start() {
        guard consumer == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(
            of: GuestChatConnection.Snapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        consumer = Task { [weak self] in
            for await snapshot in stream {
                self?.apply(snapshot)
            }
        }
        requests += 1
        let request = requests
        let connection = connection
        Task { await connection.start(request: request, updates: continuation) }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
        requests += 1
        let request = requests
        let connection = connection
        Task { await connection.stop(request: request) }
    }

    private func apply(_ snapshot: GuestChatConnection.Snapshot) {
        if snapshot.revision != appliedRevision {
            appliedRevision = snapshot.revision
            lines = snapshot.lines
        }
        if status != snapshot.status {
            status = snapshot.status
        }
    }

    // MARK: - Parsing (see `GuestIRC`)

    /// `@tags :nick!nick@nick.tmi.twitch.tv PRIVMSG #channel :text`
    nonisolated static func parsePrivmsg(_ line: String) -> Message? {
        GuestIRC.parsePrivmsg(line)
    }

    nonisolated static func parseEmoteSpans(_ tag: String) -> [TwitchEmoteSpan] {
        GuestIRC.parseEmoteSpans(tag)
    }

    nonisolated static func runs(text: String, spans: [TwitchEmoteSpan], emotes: [String: Emote]) -> [LineRun] {
        GuestIRC.runs(text: text, spans: spans, emotes: emotes)
    }

    nonisolated static func twitchEmoteReference(id: String) -> EmoteReference? {
        GuestIRC.twitchEmoteReference(id: id)
    }
}
