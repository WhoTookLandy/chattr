import ChatModel

/// One data-source update for the chat list, in item-identifier terms, so the
/// UIKit layer can fold it into a SINGLE `NSDiffableDataSourceSnapshot` apply.
///
/// Apply order: start from `resetIds` (a fresh item list) when non-nil, else
/// from the current snapshot; run `steps` in order; then reconfigure
/// `reconfigure`. Guarantees, relied on by `ChatListViewController` because
/// diffable snapshots throw on violations:
///   - no step inserts an identifier that is already present, and no
///     `.delete` / `.replace` names one that is absent;
///   - every `reconfigure` id is present after the steps AND was in the data
///     source before this edit (a row inserted by this edit is configured
///     fresh from `linesByID`; it never needs a reconfigure).
struct ChatListEdit: Equatable {
    enum Step: Equatable {
        /// Remove these identifiers.
        case delete([String])
        /// Append these identifiers at the tail, in order.
        case append([String])
        /// Swap identifier `from` for `with` at the same position.
        case replace(from: String, with: String)
    }

    var resetIds: [String]?
    var steps: [Step] = []
    var reconfigure: [String] = []

    var isEmpty: Bool { resetIds == nil && steps.isEmpty && reconfigure.isEmpty }
}

/// The chat list's consumer of `ChatChangeLog`: tracks exactly what the data
/// source shows, turns everything published since the last update into one
/// `ChatListEdit`, and holds structural changes back while the user reads
/// scrollback. Pure value type — `ChatListViewController` owns one and applies
/// its edits; tests drive it directly (the controller is iOS-only).
///
/// ## Why it exists
///
/// The view used to apply only the latest batch when the publish version
/// advanced by exactly one and fall back to a full reset otherwise. SwiftUI
/// coalesces invalidations, so under load most updates were resets — and the
/// reset path dropped pending reconfigures, so deletes / delivery flips /
/// send failures never reached rows that were already on screen. The feed
/// replays every batch since its last version, resets only when the model's
/// log was overrun, and on reset reconfigures every surviving row whose
/// `ChatLine` changed.
///
/// ## Reading scrollback (unpinned)
///
/// While the list is not pinned to the live edge, appends and removals are
/// deferred instead of applied: at 100+ msg/s the buffer's front-trim would
/// otherwise delete the very rows being read (and force an anchor-restoring
/// layout pass per flush). Edits to rows on screen still apply immediately —
/// a moderation strike, a send failure, or the user's own send being
/// delivered (`.rekeyed`, swapped in place) must show where the user is
/// looking — unless an earlier deferred append / re-key / edit touches the
/// same id (order must hold). A row's own deferred trim doesn't block an
/// in-place edit: the buffer keeps reporting moderation of recently trimmed
/// lines precisely so held rows get struck. A `.reset` applies immediately
/// too: it is wholesale (a block-list change, or a reprime that rebuilt the
/// transcript) and supersedes the backlog — the rows on screen can no longer
/// be trusted, and holding them would keep a just-blocked author visible.
/// It always carries the complete new list, so the reader is never left with
/// an empty one; rows that survive keep their cells, and the controller
/// re-anchors the viewport on the first visible row that does.
/// The backlog is bounded by `maxDeferredChanges`; past it the feed drops it
/// and resets from a snapshot on resume, since a full buffer's worth of churn
/// has replaced every row anyway.
struct ChatListFeed {

    /// Deferred-change bound. Two changes per message at cap (append + trim),
    /// so this is ~500 messages — a full default buffer — of scrollback churn.
    static let defaultMaxDeferredChanges = 1_000

    let maxDeferredChanges: Int

    /// Lines the data source currently shows, keyed by id — the cell
    /// provider's lookup. Rows held back while unpinned keep their values.
    private(set) var linesByID: [String: ChatLine] = [:]

    /// Identifiers the data source currently holds, maintained edit by edit
    /// (replaces rebuilding `Set(snapshot.itemIdentifiers)` on every update).
    private(set) var liveIds: Set<String> = []

