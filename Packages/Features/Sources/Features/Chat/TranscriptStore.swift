import Observation
import ChatModel
import Channels

/// A transcript's rows and the channel that publishes their changes: the
/// sliding-window `ChatBuffer` (dedup/echo source of truth plus the
/// block-filtered projection the view renders), the versioned `ChatChangeLog`
/// views replay, and the coalesced flush between them.
///
/// ## Coalesced change channel
///
/// Instead of re-publishing the whole `lines` array every message and making
/// the view re-diff it, the store publishes typed `[ChatChange]` batches the
/// view applies directly:
///
///   1. Callers mutate (any number of times in one main-actor turn), then
///      call `publishPending()`. The first call after a flush schedules a
///      single flush `coalescingWindow` later; the rest inside the window
///      just accumulate in the buffer.
///   2. The flush seals everything pending into `changeLog` as ONE versioned
///      batch and sets `changeVersion` (the only observed trigger) to the
///      log head. A 100 msg/s firehose costs ~one publish per frame, not one
///      per message.
///   3. Readers never assume they saw every publish (SwiftUI coalesces
///      invalidations). Each keeps the last version it consumed and pulls
///      `changes(since:)`, which replays EVERY batch after it; only a reader
///      whose next batch was evicted from the bounded log resets from
///      `snapshot()`.
///
/// Reader pulls seal pending changes too (touching only ignored state), so a
/// snapshot's lines always correspond exactly to its version.
///
/// Only `changeVersion` (moves at most once per flush) and `isEmpty` (flips
/// only) are observed. The buffer and log are mutated on EVERY inbound
/// message, so observing them would invalidate any body that ever read
/// through them at message rate.
@MainActor
@Observable
final class TranscriptStore {

    /// How long the first mutation after a flush waits before publishing —
    /// about one 60 Hz frame. Mutations inside the window ride along.
    static let coalescingWindow: Duration = .milliseconds(15)

    /// The window used while traffic is sustained (the previous flush was
    /// less than `busyThreshold` ago). Every flush costs a SwiftUI update of
    /// the transcript, a diffable snapshot copy + apply over the whole
    /// retained list, and a forced layout of the new self-sizing hosted
    /// cells — a fixed per-flush cost that dominated main-thread time in big
    /// channels when it ran every frame. ~20 publishes/s under load is still
    /// faster than anyone reads, and a quiet channel (or the first message
    /// after a lull) keeps the one-frame latency. Own sends never wait on
    /// this: the re-pin pulls `changes(since:)`, which seals immediately.
    static let busyCoalescingWindow: Duration = .milliseconds(50)

    /// A flush closer than this to the previous one marks the stream busy.
    static let busyThreshold: Duration = .milliseconds(120)

    /// When the last scheduled flush ran — picks the next window.
    @ObservationIgnored private var lastFlushAt: ContinuousClock.Instant?

    /// Cap = 500 retained lines by default; `resize(toCap:)` applies the
    /// Chat History setting at attach.
    @ObservationIgnored private var buffer = ChatBuffer(cap: 500)

    /// Published batches by version. Readers pull from it inside their own
    /// update, which must not invalidate anything.
    @ObservationIgnored private var changeLog = ChatChangeLog()

    /// True while a flush is scheduled — collapses every mutation inside the
    /// coalescing window onto that one flush.
    @ObservationIgnored private var flushScheduled = false

    /// True when there are no *visible* (block-filtered) lines — drives the
    /// transcript's empty state. Stored rather than derived so observers are
    /// invalidated only when it actually flips; kept current synchronously by
    /// `publishPending()`, so the list mounts the moment the first line lands
    /// rather than a flush later.
    private(set) var isEmpty = true

    /// Log head as of the last flush. Moves at most once per flush; readers
    /// treat a move as "pull `changes(since:)`", never as "exactly one batch
    /// happened".
    private(set) var changeVersion = 0

    // MARK: - Reading

    /// Block-filtered, display-ready lines — the live buffer state, which can
    /// run up to one coalescing window ahead of the last flush. Registers a
    /// dependency on `changeVersion`, so a body that renders it directly
    /// re-evaluates once per flush.
    var lines: [ChatLine] {
        _ = changeVersion
        return buffer.lines
    }

    /// The same lines without the observation dependency — for the model's
    /// own bookkeeping, outside any body.
    var currentLines: [ChatLine] { buffer.lines }

