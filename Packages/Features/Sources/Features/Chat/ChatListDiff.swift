import ChatModel

/// Pure diff between two `ChatLine` arrays. The chat list applies the
/// `orderedIDs` as a diffable snapshot (the data source derives
/// insert/delete/move from the id order) and then explicitly
/// `reconfigureItems(reconfigured)` — because a diffable snapshot whose item
/// identifiers are unchanged will NOT re-render a cell whose underlying
/// `ChatLine` value changed (the optimistic→delivered upgrade, `markFailed`,
/// and `deletedPlaceholder` flips all keep the same id).
///
/// UIKit-free on purpose: this is the testable core and must compile on
/// macOS (where the `UICollectionView` code is excluded by `#if canImport`).
enum ChatListDiff {

    struct Delta: Equatable {
        /// Ids present in `new` but not `old`.
        var inserted: [String]
        /// Ids present in `old` but not `new`.
        var removed: [String]
        /// Ids present in both whose `ChatLine` value changed.
        var reconfigured: [String]
        /// The full new id order — becomes the snapshot's item identifiers.
        var orderedIDs: [String]
    }

    static func compute(old: [ChatLine], new: [ChatLine]) -> Delta {
        // Fast path for the dominant live-chat shape — "drop a few off the
        // front, append a few to the tail, nothing in between changed." It
        // walks indices instead of building two whole-buffer dictionaries, so
        // the per-message main-thread cost during a busy channel drops from
        // 2×O(n) dictionary allocations to a single O(n) scan. Any shape it
        // can't prove is a clean append (a mid-buffer value flip like an
        // optimistic→delivered upgrade, a reorder) returns nil and we fall
        // through to the full diff below.
        if let fast = fastAppendDelta(old: old, new: new) { return fast }

        let oldByID = old.reduce(into: [String: ChatLine]()) { $0[$1.id] = $1 }
        let newByID = new.reduce(into: [String: ChatLine]()) { $0[$1.id] = $1 }

        var inserted: [String] = []
        var reconfigured: [String] = []
        // Walk `new` in order so the result arrays are deterministic
        // (id order follows display order — nice for tests + logging).
        for line in new {
            if let prior = oldByID[line.id] {
                if prior != line { reconfigured.append(line.id) }
            } else {
                inserted.append(line.id)
            }
        }
        let removed = old.compactMap { newByID[$0.id] == nil ? $0.id : nil }

        return Delta(
            inserted: inserted,
            removed: removed,
            reconfigured: reconfigured,
            orderedIDs: new.map(\.id)
        )
    }

    /// Allocation-light delta for the common "front-trim + append" shape.
    ///
    /// Returns a `Delta` byte-for-byte equal to `compute(old:new:)` **only**
    /// when `new` is `old` with zero-or-more lines dropped from the front and
    /// zero-or-more lines appended to the tail, and every overlapping line is
    /// unchanged by value. Returns `nil` for anything else — a value change in
    /// the overlap (reconfigure), a reorder, a prepend — so the caller can fall
    /// back to the full diff. No dictionary allocation on the hot path.
    static func fastAppendDelta(old: [ChatLine], new: [ChatLine]) -> Delta? {
        // From-empty (priming, or a cleared buffer refilling) is a pure append.
        if old.isEmpty {
            return Delta(inserted: new.map(\.id), removed: [], reconfigured: [], orderedIDs: new.map(\.id))
        }
        // new emptied while old wasn't is a removal, not an append — let the
        // full diff handle it.
        guard let first = new.first else { return nil }

        // `new[0]` must be some element of `old` (ids are unique in the buffer);
        // its position is how many lines were trimmed off the front.
        guard let trimCount = old.firstIndex(where: { $0.id == first.id }) else {
            return nil   // new[0] isn't in old → not a front-trim+append.
        }

        let overlapCount = old.count - trimCount
        // The overlap has to fit inside `new`; if `new` is shorter, lines were
        // removed from the middle/tail — not a clean append.
        guard new.count >= overlapCount else { return nil }

        // Every overlapping line must match by VALUE. A value-only change
        // (same id, e.g. optimistic→delivered, delete-flip) must surface as a
        // reconfigure, which only the full diff emits — so bail to it.
        for i in 0..<overlapCount where old[trimCount + i] != new[i] {
            return nil
        }

        return Delta(
            inserted: Array(new[overlapCount...].map(\.id)),
            removed: Array(old[0..<trimCount].map(\.id)),
            reconfigured: [],
            orderedIDs: new.map(\.id)
        )
    }
}
