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
///
/// Pure value type, no SwiftUI/UIKit surface.
struct ChatBuffer {

    /// Maximum retained (unfiltered) lines. Appending past this drops oldest.
    let cap: Int

    /// Unfiltered backing store. The live window is `storage[head...]`;
    /// everything before `head` is dead and reclaimed at the next compaction.
    private var storage: [ChatLine] = []
    private var head: Int = 0

    /// Block-filtered projection — the array the view renders. Maintained
    /// incrementally; the emitted changes mirror every transition.
    private(set) var lines: [ChatLine] = []

    /// Blocked author user-ids. Lines whose `authorUserId` is in this set stay
    /// in `storage` (so dedup/echo logic still sees them) but are excluded
    /// from `lines`.
    private var blocked: Set<String> = []

    /// Undrained changes since the last `takeChanges()`. Each mutation appends
    /// the visible-list effect it produced.
    private var pendingChanges: [ChatChange] = []

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
    mutating func takeChanges() -> [ChatChange] {
        defer { pendingChanges.removeAll(keepingCapacity: true) }
        return pendingChanges
    }

    // MARK: - Mutation

    /// Appends a line and trims to the cap. Hot path: O(1) amortized.
    mutating func append(_ line: ChatLine) {
        storage.append(line)
        if !blocked.contains(line.authorUserId) {
            lines.append(line)
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
        applyVisibilityTransition(id: id, old: old, new: newLine)
        return true
    }

    /// Removes the line with `id`. Returns false if absent.
    @discardableResult
    mutating func remove(id: String) -> Bool {
        guard let idx = index(of: id) else { return false }
        let removed = storage[idx]
        storage.remove(at: idx)
        if !blocked.contains(removed.authorUserId) {
            lines.removeAll { $0.id == id }
            pendingChanges.append(.removed(id: id))
        }
        return true
    }

    /// Transforms one line by id, if present.
    mutating func mutate(id: String, _ transform: (ChatLine) -> ChatLine) {
        guard let idx = index(of: id) else { return }
        let old = storage[idx]
        let new = transform(old)
        storage[idx] = new
        applyVisibilityTransition(id: id, old: old, new: new)
    }

    /// Transforms every line in the window (chat-clear shape). `transform` must
    /// preserve `authorUserId` (so visibility is unchanged) — true for the only
    /// caller, `markingDeleted()`.
    mutating func mutateAll(_ transform: (ChatLine) -> ChatLine) {
        guard head < storage.count else { return }
        for i in head..<storage.count {
            storage[i] = transform(storage[i])
        }
        for vi in lines.indices {
            let new = transform(lines[vi])
            lines[vi] = new
            pendingChanges.append(.reconfigured(new))
        }
    }

    /// Transforms every line authored by `authorUserId` (user-timeout shape).
    mutating func mutateMatching(authorUserId: String, _ transform: (ChatLine) -> ChatLine) {
        guard head < storage.count else { return }
        for i in head..<storage.count where storage[i].authorUserId == authorUserId {
            storage[i] = transform(storage[i])
        }
        for vi in lines.indices where lines[vi].authorUserId == authorUserId {
            let new = transform(lines[vi])
            lines[vi] = new
            pendingChanges.append(.reconfigured(new))
        }
    }

    /// Empties the buffer (keeps the configured `cap` and block set).
    mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        lines.removeAll(keepingCapacity: true)
        pendingChanges.append(.reset([]))
    }

    // MARK: - Internals

    private func index(of id: String) -> Int? {
        guard head < storage.count else { return nil }
        for i in head..<storage.count where storage[i].id == id {
            return i
        }
        return nil
    }

    /// Emits the right change for a single-line value edit, accounting for a
    /// (rare) change in whether the line is visible. The common case — author
    /// unchanged, line stays visible — is a single `.reconfigured`.
    private mutating func applyVisibilityTransition(id: String, old: ChatLine, new: ChatLine) {
        let wasVisible = !blocked.contains(old.authorUserId)
        let nowVisible = !blocked.contains(new.authorUserId)
        switch (wasVisible, nowVisible) {
        case (true, true):
            if let vi = lines.firstIndex(where: { $0.id == id }) {
                lines[vi] = new
            }
            pendingChanges.append(.reconfigured(new))
        case (true, false):
            lines.removeAll { $0.id == id }
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
            // The oldest logical line, if not filtered, is exactly `lines.first`.
            if !blocked.contains(dropped.authorUserId), !lines.isEmpty {
                lines.removeFirst()
                pendingChanges.append(.removed(id: dropped.id))
            }
        }
        if head >= cap {
            storage.removeFirst(head)
            head = 0
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