    /// Log version consumed through (applied, or deferred while unpinned).
    /// `-1` until the first update, which therefore resets from a snapshot.
    private(set) var consumedVersion = -1

    /// Appends received while unpinned that are not on screen yet — the
    /// jump-to-bottom pill's "N new". Zeroed whenever an update runs pinned.
    private(set) var unreadCount = 0

    /// Structural changes held back while unpinned, in publish order.
    private var deferred: [ChatChange] = []
    /// Ids a deferred append / re-key / in-place edit mentions — a later
    /// in-place edit of one of these must queue behind it rather than jump
    /// ahead.
    private var deferredIds: Set<String> = []
    /// Ids with a deferred removal (mostly front-trims). Deliberately NOT in
    /// `deferredIds`: an in-place edit that arrives after a row's trim (the
    /// buffer still reports moderation of recently trimmed lines) can show
    /// immediately — the row is on screen, and the removal still applies on
    /// resume. Re-keys, which swap identity, do wait behind a removal.
    private var deferredRemovals: Set<String> = []
    /// The backlog was abandoned (overflow, or a log overrun while unpinned);
    /// the next pinned update resets from a snapshot instead of replaying.
    private var resetOnResume = false

    // MARK: Per-edit scratch (valid only inside `update`)

    private var edit = ChatListEdit()
    /// Base-list deletes not yet emitted as a step (batched into one call).
    private var pendingDeletes: [String] = []
    private var pendingDeleteSet: Set<String> = []
    /// Tail appends not yet emitted (always emitted last, in order).
    private var pendingAppends: [String] = []
    private var pendingAppendSet: Set<String> = []
    /// Candidate reconfigures; filtered to live, pre-existing rows at finish.
    private var reconfigure: Set<String> = []
    /// Ids that became live during this edit and were NOT in the data source
    /// before it (they get fresh cells, so they must not be reconfigured).
    private var addedThisEdit: Set<String> = []
    /// Ids that WERE in the data source before this edit and have left it
    /// since. If one comes back within the same edit, diffable keeps its old
    /// cell, so it must be reconfigured.
    private var removedFromBase: Set<String> = []

    init(maxDeferredChanges: Int = ChatListFeed.defaultMaxDeferredChanges) {
        self.maxDeferredChanges = max(1, maxDeferredChanges)
    }

    /// True while changes are held back for scrollback reading.
    var hasDeferredChanges: Bool { !deferred.isEmpty || resetOnResume }

    /// Consumes everything published since the last call and returns the edit
    /// to apply now.
    ///
    /// - Parameters:
    ///   - pinned: the list is tailing the live edge. Pinned updates apply
    ///     everything (first flushing any backlog, in order); unpinned ones
    ///     defer structural changes (see the type doc).
    ///   - reconfigureAll: refresh every row already on screen (row inputs
    ///     outside `ChatLine` — badges, mod status — changed).
    ///   - changes: the model's `changes(since:)`.
    ///   - snapshot: the model's `transcriptSnapshot()` — only called when the
    ///     feed must reset (first update, log overrun, abandoned backlog).
    mutating func update(
        pinned: Bool,
        reconfigureAll: Bool = false,
        changes: (Int) -> ChatChangeLog.Delta,
        snapshot: () -> (version: Int, lines: [ChatLine])
    ) -> ChatListEdit {
        beginEdit()
        if reconfigureAll { reconfigure.formUnion(liveIds) }

        var needsSnapshot = consumedVersion < 0
        if pinned {
            unreadCount = 0
            if resetOnResume {
                needsSnapshot = true
            } else if !deferred.isEmpty {
                // Resume: replay the backlog first so newer changes land on
                // top of it in publish order.
                let backlog = deferred
                clearDeferred()
                for change in backlog { process(change) }
            }
            clearDeferred()
        }

        if !needsSnapshot {
            switch changes(consumedVersion) {
            case .overrun(let head):
                if pinned {
                    needsSnapshot = true
                } else {
                    // Can't replay what was evicted; reset when the user
                    // returns. Keep reading from the head meanwhile (for the
                    // unread count and on-screen edits).
                    clearDeferred()
                    resetOnResume = true
                    consumedVersion = head
                }
            case .changes(let published, let through):
                consumedVersion = through
                if pinned {
                    for change in published { process(change) }
                } else {
                    route(published)
                }
            }
        }

        if needsSnapshot {
            let current = snapshot()
            clearDeferred()
            resetVisible(to: current.lines)
            consumedVersion = current.version
        }
        return finishEdit()
    }

