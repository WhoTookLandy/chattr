import ChatModel

/// One atomic change to the visible chat list, emitted by `ChatBuffer` and
/// applied by `ChatListView` directly to its diffable data source.
///
/// This is the vocabulary of the model→view incremental-change contract. The
/// old path re-published the whole `[ChatLine]` every message and made the
/// view re-diff it (two whole-buffer dictionaries + a snapshot copy). With
/// `ChatChange`, the model emits exactly what it already knows changed, and the
/// view applies it with no re-diff of the line array. Cost: O(1) per change
/// on the model side; the view folds every change since its last update
/// into ONE diffable-snapshot apply (UIKit's apply itself is O(rows) — the
/// floor for any diffable update, now paid once per flush instead of twice
/// per message). Batches travel through the versioned `ChatChangeLog`, so a
/// view that missed publishes replays them instead of guessing.
///
/// `reset` is the escape hatch: priming, a block-set change, or an
/// (un)blocked line reappearing all fall back to a wholesale replace, which
/// the view applies as a fresh snapshot (reconfiguring surviving rows whose
/// value changed).
enum ChatChange: Equatable {
    /// A new line was appended at the tail of the visible list.
    case appended(ChatLine)
    /// The line with this id left the visible list (trimmed, removed, or
    /// newly block-filtered).
    case removed(id: String)
    /// The line with this id changed value but kept its position AND its id
    /// (markFailed, delete-flip, chat-clear).
    case reconfigured(ChatLine)
    /// The line with id `from` was replaced in place by `to`, which carries a
    /// different id — an optimistic `pending-…` send row upgraded to its
    /// server-issued message id (echo reconciliation or the stuck-send
    /// fallback). Position unchanged. A distinct case because the view keys
    /// rows by id: emitted as `.reconfigured(to)` it would look up `to.id`,
    /// find nothing, and leave the dimmed `.sending` row on screen forever.
    case rekeyed(from: String, to: ChatLine)
    /// The visible list was replaced wholesale with this exact array.
    case reset([ChatLine])

    /// Reference applier: folds `changes` onto `lines`, reproducing the state
    /// the emitter ended in. This is both the semantics the view must match and
    /// the oracle the contract tests check `ChatBuffer`'s emissions against.
    static func apply(_ changes: [ChatChange], to lines: [ChatLine]) -> [ChatLine] {
        var result = lines
        for change in changes {
            switch change {
            case .appended(let line):
                result.append(line)
            case .removed(let id):
                if let idx = result.firstIndex(where: { $0.id == id }) {
                    result.remove(at: idx)
                }
            case .reconfigured(let line):
                if let idx = result.firstIndex(where: { $0.id == line.id }) {
                    result[idx] = line
                }
            case .rekeyed(let from, let line):
                if let idx = result.firstIndex(where: { $0.id == from }) {
                    result[idx] = line
                }
            case .reset(let lines):
                result = lines
            }
        }
        return result
    }
}

/// Bounded, versioned log of published `ChatChange` batches — the delivery
/// channel between `ChatTranscriptModel` and its views.
///
/// SwiftUI coalesces observation invalidations, so a view can never assume it
/// saw every publish. Instead each reader remembers the last version it
/// consumed and asks for `changes(since:)`, which replays EVERY batch after
/// it, in order. Only a reader that fell behind by more than `capacity`
/// batches (its next batch was evicted) gets `.overrun` and must reset from a
/// snapshot. Multiple readers (the chat list, an open thread sheet) consume
/// independently.
///
/// Versions are contiguous: each non-empty `append` is exactly
/// `headVersion + 1`, so the retained window is
/// `(headVersion - batches.count + 1)...headVersion` and lookup is index
/// arithmetic. Pure value type.
struct ChatChangeLog {

    /// What a reader at some version needs to catch up.
    enum Delta: Equatable {
        /// Every change published after the reader's version, flattened in
        /// publish order (empty when already current). `through` is the
        /// version the reader is at once it has consumed them.
        case changes([ChatChange], through: Int)
        /// The reader's next batch was evicted (or its version is unknown,
        /// e.g. `-1` before first read). It must reset from a snapshot taken
        /// at `head` or later.
        case overrun(head: Int)
    }

    /// Batches retained for readers that fall behind. A transcript flush
    /// publishes at most one batch per coalescing window (~one frame), so the
    /// default covers ~2s at the ceiling rate — far longer than any gap
    /// between SwiftUI updates of an on-screen view.
    static let defaultCapacity = 120

    let capacity: Int

    /// Version of the newest batch; `0` before anything was published.
    private(set) var headVersion = 0

    /// Retained batches, oldest first; `batches.last` is `headVersion`.
    private var batches: [[ChatChange]] = []

    init(capacity: Int = ChatChangeLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Version of the oldest retained batch (`headVersion + 1` when empty).
    private var oldestVersion: Int { headVersion - batches.count + 1 }

    /// Publishes `changes` as the next version. Empty batches are dropped —
    /// they'd bump the version without giving readers anything to apply.
    mutating func append(_ changes: [ChatChange]) {
        guard !changes.isEmpty else { return }
        headVersion += 1
        batches.append(changes)
        if batches.count > capacity {
            // O(capacity) pointer shuffle, capacity is small.
            batches.removeFirst(batches.count - capacity)
        }
    }

    /// Everything a reader at `version` hasn't consumed yet.
    func changes(since version: Int) -> Delta {
        if version == headVersion { return .changes([], through: headVersion) }
        // Next needed batch is `version + 1`; it must still be retained, and
        // a version from the future means the reader is confused — reset it.
        guard version + 1 >= oldestVersion, version < headVersion else {
            return .overrun(head: headVersion)
        }
        let start = version + 1 - oldestVersion
        // Common case: exactly one batch behind — hand it over without
        // allocating a flattened copy.
        if start == batches.count - 1 { return .changes(batches[start], through: headVersion) }
        return .changes(Array(batches[start...].joined()), through: headVersion)
    }
}
