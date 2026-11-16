import Foundation
import TwitchKit

/// Pure merge/dedup rules for splicing chat history into a channel's ring:
/// the join-time backfill (history + buffered live, with a "New" divider
/// between them), the late-join merge, and the reconnect gap-fill.
///
/// Static + pure so they're unit-testable without a `TwitchClient`;
/// `ChannelSession` calls them and commits the results to its ring.
enum ChannelHistoryMerge {

    /// Merges rustlog `history` with `pendingLive` (events buffered while the
    /// backfill fetch was in flight), deduplicating by `messageId` and capping
    /// to `capacity`. When `divider` is non-nil it's inserted between the two
    /// blocks — after every history event, before the first buffered-live one —
    /// marking "everything above happened before you joined."
    ///
    /// `ChannelSession.applyBackfill(_:)` calls this and commits the result to
    /// the ring.
    static func mergeBackfill(
        history: [ChannelUpdate],
        pendingLive: [ChannelUpdate],
        capacity: Int,
        divider: ChannelUpdate? = nil
    ) -> [ChannelUpdate] {
        var seenMessageIds = Set<String>()
        var merged: [ChannelUpdate] = []
        merged.reserveCapacity(history.count + pendingLive.count + 1)

        // History first (oldest scrollback), then buffered-live in arrival
        // order. Chat messages dedup by canonical `messageId` — the same
        // message can land in BOTH rustlog history and the live buffer during
        // the fetch-overlap window. First occurrence wins, so a duplicate keeps
        // its chronological history position rather than jumping to the live tail.
        // Non-message events (notifications/raids/clears) never appear in
        // backfill and carry no shared id, so they pass through untouched.
        //
        // The divider goes between the blocks (not appended after dedup) so a
        // live duplicate that kept its history position still lands above it.
        for event in history {
            if case .message(let normalized) = event {
                guard seenMessageIds.insert(normalized.message.messageId).inserted else { continue }
            }
            merged.append(event)
        }
        if let divider {
            merged.append(divider)
        }
        for event in pendingLive {
            if case .message(let normalized) = event {
                guard seenMessageIds.insert(normalized.message.messageId).inserted else { continue }
            }
            merged.append(event)
        }

        return merged.count > capacity ? Array(merged.suffix(capacity)) : merged
    }

    /// Pure dedup: the fetched history messages the ring does NOT already
    /// hold, in fetched order. Empty when nothing was missed — callers then
    /// add nothing (no divider for a clean reconnect).
    static func missingMessages(
        _ fetched: [BackfillMessage],
        notIn ring: [ChannelUpdate]
    ) -> [BackfillMessage] {
        var knownMessageIds = Set<String>()
        for update in ring {
            if case .message(let normalized) = update {
                knownMessageIds.insert(normalized.message.messageId)
            }
        }
        return fetched.filter { !knownMessageIds.contains($0.message.messageId) }
    }
}
