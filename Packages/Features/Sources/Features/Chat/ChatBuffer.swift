import ChatModel

/// Sliding-window store of chat lines with an incrementally-maintained,
/// block-filtered projection.
///
/// Replaces `TabChatModel`'s old `allLines` array + per-message
/// `BlockFilter.apply` full rescan + `Array.removeFirst` front trim. Two costs
/// that used to be paid on every inbound message are now cheaper:
///
///   - **Filtering (#1):** the visible projection (`lines`) is maintained as
///     lines are appended and dropped, instead of re-filtering the whole
///     buffer on every message. For a viewer who has blocked someone this
///     turns a guaranteed O(n) filter+allocation per message into an O(1)
///     append-side check; the rare paths (a mid-buffer value change, a block-
///     set toggle) still rebuild from scratch, which is correct and uncommon.
///
///   - **Trimming (#3):** the unfiltered store is a head-index ring. Dropping
///     the oldest line advances `head` (a pointer bump) instead of memmoving
///     ~500 `ChatLine` structs. The dead prefix is compacted away in one batch
///     once it grows past `cap`, so the backing array never exceeds ~2×cap and
///     `head` stays bounded.
///
/// Pure value type, no SwiftUI/UIKit surface — the same "testable core"
/// philosophy as `ChatListDiff` and `ChannelSession.mergeBackfill`.
struct ChatBuffer {

    /// Maximum retained (unfiltered) lines. Appending past this drops oldest.
    let cap: Int

    /// Unfiltered backing store. The logical window is `storage[head...]`;
    /// everything before `head` is dead and reclaimed at the next compaction.
    private var storage: [ChatLine] = []
    private var head: Int = 0

    /// Block-filtered projection — the array the view renders. Maintained
    /// incrementally on the append path; rebuilt from the window only on the
    /// uncommon mutation / block-set paths.
    private(set) var lines: [ChatLine] = []

    /// Blocked author user-ids. Lines whose `authorUserId` is in this set are
    /// kept in `storage` (so dedup/echo logic still sees them) but excluded
    /// from `lines`.
    private var blocked: Set<String> = []

    init(cap: Int) {
        self.cap = cap
    }

    // MARK: - Queries (over the unfiltered window)

    /// Logical (unfiltered) line count.
    var count: Int { storage.count - head }

    /// The most-recently-appended line, or nil when empty. Reads the physical
    /// tail — always the newest line regardless of `head`.
    var last: ChatLine? { storage.last }

    var blockedIds: Set<String> {
        get { blocked }
        set {
            guard newValue != blocked else { return }
            blocked = newValue
            rebuildVisible()
        }
    }

    func contains(id: String) -> Bool { index(of: id) != nil }

    func line(id: String) -> ChatLine? {
        guard let idx = index(of: id) else { return nil }
        return storage[idx]
    }

    // MARK: - Mutation

    /// Appends a line and trims to the cap. Hot path: O(1) amortized (no full
    /// re-filter, no front memmove).
    mutating func append(_ line: ChatLine) {
        storage.append(line)
        if !blocked.contains(line.authorUserId) {
            lines.append(line)
        }
        trimToCap()
    }

    /// Replaces the line with `id` by value (e.g. optimistic→delivered upgrade,
    /// markFailed). Returns false if no line with that id is in the window.
    @discardableResult
    mutating func replace(id: String, with newLine: ChatLine) -> Bool {
        guard let idx = index(of: id) else { return false }
        storage[idx] = newLine
        rebuildVisible()
        return true
    }

    /// Removes the line with `id`. Returns false if it wasn't present.
    @discardableResult
    mutating func remove(id: String) -> Bool {
        guard let idx = index(of: id) else { return false }
        storage.remove(at: idx)
        rebuildVisible()
        return true
    }

    /// Transforms one line by id, if present.
    mutating func mutate(id: String, _ transform: (ChatLine) -> ChatLine) {
        guard let idx = index(of: id) else { return }
        storage[idx] = transform(storage[idx])
        rebuildVisible()
    }

    /// Transforms every line in the window (chat-clear shape).
    mutating func mutateAll(_ transform: (ChatLine) -> ChatLine) {
        guard head < storage.count else { return }
        for i in head..<storage.count {
            storage[i] = transform(storage[i])
        }
        rebuildVisible()
    }

    /// Transforms every line authored by `authorUserId` (user-timeout shape).
    mutating func mutateMatching(authorUserId: String, _ transform: (ChatLine) -> ChatLine) {
        guard head < storage.count else { return }
        for i in head..<storage.count where storage[i].authorUserId == authorUserId {
            storage[i] = transform(storage[i])
        }
        rebuildVisible()
    }

    /// Empties the buffer (keeps the configured `cap` and block set).
    mutating func reset() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        lines.removeAll(keepingCapacity: true)
    }

    // MARK: - Internals

    /// Index into `storage` of the line with `id`, searching only the live
    /// window. Linear scan — the by-id paths (echo reconciliation, deletes)
    /// are far colder than the append hot path.
    private func index(of id: String) -> Int? {
        guard head < storage.count else { return nil }
        for i in head..<storage.count where storage[i].id == id {
            return i
        }
        return nil
    }

    /// Drops oldest lines until the window is within `cap`, then compacts the
    /// dead prefix in one batch if it has grown large.
    private mutating func trimToCap() {
        while count > cap {
            let dropped = storage[head]
            head += 1
            // Because `lines` preserves order, the oldest logical line — if it
            // wasn't filtered out — is exactly `lines.first`. So a non-blocked
            // drop pops the visible front; a blocked drop touches nothing.
            if !blocked.contains(dropped.authorUserId), !lines.isEmpty {
                lines.removeFirst()
            }
        }
        // Reclaim the dead prefix once it's grown past a window's worth, so the
        // backing array stays ~cap..2×cap and `head` never runs away.
        if head >= cap {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// Rebuilds the visible projection from the live window. Used by the cold
    /// paths (mutation, block-set change) where an incremental update isn't
    /// straightforward. No-op-cheap when there are no blocks (slice copy).
    private mutating func rebuildVisible() {
        let window = storage[head...]
        if blocked.isEmpty {
            lines = Array(window)
        } else {
            lines = window.filter { !blocked.contains($0.authorUserId) }
        }
    }
}
