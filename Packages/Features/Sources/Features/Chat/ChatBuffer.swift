import ChatModel

/// Sliding-window store of chat lines with an incrementally-maintained,
/// block-filtered projection, that also emits a typed `[ChatChange]` for every
/// mutation.
///
/// Replaces `ChatTranscriptModel`'s old `allLines` array + per-message
/// `BlockFilter.apply` full rescan + `Array.removeFirst` front trim, and now
/// additionally records *what changed* so the view can apply it directly
/// instead of re-diffing the whole array:
///
///   - **Filtering (#1):** the visible projection (`lines`) is maintained as
///     lines are appended and dropped, not re-filtered every message.
///   - **Trimming (#3):** the unfiltered store is a head-index ring — dropping
///     the oldest line is a pointer bump + batch compaction, not a memmove.
///   - **Change emission:** each op records `.appended` / `.removed` /
///     `.reconfigured` / `.reset` into `pendingChanges`; `takeChanges()` drains
///     them. The contract (`ChatChangeContractTests`) guarantees applying a
///     batch to the previous visible state reproduces the new one exactly, so
///     the view never has to re-diff.
///   - **Late moderation:** visible lines that age out are remembered (up to
///     `cap`) so a delete / timeout / clear that arrives afterwards still
///     reaches a view holding them on screen (see `trimmed`).
///
/// Pure value type, no SwiftUI/UIKit surface.
struct ChatBuffer {

    /// Maximum retained (unfiltered) lines. Appending past this drops oldest.
    let cap: Int

    /// Unfiltered backing store. The live window is `storage[head...]`;
    /// everything before `head` is dead and reclaimed at the next compaction.
    private var storage: [ChatLine] = []
    private var head: Int = 0

    /// Backing store for the block-filtered projection. The live visible
    /// window is `_lines[linesHead...]`; everything before `linesHead` is dead
    /// and reclaimed at the next compaction — the same head-index ring trick
    /// `storage` uses, applied to the projection so a front-trim is an O(1)
    /// pointer bump instead of an O(visible) `removeFirst` memmove on every
    /// message once the buffer is at cap.
    private var _lines: [ChatLine] = []
    private var linesHead: Int = 0

    /// Block-filtered projection — the array the view renders. Maintained
    /// incrementally; the emitted changes mirror every transition. Reading is
    /// a cold path (reset/first-mount/`isEmpty`), so materializing the window
    /// here is fine; the per-message hot path appends + bumps, never reads this.
    private(set) var lines: [ChatLine] {
        get { linesHead == 0 ? _lines : Array(_lines[linesHead...]) }
        set { _lines = newValue; linesHead = 0 }
    }

    /// Number of currently-visible lines — O(1), avoids materializing `lines`.
    /// Internal (not private): `TranscriptStore.publishPending` reads it so the
    /// empty-state check matches the *filtered* projection without paying the
    /// `lines` getter's window copy.
    var visibleCount: Int { _lines.count - linesHead }

    /// Blocked author user-ids. Lines whose `authorUserId` is in this set stay
    /// in `storage` (so dedup/echo logic still sees them) but are excluded
    /// from `lines`.
    private var blocked: Set<String> = []

    /// Undrained changes since the last `takeChanges()`. Each mutation appends
    /// the visible-list effect it produced.
    private var pendingChanges: [ChatChange] = []

    /// id → absolute index into `storage`, maintained by every mutation so
    /// `index(of:)` — and therefore the per-message dedup check
    /// (`contains(id:)`) — is O(1) instead of a linear scan of the window.
    /// Entries are removed as lines drop off the ring, and values are shifted
    /// on the (rare) mid-array remove and the amortized compaction.
    private var indexByID: [String: Int] = [:]

