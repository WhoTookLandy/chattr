import Foundation
import ChatModel
import EmoteSources

/// The guest transcript: the newest messages, each with the `ChatLine`
/// built for it once, when it arrived. Owned by `GuestChatConnection`, off
/// the main actor; the view only ever sees `lines`.
struct GuestChatBuffer: Sendable {
    static let maxMessages = 300

    private struct Entry: Sendable {
        let message: GuestChatMessage
        var line: ChatLine
    }

    private var entries: [Entry] = []
    private var emotes: [String: Emote] = [:]

    /// Changes whenever `lines` does, so a reader can tell without
    /// comparing 300 rows.
    private(set) var revision = 0

    var lines: [ChatLine] { entries.map(\.line) }
    var isEmpty: Bool { entries.isEmpty }

    mutating func append(_ message: GuestChatMessage) {
        entries.append(Entry(message: message, line: GuestIRC.chatLine(for: message, emotes: emotes)))
        if entries.count > Self.maxMessages {
            entries.removeFirst(entries.count - Self.maxMessages)
        }
        revision += 1
    }

    /// `CLEARMSG`: one message deleted by a moderator.
    mutating func removeMessage(id: String) {
        remove { $0.message.id == id }
    }

    /// `CLEARCHAT` with a target: a user timed out or banned.
    mutating func removeMessages(fromUserId userId: String) {
        remove { $0.message.userId == userId }
    }

    /// `CLEARCHAT` without a target: the whole chat cleared.
    mutating func removeAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        revision += 1
    }

    /// Installs the third-party emote table and rebuilds every line built
    /// before it arrived, so words that are emotes stop reading as text.
    mutating func setEmotes(_ emotes: [String: Emote]) {
        guard emotes != self.emotes else { return }
        self.emotes = emotes
        guard !entries.isEmpty else { return }
        for index in entries.indices {
            entries[index].line = GuestIRC.chatLine(for: entries[index].message, emotes: emotes)
        }
        revision += 1
    }

    private mutating func remove(where shouldRemove: (Entry) -> Bool) {
        let before = entries.count
        entries.removeAll(where: shouldRemove)
        if entries.count != before {
            revision += 1
        }
    }
}