    // MARK: - Unpinned routing

    private mutating func route(_ published: [ChatChange]) {
        for change in published {
            switch change {
            case .reset:
                // Wholesale (block-list change, reprime): show it now; it
                // supersedes whatever was held back. `unreadCount` is kept on
                // purpose: the held appends land below the viewport, still
                // unseen.
                clearDeferred()
                process(change)
            case .reconfigured(let line) where liveIds.contains(line.id) && !deferredIds.contains(line.id):
                // A row on screen changed value in place (moderation strike,
                // send failure), with nothing but possibly its own trim
                // deferred ahead of it — safe, and wanted, to show now.
                process(change)
            case .rekeyed(let from, let line)
                where liveIds.contains(from) && !liveIds.contains(line.id)
                    && !deferredIds.contains(from) && !deferredRemovals.contains(from)
                    && !deferredIds.contains(line.id):
                // The user's own on-screen send was delivered: swap it in
                // place now (same position) instead of leaving it dimmed as
                // "sending" — with stale-id context actions — until re-pin.
                process(change)
            default:
                if case .appended = change { unreadCount += 1 }
                deferChange(change)
            }
        }
    }

    private mutating func deferChange(_ change: ChatChange) {
        // Backlog already abandoned: the resume snapshot covers this change.
        guard !resetOnResume else { return }
        deferred.append(change)
        switch change {
        case .appended(let line), .reconfigured(let line):
            deferredIds.insert(line.id)
        case .removed(let id):
            deferredRemovals.insert(id)
        case .rekeyed(let from, let line):
            deferredIds.insert(from)
            deferredIds.insert(line.id)
        case .reset:
            break
        }
        if deferred.count > maxDeferredChanges {
            clearDeferred()
            resetOnResume = true
        }
    }

    private mutating func clearDeferred() {
        if !deferred.isEmpty { deferred = [] }
        if !deferredIds.isEmpty { deferredIds = [] }
        if !deferredRemovals.isEmpty { deferredRemovals = [] }
        resetOnResume = false
    }

    // MARK: - Edit building

    private mutating func beginEdit() {
        edit = ChatListEdit()
        pendingDeletes = []
        pendingDeleteSet = []
        pendingAppends = []
        pendingAppendSet = []
        reconfigure = []
        addedThisEdit = []
        removedFromBase = []
    }

    private mutating func finishEdit() -> ChatListEdit {
        flushPendingDeletes()
        if !pendingAppends.isEmpty {
            edit.steps.append(.append(pendingAppends))
        }
        var reconfigureIds: [String] = []
        for id in reconfigure where liveIds.contains(id) && !addedThisEdit.contains(id) {
            reconfigureIds.append(id)
        }
        edit.reconfigure = reconfigureIds
        let result = edit
        beginEdit()   // release scratch storage
        return result
    }

    private mutating func flushPendingDeletes() {
        guard !pendingDeletes.isEmpty else { return }
        edit.steps.append(.delete(pendingDeletes))
        pendingDeletes = []
        pendingDeleteSet = []
    }

    /// `id` joins the item list.
    private mutating func enterLive(_ id: String) {
        liveIds.insert(id)
        if removedFromBase.remove(id) != nil {
            // Back in the same apply: diffable sees it in both the old and new
            // snapshot and keeps the old cell — refresh it.
            reconfigure.insert(id)
        } else {
            addedThisEdit.insert(id)
        }
    }

    /// `id` leaves the item list.
    private mutating func leaveLive(_ id: String) {
        liveIds.remove(id)
        if addedThisEdit.remove(id) == nil {
            removedFromBase.insert(id)
        }
    }