    /// Visible lines that recently aged out of the window, by id (FIFO,
    /// bounded at `cap`). `ChatListFeed` holds trims back while the reader is
    /// in scrollback, so during a firehose most of what's on screen has
    /// already left the buffer — and moderation arriving after that (a mass
    /// ban in a hate raid) used to find nothing to edit, leaving those rows
    /// un-struck until the reader returned to the live edge. The `mutate…`
    /// methods also apply to these lines and emit `.reconfigured` for them:
    /// a view applies that only if it still shows the row, and against
    /// `lines` it's a no-op, so the change contract is unaffected. Never
    /// consulted by `contains` / `line(id:)` — dedup semantics are unchanged.
    private var trimmed: [String: ChatLine] = [:]
    /// Eviction order for `trimmed`; live entries are `trimmedOrder[trimmedHead...]`.
    private var trimmedOrder: [String] = []
    private var trimmedHead = 0

    init(cap: Int) {
        self.cap = cap
    }

    // MARK: - Queries (over the unfiltered window)

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    /// The most-recently-appended line, or nil when empty (physical tail —
    /// always the newest regardless of `head`).
    var last: ChatLine? { storage.last }

    var blockedIds: Set<String> {
        get { blocked }
        set {
            guard newValue != blocked else { return }
            blocked = newValue
            rebuildVisible()
            // A block-set change can add/remove arbitrary lines at arbitrary
            // positions — a wholesale reset is the honest, position-safe edit.
            pendingChanges.append(.reset(lines))
        }
    }

    func contains(id: String) -> Bool { index(of: id) != nil }

    func line(id: String) -> ChatLine? {
        guard let idx = index(of: id) else { return nil }
        return storage[idx]
    }

    /// Drains and returns the changes accumulated since the last call.
    ///
    /// Empty is the common case (a view pull or flush that finds nothing
    /// new), so that path returns without writing the stored array at all.
    mutating func takeChanges() -> [ChatChange] {
        guard !pendingChanges.isEmpty else { return [] }
        let drained = pendingChanges
        // Fresh storage sized like the last batch: the drained array keeps
        // the old buffer, so `removeAll(keepingCapacity:)` would have had to
        // copy-allocate anyway.
        pendingChanges = []
        pendingChanges.reserveCapacity(drained.count)
        return drained
    }

    // MARK: - Mutation

    /// Appends a line and trims to the cap. Hot path: O(1) amortized.
    mutating func append(_ line: ChatLine) {
        storage.append(line)
        indexByID[line.id] = storage.count - 1
        if !blocked.contains(line.authorUserId) {
            _lines.append(line)
            pendingChanges.append(.appended(line))
        }
        trimToCap()
    }

    /// Replaces the line with `id` by value. Returns false if absent.
    @discardableResult
    mutating func replace(id: String, with newLine: ChatLine) -> Bool {
        guard let idx = index(of: id) else { return false }
        let old = storage[idx]
        storage[idx] = newLine
        if newLine.id != id {
            // Pending-send rows get re-keyed to the server-issued id.
            indexByID[id] = nil
            indexByID[newLine.id] = idx
        }
        applyVisibilityTransition(id: id, storageIndex: idx, old: old, new: newLine)
        return true
    }

    /// Removes the line with `id`. Returns false if absent.
    @discardableResult
    mutating func remove(id: String) -> Bool {
        guard let idx = index(of: id) else { return false }
        let removed = storage[idx]
        let isVisible = !blocked.contains(removed.authorUserId)
        // Locate the visible copy BEFORE the storage shift: the aligned fast
        // path in `visibleIndex` reads `idx` against the current layout.
        let vi = isVisible ? visibleIndex(of: id, storageIndex: idx) : nil
        storage.remove(at: idx)
        // Only the lines after `idx` shifted down one, so re-point just those
        // instead of rebuilding the whole table with `mapValues`. Removes hit
        // recent lines in practice (retry / stuck-send cleanup of the user's
        // own sends), so this is a short walk from the tail.
        indexByID[id] = nil
        if idx < storage.count {
            for i in idx..<storage.count {
                indexByID[storage[i].id] = i
            }
        }
        if isVisible {
            if let vi { _lines.remove(at: vi) }
            pendingChanges.append(.removed(id: id))
        }
        return true
    }

