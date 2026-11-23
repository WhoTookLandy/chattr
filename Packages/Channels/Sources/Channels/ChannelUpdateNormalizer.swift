import Foundation
import TwitchKit
import ChatModel
import EmoteSources
import Core
import os

/// Instruments the `normalize` interval (per live message / per history
/// batch) of the session half of the message pipeline. Same category as the
/// session's `renormalize` and the hub's `deliver` intervals.
private let signposter = AppLogger.signposter("Channels.Pipeline")

/// Turns translated channel events and history records into display-ready
/// `ChannelUpdate`s — the one place a session runs the `Normalizer`.
///
/// Holds only immutable inputs (the account login and the channel's emote
/// index, read through its nonisolated lock-protected snapshot), so it is a
/// `Sendable` value the session can hand to a ring rewrite without touching
/// actor state.
struct ChannelUpdateNormalizer: Sendable {

    /// The emote table normalization reads, plus the generation stamping it.
    typealias EmoteTable = (emotes: [String: Emote], generation: Int)

    /// The session account's login. The only viewer-specific input the
    /// session's normalization uses: it marks `@login` mentions as `isMe`
    /// (and the line highlighted). A session is per account, so this is the
    /// same for every tab that shows it; keyword highlighting — a per-attach
    /// viewer preference — stays with each subscriber.
    let accountLogin: String

    /// The channel's third-party emote table. Read through its nonisolated,
    /// lock-protected snapshot — no actor hop on the per-message path. nil
    /// (tests) normalizes with no third-party emotes.
    let emoteIndex: EmoteIndex?

    var hasEmoteIndex: Bool { emoteIndex != nil }

    func currentEmoteTable() -> EmoteTable {
        emoteIndex?.snapshotWithGeneration() ?? (emotes: [:], generation: 0)
    }

    /// Normalizes one message — the one place the session runs the
    /// `Normalizer` for chat. `timestamp` is decided by the caller from the
    /// message's metadata and stored with the line, so every later replay is
    /// the identical value.
    func normalize(
        _ message: ChatMessage,
        isHistorical: Bool,
        timestamp: Date,
        table: EmoteTable
    ) -> NormalizedMessage {
        var line = Normalizer.normalize(
            message: message,
            emoteSnapshot: table.emotes,
            currentUserLogin: accountLogin,
            timestamp: timestamp
        )
        line.isHistorical = isHistorical
        return NormalizedMessage(message: message, line: line, emoteGeneration: table.generation)
    }

    /// Normalizes a history batch (join backfill, gap-fill) as historical
    /// rows, timestamped by `tmi-sent-ts` — or, for a line without one, by
    /// the batch's arrival time, captured once.
    func normalizeHistory(_ messages: [BackfillMessage]) -> [ChannelUpdate] {
        guard !messages.isEmpty else { return [] }
        let interval = signposter.beginInterval(
            "normalize",
            id: signposter.makeSignpostID(),
            "history=\(messages.count)"
        )
        defer { signposter.endInterval("normalize", interval) }

        let table = currentEmoteTable()
        let fetchedAt = Date()
        return messages.map { record in
            ChannelUpdate.message(normalize(
                record.message,
                isHistorical: true,
                timestamp: record.sentAt ?? fetchedAt,
                table: table
            ))
        }
    }

    /// A fresh "New" divider row. Its id and timestamp are minted here, once,
    /// and the row is stored in the ring — every replay is the same row.
    func makeDivider() -> ChatLine {
        ChatLine(
            id: "divider-\(UUID().uuidString)",
            kind: .newMessagesDivider,
            authorDisplayName: "",
            runs: [],
            timestamp: Date()
        )
    }

    /// Normalizes one translated event into its ring/delivery form. Message
    /// text is tokenized and emote-resolved here — once per channel, not once
    /// per tab — and bubble ids/timestamps are minted here, once, so replays
    /// are identical. Returns nil for notice types the Normalizer doesn't
    /// render (dropped here rather than stored and dropped by every tab).
    func makeUpdate(for event: ChannelSession.ChannelEvent, receivedAt: Date) -> ChannelUpdate? {
        switch event {
        case .message(let message):
            let interval = signposter.beginInterval("normalize", id: signposter.makeSignpostID())
            let normalized = normalize(
                message,
                isHistorical: false,
                timestamp: receivedAt,
                table: currentEmoteTable()
            )
            signposter.endInterval("normalize", interval)
            return .message(normalized)
        case .notification(let notification):
            let table = currentEmoteTable()
            return Normalizer.line(
                from: notification,
                emoteSnapshot: table.emotes,
                currentUserLogin: accountLogin,
                timestamp: receivedAt
            ).map { ChannelUpdate.row($0) }
        case .raid(let raid):
            let id = Normalizer.raidLineID(
                fromBroadcasterUserId: raid.fromBroadcasterUserId,
                receivedAt: receivedAt
            )
            return .row(Normalizer.line(from: raid, id: id, timestamp: receivedAt))
        case .messageDeleted(let targetMessageId):
            return .messageDeleted(targetMessageId: targetMessageId)
        case .chatCleared:
            return .chatCleared
        case .messagesClearedFromUser(let targetUserId):
            return .messagesClearedFromUser(targetUserId: targetUserId)
        case .restrictionsUpdated(let restrictions):
            return .restrictionsUpdated(restrictions)
        case .moderationStatusChanged(let canModerate):
            return .moderationStatusChanged(canModerate: canModerate)
        }
    }

    /// `stale` re-normalized against `table`, or nil when it was already
    /// built against that table's generation.
    func renormalized(_ stale: NormalizedMessage, table: EmoteTable) -> NormalizedMessage? {
        guard stale.emoteGeneration != table.generation else { return nil }
        return normalize(
            stale.message,
            isHistorical: stale.line.isHistorical,
            timestamp: stale.line.timestamp,
            table: table
        )
    }
}