    /// The most recently appended line (unfiltered).
    var last: ChatLine? { buffer.last }

    /// Blocked user ids. Changing the set re-filters the visible projection
    /// immediately; the no-op-when-unchanged guard lives in `ChatBuffer`.
    var blockedIds: Set<String> {
        get { buffer.blockedIds }
        set {
            buffer.blockedIds = newValue
            publishPending()
        }
    }

    func contains(id: String) -> Bool { buffer.contains(id: id) }

    func line(id: String) -> ChatLine? { buffer.line(id: id) }

    /// A row's delivery state, or nil when no row has that id — the lookup
    /// `OutgoingMessageReconciler` decides against.
    func deliveryState(ofRow id: String) -> ChatLine.DeliveryState? {
        buffer.deliveryState(of: id)
    }

    /// How many lines the transcript retains (the Chat History setting) —
    /// the most "new messages" a jump to the live edge can reveal.
    var lineCap: Int { buffer.cap }

    /// Non-observed counts for diagnostics (avoids materializing `lines` or
    /// subscribing a view body).
    var visibleLineCount: Int { buffer.visibleCount }
    var unfilteredLineCount: Int { buffer.count }
    var blockedUserCount: Int { buffer.blockedIds.count }

    /// Every line of the thread rooted at `rootMessageId` — the root plus any
    /// reply naming it as root, in order. O(lines): computed on demand
    /// (threads are rare), and `ThreadView` only calls it on open and when a
    /// published batch actually touches the thread.
    func lines(inThreadRootedAt rootMessageId: String) -> [ChatLine] {
        lines.filter { line in
            line.id == rootMessageId
                || line.replyParent?.threadRootMessageId == rootMessageId
        }
    }

    // MARK: - Mutating

    /// Applies the Chat History setting. Rebuilds (rather than resets) only
    /// when the cap changed, carrying the block set over — the view pushes
    /// `blockedIds` on its own schedule and may already have done so.
    func resize(toCap lineCap: Int) {
        guard buffer.cap != lineCap else { return }
        let blocked = buffer.blockedIds
        buffer = ChatBuffer(cap: max(1, lineCap))
        buffer.blockedIds = blocked
    }

    func append(_ line: ChatLine) {
        buffer.append(line)
    }

    /// Replaces the row with `id` by value; false (a no-op) when absent.
    @discardableResult
    func replace(id: String, with line: ChatLine) -> Bool {
        buffer.replace(id: id, with: line)
    }

    /// Removes the row with `id`; false when absent.
    @discardableResult
    func remove(id: String) -> Bool {
        buffer.remove(id: id)
    }

    /// Applies one session update to the rows, as `policy` presents them.
    /// The one dispatch shared by live ingestion and every replay (attach
    /// priming, reprime), so initial state and live state can't drift. Rows
    /// arrive normalized by the session; nothing is tokenized here.
    func ingest(_ update: ChannelUpdate, policy: ChatViewerPolicy) {
        Self.ingest(update, into: &buffer, policy: policy)
    }

    /// Appends a live message the caller has already checked against
    /// `policy.hides` (it filters before echo reconciliation), so the filter
    /// runs once per message. Returns whether the row, as this viewer sees
    /// it, is highlighted.
    @discardableResult
    func appendLiveMessage(_ normalized: NormalizedMessage, policy: ChatViewerPolicy) -> Bool {
        let line = policy.presenting(normalized.line)
        buffer.append(line)
        return line.isHighlighted
    }

    /// `ingest` against an explicit buffer, so `replay` can run it inside
    /// the buffer's own rebuild.
    private static func ingest(
        _ update: ChannelUpdate,
        into buffer: inout ChatBuffer,
        policy: ChatViewerPolicy
    ) {
        switch update {
        case .message(let normalized):
            // The live path filters before echo reconciliation; this check
            // covers the replays, which would otherwise resurrect messages
            // the live path dropped.
            if policy.hides(normalized.message) { return }
            buffer.append(policy.presenting(normalized.line))

        case .row(let line):
            // Bubbles and the "New" divider, built once by the session with
            // stable ids — a replay yields the same identity.
            buffer.append(line)

        case .messageDeleted(let targetMessageId):
            // Flip in place rather than remove — a vanishing line is
            // disorienting mid-scroll, and the struck-through placeholder is
            // the Twitch web convention. No-op once it aged out entirely.
            buffer.mutate(id: targetMessageId) { $0.markingDeleted() }

        case .chatCleared:
            // Retroactively strikes the scrollback; later messages arrive
            // normally.
            buffer.mutateAll { $0.markingDeleted() }

        case .messagesClearedFromUser(let targetUserId):
            // A timeout / ban strikes everything the user wrote.
            buffer.mutateMatching(authorUserId: targetUserId) { $0.markingDeleted() }

        case .restrictionsUpdated, .moderationStatusChanged:
            // State-only updates — handled by the model before ingest, and
            // never re-applied from a replayed ring (attach re-derives both
            // from fresher sources).
            break

        case .reprime:
            // Never part of a ring snapshot; handled by the model.
            break
        }
    }

