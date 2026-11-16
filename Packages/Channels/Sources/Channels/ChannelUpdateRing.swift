import Foundation

/// Fixed-capacity ring of display-ready `ChannelUpdate`s — the canonical
/// per-channel state `ChannelSession` primes subscribers from.
///
/// Head-index ring: the live window is `storage[head...]`; everything before
/// `head` is dead and reclaimed at the next batch compaction (see `append`).
/// Same technique as `ChatBuffer` — a front trim is an O(1) pointer bump, not
/// an O(count) `removeFirst` memmove per event. Readers go through
/// `snapshot`, never `storage` directly.
///
/// Holding normalized rows (not raw events) is what makes the ring the
/// normalize memo: a tab that re-attaches primes from finished lines.
///
/// A value type owned by (and only ever mutated inside) the session actor.
struct ChannelUpdateRing {

    /// Set at construction from the user's Chat History setting (default
    /// 500). Fixed for the session's lifetime — a changed setting applies
    /// to sessions created after it (i.e. newly opened channel tabs).
    let capacity: Int

    private var storage: [ChannelUpdate] = []
    private var head: Int = 0

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// The live window, materialized. O(count) copy — acceptable on the cold
    /// paths that read it (subscribe prime, one-shot snapshot, resync dedup),
    /// never touched on the per-event hot path.
    var snapshot: [ChannelUpdate] {
        head == 0 ? storage : Array(storage[head...])
    }

    /// Number of updates in the live window.
    var count: Int { storage.count - head }

    var isEmpty: Bool { count == 0 }

    /// Appends one update, dropping the oldest past `capacity`. The single
    /// owner of the cap invariant — every post-backfill ring write goes
    /// through here (via the session's `emit`) so the trim logic can't drift
    /// between call sites.
    ///
    /// O(1) amortized: at capacity (the steady state for any long-open
    /// channel) each append bumps `head` instead of paying an O(count)
    /// `removeFirst` memmove — under raid bursts (50-200 events/sec) that
    /// memmove compounded on every single event. The dead prefix is reclaimed
    /// in one batch once per `capacity` appends.
    mutating func append(_ event: ChannelUpdate) {
        storage.append(event)
        if storage.count - head > capacity {
            head += 1
        }
        if head >= capacity {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// Replaces the whole window. Callers pass an already-capped list (see
    /// `ChannelHistoryMerge.mergeBackfill`).
    mutating func replace(with updates: [ChannelUpdate]) {
        storage = updates
        head = 0
    }

    /// Rewrites, in place, each live-window message for which `transform`
    /// returns a replacement. Returns how many were replaced.
    mutating func refreshMessages(
        _ transform: (NormalizedMessage) -> NormalizedMessage?
    ) -> Int {
        var refreshed = 0
        for index in head..<storage.count {
            guard case .message(let stale) = storage[index],
                  let replacement = transform(stale) else { continue }
            storage[index] = .message(replacement)
            refreshed += 1
        }
        return refreshed
    }
}
