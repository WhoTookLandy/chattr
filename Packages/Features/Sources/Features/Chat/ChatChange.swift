import ChatModel

/// One atomic change to the visible chat list, emitted by `ChatBuffer` and
/// applied by `ChatListView` directly to its diffable data source.
///
/// This is the vocabulary of the model→view incremental-change contract. The
/// old path re-published the whole `[ChatLine]` every message and made the
/// view re-diff it (two whole-buffer dictionaries + a snapshot copy). With
/// `ChatChange`, the model emits exactly what it already knows changed, and the
/// view applies it — O(1) per message on both sides, no re-diff, no snapshot.
///
/// `reset` is the escape hatch: priming, a block-set change, or a missed batch
/// (SwiftUI coalesced two updates) all fall back to a wholesale replace, which
/// the view applies as a fresh snapshot.
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