    /// Transforms one line by id, if present — or, if it recently aged out,
    /// its retained copy (see `trimmed`).
    mutating func mutate(id: String, _ transform: (ChatLine) -> ChatLine) {
        guard let idx = index(of: id) else {
            mutateTrimmed(id: id, transform)
            return
        }
        let old = storage[idx]
        let new = transform(old)
        storage[idx] = new
        if new.id != id {
            indexByID[id] = nil
            indexByID[new.id] = idx
        }
        applyVisibilityTransition(id: id, storageIndex: idx, old: old, new: new)
    }

    /// Transforms every line in the window (chat-clear shape). `transform` must
    /// preserve `authorUserId` (so visibility is unchanged) and `id` (so the
    /// id→index side table stays valid) — true for the only caller,
    /// `markingDeleted()`. Recently trimmed lines are transformed too.
    mutating func mutateAll(_ transform: (ChatLine) -> ChatLine) {
        mutateTrimmed { transform($0) }
        guard head < storage.count else { return }
        for i in head..<storage.count {
            storage[i] = transform(storage[i])
        }
        for i in linesHead..<_lines.count {
            let new = transform(_lines[i])
            _lines[i] = new
            pendingChanges.append(.reconfigured(new))
        }
    }

    /// Transforms every line authored by `authorUserId` (user-timeout shape),
    /// recently trimmed ones included.
    mutating func mutateMatching(authorUserId: String, _ transform: (ChatLine) -> ChatLine) {
        mutateTrimmed { $0.authorUserId == authorUserId ? transform($0) : nil }
        guard head < storage.count else { return }
        for i in head..<storage.count where storage[i].authorUserId == authorUserId {
            storage[i] = transform(storage[i])
        }
        for i in linesHead..<_lines.count where _lines[i].authorUserId == authorUserId {
            let new = transform(_lines[i])
            _lines[i] = new
            pendingChanges.append(.reconfigured(new))
        }
    }

