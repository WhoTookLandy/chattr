import Foundation
import Observation
import Core

/// The Activity tab's inbox: every @-mention of the signed-in user and every
/// highlight-keyword hit, across all open chats, newest first.
///
/// Fed by the mention watcher `AppShell` already runs per open tab (one
/// subscription per channel, live rows only — never backfilled history), so
/// it costs no extra connections. In-memory for the app session and capped
/// at `capacity`; it's a "what did I miss" list, not an archive.
@MainActor
@Observable
public final class ActivityStore {

    public struct Entry: Identifiable, Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            case mention
            case keyword
        }

        /// The chat message id — also the dedupe key (two tabs on the same
        /// channel would otherwise report one ping twice).
        public let id: String
        public let channel: ChannelDescriptor
        public let authorDisplayName: String
        /// Twitch hex color ("" when the chatter never picked one).
        public let authorColor: String
        public let text: String
        public let timestamp: Date
        public let reason: Reason
    }

    static let capacity = 200

    public private(set) var entries: [Entry] = []
    /// Entries recorded since the Activity tab was last viewed — the badge.
    public private(set) var unreadCount = 0

    @ObservationIgnored private var seenIds: Set<String> = []

    public init() {}

    /// Records new hits (any order); duplicates by message id are dropped.
    /// `asRead` files them without counting them as unread — for hits the
    /// user is already looking at (the chat on screen).
    public func record(_ newEntries: [Entry], asRead: Bool = false) {
        let fresh = newEntries.filter { seenIds.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        entries.insert(contentsOf: fresh.sorted { $0.timestamp > $1.timestamp }, at: 0)
        if !asRead { unreadCount += fresh.count }
        if entries.count > Self.capacity {
            for dropped in entries[Self.capacity...] { seenIds.remove(dropped.id) }
            entries.removeLast(entries.count - Self.capacity)
        }
    }

    public func markAllRead() {
        if unreadCount != 0 { unreadCount = 0 }
    }

    public func clear() {
        entries = []
        seenIds = []
        unreadCount = 0
    }
}