    /// Rebuilds the rows from scratch by replaying `updates` through `ingest`,
    /// then re-appending at the tail each of `localRows` (rows only this
    /// transcript holds) the replay didn't already produce. Returns how many
    /// of those it re-appended.
    ///
    /// Views receive the whole rebuild as ONE wholesale change (see
    /// `ChatBuffer.replaceAll`), local rows included — never an emptied list
    /// that refills row by row.
    @discardableResult
    func replay(
        _ updates: [ChannelUpdate],
        policy: ChatViewerPolicy,
        keeping localRows: [ChatLine] = []
    ) -> Int {
        var kept = 0
        buffer.replaceAll { rebuilt in
            for update in updates {
                Self.ingest(update, into: &rebuilt, policy: policy)
            }
            for row in localRows where !rebuilt.contains(id: row.id) {
                rebuilt.append(row)
                kept += 1
            }
        }
        return kept
    }

    // MARK: - Publishing

    /// Call after mutating: refreshes `isEmpty` and schedules the coalesced
    /// flush. Cheap — beyond the O(1) empty check it does nothing while a
    /// flush is already pending. Because the buffer *accumulates* until a
    /// flush or a reader pull seals it, nothing is lost between calls.
    func publishPending() {
        let empty = buffer.visibleCount == 0
        if empty != isEmpty { isEmpty = empty }
        guard !flushScheduled else { return }
        flushScheduled = true
        let window: Duration
        if let lastFlushAt, ContinuousClock.now - lastFlushAt < Self.busyThreshold {
            window = Self.busyCoalescingWindow
        } else {
            window = Self.coalescingWindow
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: window)
            self?.flushPendingChanges()
        }
    }

    /// Seals pending buffer changes into the log and publishes the new head.
    /// Normally run by the task `publishPending()` schedules; tests call it
    /// to flush deterministically instead of sleeping.
    func flushPendingChanges() {
        flushScheduled = false
        lastFlushAt = ContinuousClock.now
        let head = sealPendingChanges()
        if changeVersion != head { changeVersion = head }
    }

    /// Every change published after `version`, flattened in order, or
    /// `.overrun` when `version` predates the retained log (the reader must
    /// reset from `snapshot()`). Seals pending changes first, so the reader
    /// is never behind the buffer. Observation-free: safe to call from
    /// `updateUIViewController`, `onChange`, or a scroll callback.
    func changes(since version: Int) -> ChatChangeLog.Delta {
        sealPendingChanges()
        return changeLog.changes(since: version)
    }

    /// The visible lines plus the exact log version they reflect. A reader
    /// that resets from this and then pulls `changes(since: version)` sees
    /// every later change exactly once. O(visible) — reset path only.
    func snapshot() -> (version: Int, lines: [ChatLine]) {
        let version = sealPendingChanges()
        return (version, buffer.lines)
    }

    /// `snapshot()` for one thread — the thread sheet's seed.
    func threadSnapshot(rootedAt rootMessageId: String) -> (version: Int, lines: [ChatLine]) {
        let version = sealPendingChanges()
        return (version, lines(inThreadRootedAt: rootMessageId))
    }

    /// Moves the buffer's undrained changes into the log as one batch and
    /// returns the log head; afterwards `buffer.lines` is exactly the state
    /// at that version. Touches only observation-ignored state, so readers
    /// may call it from inside a view update.
    @discardableResult
    private func sealPendingChanges() -> Int {
        let changes = buffer.takeChanges()
        if !changes.isEmpty { changeLog.append(changes) }
        return changeLog.headVersion
    }
}
