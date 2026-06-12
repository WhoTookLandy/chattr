import Foundation

/// Per-channel memo of `Normalizer.normalize` results, keyed by Twitch
/// messageId.
///
/// ## Why this exists
///
/// The channel session's ring stores RAW events; the display form
/// (`ChatLine`) is derived per message by the Normalizer — word tokenizing
/// plus an emote-table lookup per word. That derivation is deterministic,
/// but it used to run on the main thread for the entire ring every time a
/// chat tab remounted (each swipe in the paged tab view), re-deriving
/// hundreds of identical results per swipe. Owned by
/// `ChannelSessionRegistry` with the same lifetime as the session, this
/// cache makes each message pay normalization once — on live arrival — and
/// turns re-prime into dictionary hits.
///
/// ## Context stamping
///
/// Normalization is only deterministic for fixed inputs: the third-party
/// emote table, the viewer's login (self-mentions), and their highlight
/// keywords. Those are near-constant but DO change — most commonly the
/// emote table going empty→loaded a moment after a channel opens. Rather
/// than subscribing to those inputs, every read/write carries a `Context`
/// fingerprint; a mismatch wipes the cache wholesale (the cheap, obviously-
/// correct invalidation — stale entries are at worst a few hundred early
/// messages). This also fixes a pre-cache quirk: messages normalized before
/// the emote table loaded kept their emotes as plain text for the tab's
/// whole life; now the version bump re-normalizes them on the next prime.
///
/// `@MainActor` because both writers (`ChatTranscriptModel.ingest`, on the live
/// path) and the owner (`ChannelSessionRegistry`) are main-actor isolated.
@MainActor
public final class NormalizedLineCache {

    /// Fingerprint of the normalization inputs a cached line was built
    /// with. Reads under a different context miss; writes under a
    /// different context reset the cache to it.
    public struct Context: Equatable, Sendable {
        /// `EmoteIndex.snapshot().count` — 0 before the provider fetches
        /// land, the table size after. Loads are idempotent-once per
        /// channel, so the count only moves on a real table change.
        public let emoteVersion: Int
        public let currentUserLogin: String
        public let highlightKeywords: [String]

        public init(emoteVersion: Int, currentUserLogin: String, highlightKeywords: [String]) {
            self.emoteVersion = emoteVersion
            self.currentUserLogin = currentUserLogin
            self.highlightKeywords = highlightKeywords
        }
    }

    /// Maximum retained lines. Sized by the owner to comfortably cover the
    /// session ring (2× the chat-history limit) so a full re-prime is all
    /// hits; FIFO eviction matches the ring's own oldest-first trim.
    private let capacity: Int

    private var context: Context?
    private var linesByID: [String: ChatLine] = [:]
    /// Insertion order for FIFO eviction. Ids arrive in ring order, so
    /// evicting the front mirrors the ring dropping its oldest event.
    private var insertionOrder: [String] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// The cached line for `id`, or nil on a miss — including the
    /// whole-cache miss when `context` doesn't match what entries were
    /// built with.
    public func line(id: String, context: Context) -> ChatLine? {
        guard context == self.context else { return nil }
        return linesByID[id]
    }

    /// Stores a freshly normalized line. A context change resets the cache
    /// first (all prior entries were built from outdated inputs). Re-storing
    /// an existing id (echo upgrade) replaces in place without consuming a
    /// second slot.
    public func store(_ line: ChatLine, context: Context) {
        if context != self.context {
            linesByID.removeAll(keepingCapacity: true)
            insertionOrder.removeAll(keepingCapacity: true)
            self.context = context
        }
        if linesByID.updateValue(line, forKey: line.id) == nil {
            insertionOrder.append(line.id)
            if insertionOrder.count > capacity {
                linesByID.removeValue(forKey: insertionOrder.removeFirst())
            }
        }
    }
}
