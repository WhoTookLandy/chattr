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
}