    /// Empties the buffer (keeps the configured `cap` and block set).
    mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        _lines.removeAll(keepingCapacity: true)
        linesHead = 0
        indexByID.removeAll(keepingCapacity: true)
        trimmed.removeAll()
        trimmedOrder.removeAll()
        trimmedHead = 0
        pendingChanges.append(.reset([]))
    }

    // MARK: - Internals

    /// Remembers a visible line the window just dropped (see `trimmed`),
    /// evicting the oldest past `cap`. O(1) amortized — same head-index ring
    /// trick as `storage`.
    private mutating func retainTrimmed(_ line: ChatLine) {
        trimmed[line.id] = line
        trimmedOrder.append(line.id)
        if trimmedOrder.count - trimmedHead > cap {
            trimmed[trimmedOrder[trimmedHead]] = nil
            trimmedHead += 1
        }
        if trimmedHead >= cap {
            trimmedOrder.removeFirst(trimmedHead)
            trimmedHead = 0
        }
    }

    /// Single-line edit of a recently trimmed line. Emits `.reconfigured` only
    /// when the value actually changed (moderation edits are idempotent) and
    /// the id is kept — re-keys only ever target pending sends still in the
    /// window.
    private mutating func mutateTrimmed(id: String, _ transform: (ChatLine) -> ChatLine) {
        guard let old = trimmed[id] else { return }
        let new = transform(old)
        guard new.id == id, new != old else { return }
        trimmed[id] = new
        pendingChanges.append(.reconfigured(new))
    }

    /// Bulk edit of recently trimmed lines; `edit` returns nil to skip one.
    /// O(retained) — only the rare chat-clear / user-timeout paths use it.
    private mutating func mutateTrimmed(_ edit: (ChatLine) -> ChatLine?) {
        guard !trimmed.isEmpty else { return }
        var changed: [ChatLine] = []
        for (id, old) in trimmed {
            if let new = edit(old), new.id == id, new != old { changed.append(new) }
        }
        for line in changed {
            trimmed[line.id] = line
            pendingChanges.append(.reconfigured(line))
        }
    }

    private func index(of id: String) -> Int? {
        // O(1) via the maintained side table. Dropped lines are pruned from
        // the table as the head advances, so the `>= head` guard is pure
        // defense against a maintenance bug, not an expected state.
        guard let idx = indexByID[id], idx >= head, idx < storage.count else { return nil }
        return idx
    }

    /// Index into `_lines` of the visible line with `id` (stored at absolute
    /// `storageIndex`), or nil if not visible.
    ///
    /// O(1) when nobody is blocked: the visible window is then exactly the
    /// storage window (every append lands in both, every trim / remove /
    /// rebuild drops from both), so the offsets line up — verified against
    /// the id, never assumed. Otherwise a scan of the live window from the
    /// NEWEST end, since edits overwhelmingly target recent lines (echo
    /// upgrades, send failures, fresh moderation deletes).
    private func visibleIndex(of id: String, storageIndex: Int) -> Int? {
        if blocked.isEmpty {
            let aligned = linesHead + (storageIndex - head)
            if aligned >= linesHead, aligned < _lines.count, _lines[aligned].id == id {
                return aligned
            }
        }
        guard linesHead < _lines.count else { return nil }
        for i in stride(from: _lines.count - 1, through: linesHead, by: -1) where _lines[i].id == id {
            return i
        }
        return nil
    }

    /// Emits the right change for a single-line value edit, accounting for a
    /// (rare) change in whether the line is visible. The common case — author
    /// unchanged, line stays visible — is a single `.reconfigured`.
    ///
    /// `storageIndex` is the edited line's absolute index in `storage`; the
    /// projection (`_lines`) still holds the OLD line (keyed by `id`) when
    /// this runs.
    private mutating func applyVisibilityTransition(id: String, storageIndex: Int, old: ChatLine, new: ChatLine) {
        let wasVisible = !blocked.contains(old.authorUserId)
        let nowVisible = !blocked.contains(new.authorUserId)
        switch (wasVisible, nowVisible) {
        case (true, true):
            if let vi = visibleIndex(of: id, storageIndex: storageIndex) {
                _lines[vi] = new
            }
            // A pending-send row re-keyed to its server id keeps its slot but
            // changes identity — only `.rekeyed` lets the view find the row.
            pendingChanges.append(new.id == id ? .reconfigured(new) : .rekeyed(from: id, to: new))
        case (true, false):
            if let vi = visibleIndex(of: id, storageIndex: storageIndex) { _lines.remove(at: vi) }
            pendingChanges.append(.removed(id: id))
        case (false, true):
            // Now-visible line has to slot back in at its window position —
            // position-sensitive, so reset the projection wholesale.
            rebuildVisible()
            pendingChanges.append(.reset(lines))
        case (false, false):
            break
        }
    }

    private mutating func trimToCap() {
        while count > cap {
            let dropped = storage[head]
            head += 1
            indexByID[dropped.id] = nil
            // The oldest logical line, if not filtered, is exactly the visible
            // window's front (`_lines[linesHead]`). Drop it by bumping the head
            // — O(1) — instead of an O(visible) `removeFirst` memmove.
            if !blocked.contains(dropped.authorUserId), linesHead < _lines.count {
                linesHead += 1
                pendingChanges.append(.removed(id: dropped.id))
                retainTrimmed(dropped)
            }
        }
        if head >= cap {
            storage.removeFirst(head)
            // Compaction shifted every survivor down by `head`; re-base the
            // side table in the same batch. O(cap) once per `cap` appends —
            // amortized O(1), same budget as the `removeFirst` itself.
            indexByID = indexByID.mapValues { $0 - head }
            head = 0
        }
        // Reclaim the dead prefix in one batch once it grows past the cap —
        // the same amortized-compaction the `storage` ring uses above.
        if linesHead >= cap {
            _lines.removeFirst(linesHead)
            linesHead = 0
        }
    }

    private mutating func rebuildVisible() {
        let window = storage[head...]
        if blocked.isEmpty {
            lines = Array(window)
        } else {
            lines = window.filter { !blocked.contains($0.authorUserId) }
        }
    }
}