    /// Folds one change into the edit under construction. Tolerant by design:
    /// a change that doesn't fit the current item list (append of a present
    /// id, removal of an absent one) degrades to a value refresh or a no-op
    /// rather than an identifier the diffable snapshot would reject.
    private mutating func process(_ change: ChatChange) {
        switch change {
        case .appended(let line):
            let id = line.id
            if liveIds.contains(id) {
                linesByID[id] = line
                reconfigure.insert(id)
                return
            }
            // Re-adding an id whose delete is still pending: emit the delete
            // first so the append never sees a duplicate.
            if pendingDeleteSet.contains(id) { flushPendingDeletes() }
            linesByID[id] = line
            pendingAppends.append(id)
            pendingAppendSet.insert(id)
            enterLive(id)

        case .removed(let id):
            guard liveIds.contains(id) else { return }
            linesByID[id] = nil
            if pendingAppendSet.remove(id) != nil {
                // Appended earlier in this edit — just never append it.
                if let i = pendingAppends.lastIndex(of: id) { pendingAppends.remove(at: i) }
            } else {
                pendingDeletes.append(id)
                pendingDeleteSet.insert(id)
            }
            leaveLive(id)

        case .reconfigured(let line):
            guard liveIds.contains(line.id) else { return }
            linesByID[line.id] = line
            reconfigure.insert(line.id)

        case .rekeyed(let from, let line):
            let to = line.id
            guard liveIds.contains(from) else {
                // Old row isn't shown; refresh the new id if it is.
                if liveIds.contains(to) { process(.reconfigured(line)) }
                return
            }
            if from == to {
                process(.reconfigured(line))
                return
            }
            if liveIds.contains(to) {
                // Never duplicate an identifier: drop the old row and refresh
                // the one already carrying the new id.
                process(.removed(id: from))
                process(.reconfigured(line))
                return
            }
            linesByID[from] = nil
            linesByID[to] = line
            if pendingAppendSet.remove(from) != nil {
                // Not in the data source yet: swap inside the pending run.
                if let i = pendingAppends.firstIndex(of: from) { pendingAppends[i] = to }
                pendingAppendSet.insert(to)
            } else {
                // `to` must be gone before it's inserted.
                if pendingDeleteSet.contains(to) { flushPendingDeletes() }
                edit.steps.append(.replace(from: from, with: to))
            }
            leaveLive(from)
            enterLive(to)

        case .reset(let lines):
            resetVisible(to: lines)
        }
    }

    /// Replaces the item list wholesale with `lines`, reconfiguring every row
    /// that survives from the data source with a changed `ChatLine` — the
    /// part the old reset path lost (it cleared pending reconfigures and
    /// never compared values, so on-screen rows kept stale content).
    private mutating func resetVisible(to lines: [ChatLine]) {
        // Dedupe defensively: a duplicate identifier would make the apply throw.
        var newIds: [String] = []
        newIds.reserveCapacity(lines.count)
        var newByID: [String: ChatLine] = [:]
        newByID.reserveCapacity(lines.count)
        for line in lines where newByID[line.id] == nil {
            newByID[line.id] = line
            newIds.append(line.id)
        }

        var newAdded: Set<String> = []
        for id in newIds {
            let wasInDataSource = (liveIds.contains(id) && !addedThisEdit.contains(id))
                || removedFromBase.contains(id)
            if wasInDataSource {
                // Kept cell — refresh if its value differs from what's shown
                // (or what it was before it left earlier in this edit).
                if removedFromBase.contains(id) || linesByID[id] != newByID[id] {
                    reconfigure.insert(id)
                }
            } else {
                newAdded.insert(id)
            }
        }
        // Pre-edit rows the reset drops: remember them, so a re-add later in
        // this same edit is recognized as a kept cell.
        for id in liveIds where !addedThisEdit.contains(id) && newByID[id] == nil {
            removedFromBase.insert(id)
        }
        for id in newIds { removedFromBase.remove(id) }

        liveIds = Set(newIds)
        addedThisEdit = newAdded
        linesByID = newByID
        edit = ChatListEdit(resetIds: newIds)
        pendingDeletes = []
        pendingDeleteSet = []
        pendingAppends = []
        pendingAppendSet = []
    }
}
