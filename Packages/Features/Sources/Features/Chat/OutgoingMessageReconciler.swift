import Foundation
import ChatModel

/// Bookkeeping for the user's own sends: the optimistic row's lifecycle from
/// `.sending` to delivered (by its EventSub echo, or locally by the stuck-send
/// fallback) or failed.
///
/// A pure, synchronous state machine. It owns only correlation state and
/// never touches rows: callers pass a read-only view of the transcript
/// (`rowState` — a row's delivery state by id, nil when absent) and apply the
/// decision each transition returns. There are no timers or tasks either —
/// the fallback is a deadline on an injectable clock, so every transition is
/// unit-testable without sleeping (`OutgoingMessageReconcilerTests`).
///
/// ## Echo correlation is two-keyed
///
/// The Helix POST response and the EventSub echo race (~50ms apart, either
/// order), so an echo is matched by:
///
///   - **Path 0 — the Helix-returned message id** (primary). Unambiguous:
///     Twitch's id is unique per send. Known only once Helix has responded.
///   - **Path 1 — dedup by id.** A row with the echo's id already exists
///     (Twitch re-sent it on reconnect, or the fallback already settled the
///     send under that id): drop the echo.
///   - **Path 2 — the canonical (trimmed) text of an own message**
///     (fallback). Covers the echo beating the Helix response. Keyed text →
///     a FIFO queue of pending ids, because identical-text double-sends
///     inside the race window would otherwise overwrite each other: echo #N
///     reconciles row #N, in Twitch's broadcast order. Without the queue a
///     second "lol" orphaned the first, the fallback then re-keyed a row to
///     an id already on screen, and the duplicate id crashed the list.
///
/// ## Stuck-send fallback
///
/// When Helix accepts a send but its echo never arrives (the WebSocket
/// dropped between accept and broadcast), the row would sit dimmed forever.
/// `accepted` arms a deadline `fallbackTimeout` later; past it,
/// `nextDueFallback` settles the row locally under the Helix id — so a late
/// echo then dedups against it (Path 1) instead of duplicating it. Any
/// settlement of the send disarms its deadline.
struct OutgoingMessageReconciler {

    /// A row's delivery state by id; nil when the transcript has no such row.
    typealias RowState = (String) -> ChatLine.DeliveryState?

    /// What a live chat message does to the user's pending sends.
    enum EchoMatch: Equatable {
        /// The message is the echo of this pending send: swap its optimistic
        /// row in place for the echo's row.
        case upgrade(pendingId: String)
        /// A row with the message's id already exists — drop the message.
        case duplicate
        /// Not (or no longer) tied to a visible optimistic row — append it
        /// like any other message.
        case unmatched
    }

    /// How to settle a send whose echo is overdue.
    enum FallbackOutcome: Equatable {
        /// Re-key the optimistic row to `messageId` and mark it delivered.
        case settleLocally(pendingId: String, messageId: String)
        /// `messageId` is already on a row (the echo got there by another
        /// path), so re-keying would duplicate it — remove the optimistic row.
        case dropOptimistic(pendingId: String, messageId: String)
    }

    /// How long to wait for the echo after Helix accepts. Long enough for
    /// normal echo latency (median ~150ms, p99 ~1s on busy channels) plus a
    /// transient WebSocket re-handshake; short enough that the user sees the
    /// message land before giving up and retrying.
    static let defaultFallbackTimeout: Duration = .seconds(5)

    let fallbackTimeout: Duration
    private let now: () -> ContinuousClock.Instant
    private let makePendingId: () -> String

    /// Path 0: pending id → Helix message id. Filled once Helix accepts.
    private var helixMessageIdByPendingId: [String: String] = [:]

    /// Path 2: canonical text → pending ids, oldest first. Filled at `begin`.
    private var pendingIdsByText: [String: [String]] = [:]

    /// Armed stuck-send deadlines, by pending id.
    private var fallbacks: [String: Fallback] = [:]

    private struct Fallback {
        let messageId: String
        let deadline: ContinuousClock.Instant
    }

    /// Rows the fallback settled locally: `.delivered` under their server id,
    /// yet absent from the session's ring because the echo never came. A
    /// transcript rebuild must carry them across like any other local row
    /// (see `isLocalOnly`).
    private(set) var locallySettledIds: Set<String> = []

    /// - Parameters:
    ///   - now: the clock deadlines are measured on. Production reads the
    ///     continuous clock (the one `Task.sleep(until:)` waits on); tests
    ///     inject a manual one.
    ///   - makePendingId: mints optimistic-row ids. The `pending-` prefix
    ///     can't collide with Twitch's un-prefixed UUID message ids.
    init(
        fallbackTimeout: Duration = OutgoingMessageReconciler.defaultFallbackTimeout,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
        makePendingId: @escaping () -> String = { "pending-\(UUID().uuidString)" }
    ) {
        self.fallbackTimeout = fallbackTimeout
        self.now = now
        self.makePendingId = makePendingId
    }

    // MARK: - Send lifecycle

    /// Starts tracking a send of `text` — already canonical, i.e. trimmed the
    /// way `ChannelSession.send` trims, or the Path 2 match would miss.
    /// Returns the id for its optimistic row.
    mutating func begin(text: String) -> String {
        let pendingId = makePendingId()
        pendingIdsByText[text, default: []].append(pendingId)
        return pendingId
    }

    /// Helix accepted the send as `messageId`. If its optimistic row is still
    /// in the transcript, the id becomes the Path 0 key and the stuck-send
    /// deadline is armed; returns true so the caller can schedule a wake-up.
    ///
    /// If the row is gone, the echo already reconciled it by text during the
    /// request (or a chat clear / rebuild removed it), so a mapping written
    /// now would be a dead letter — the send is settled instead.
    @discardableResult
    mutating func accepted(pendingId: String, messageId: String, rowState: RowState) -> Bool {
        guard rowState(pendingId) != nil else {
            settle(pendingId)
            return false
        }
        helixMessageIdByPendingId[pendingId] = messageId
        fallbacks[pendingId] = Fallback(
            messageId: messageId,
            deadline: now().advanced(by: fallbackTimeout)
        )
        return true
    }

    /// The send failed (Twitch dropped it, or the request threw). Stops
    /// correlating it; the caller marks its row `.failed`.
    mutating func failed(pendingId: String) {
        settle(pendingId)
    }

    /// Decides what a live chat message does to the pending sends (Paths 0,
    /// 1, 2 in order — see the type docs). Settles whichever send it
    /// matches, even when that send's row is gone: the message then falls
    /// through to the next path — ultimately a plain append, because Twitch
    /// saw the message and the user deserves to see it.
    ///
    /// - Parameter isOwn: whether the signed-in user wrote the message; only
    ///   own messages may match by text.
    mutating func matchEcho(
        messageId: String,
        text: String,
        isOwn: Bool,
        rowState: RowState
    ) -> EchoMatch {
        if let pendingId = sendAcceptedAs(helixMessageId: messageId) {
            settle(pendingId)
            if rowState(pendingId) != nil { return .upgrade(pendingId: pendingId) }
        }
        if rowState(messageId) != nil { return .duplicate }
        // Trim only on the own-message path: `trimmingCharacters` allocates,
        // and only the user's own (rare) echoes can match by text.
        if isOwn, let pendingId = oldestPendingId(forText: text) {
            settle(pendingId)
            if rowState(pendingId) != nil { return .upgrade(pendingId: pendingId) }
        }
        return .unmatched
    }

    /// For an own echo found in a rebuild snapshot — whose row the snapshot
    /// already holds — settles the pending send it answers (Path 0, else
    /// Path 2) and returns its id, so the caller drops that optimistic row
    /// instead of re-appending it as a duplicate. Doesn't consult rows.
    mutating func settlePending(answeredBy messageId: String, text: String, isOwn: Bool) -> String? {
        let pendingId = sendAcceptedAs(helixMessageId: messageId)
            ?? (isOwn ? oldestPendingId(forText: text) : nil)
        if let pendingId { settle(pendingId) }
        return pendingId
    }

    // MARK: - Stuck-send fallback

    /// The earliest armed deadline — when the caller should next call
    /// `nextDueFallback`. Nil when nothing is armed.
    var nextFallbackDeadline: ContinuousClock.Instant? {
        fallbacks.values.map(\.deadline).min()
    }

    /// Pops the most overdue armed send and says how to settle its row; nil
    /// once nothing (more) is due. Call it in a loop, applying each outcome
    /// before the next call so `rowState` reflects the previous one.
    ///
    /// A due send whose row is no longer `.sending` (its echo raced the
    /// deadline, or the row left the transcript) is just disarmed.
    mutating func nextDueFallback(rowState: RowState) -> FallbackOutcome? {
        let currentTime = now()
        while let due = mostOverdueFallback(at: currentTime) {
            fallbacks[due.pendingId] = nil
            guard rowState(due.pendingId) == .sending else { continue }
            settle(due.pendingId)
            if rowState(due.messageId) != nil {
                return .dropOptimistic(pendingId: due.pendingId, messageId: due.messageId)
            }
            locallySettledIds.insert(due.messageId)
            return .settleLocally(pendingId: due.pendingId, messageId: due.messageId)
        }
        return nil
    }

    /// Disarms every deadline (the transcript detached). Correlation keys are
    /// kept: an echo or a Helix response can still land.
    mutating func cancelFallbacks() {
        fallbacks.removeAll()
    }

    // MARK: - Local rows across a rebuild

    /// Whether `line` exists only in this transcript, not in the session's
    /// ring: a send still in flight or failed, or one the fallback settled.
    func isLocalOnly(_ line: ChatLine) -> Bool {
        line.deliveryState != .delivered || locallySettledIds.contains(line.id)
    }

    /// Forgets every locally settled row (the transcript is re-priming).
    mutating func forgetLocallySettled() {
        locallySettledIds.removeAll()
    }

    /// Keeps only the locally settled ids the transcript still holds.
    mutating func pruneLocallySettled(keeping isPresent: (String) -> Bool) {
        locallySettledIds = locallySettledIds.filter(isPresent)
    }

    /// Whether `pendingId` still has any correlation state or deadline.
    func isTracking(_ pendingId: String) -> Bool {
        helixMessageIdByPendingId[pendingId] != nil
            || fallbacks[pendingId] != nil
            || pendingIdsByText.values.contains { $0.contains(pendingId) }
    }

    // MARK: - Internals

    private func sendAcceptedAs(helixMessageId messageId: String) -> String? {
        guard !helixMessageIdByPendingId.isEmpty else { return nil }
        return helixMessageIdByPendingId.first { $0.value == messageId }?.key
    }

    private func oldestPendingId(forText text: String) -> String? {
        pendingIdsByText[text.trimmingCharacters(in: .whitespacesAndNewlines)]?.first
    }

    private func mostOverdueFallback(
        at time: ContinuousClock.Instant
    ) -> (pendingId: String, messageId: String)? {
        var best: (pendingId: String, fallback: Fallback)?
        for (pendingId, fallback) in fallbacks where fallback.deadline <= time {
            if let current = best, current.fallback.deadline <= fallback.deadline { continue }
            best = (pendingId: pendingId, fallback: fallback)
        }
        return best.map { (pendingId: $0.pendingId, messageId: $0.fallback.messageId) }
    }

    /// The send reached a terminal state: drop every key and deadline that
    /// still points at it. O(pending sends) — typically 0–1.
    private mutating func settle(_ pendingId: String) {
        helixMessageIdByPendingId.removeValue(forKey: pendingId)
        if let text = pendingIdsByText.first(where: { $0.value.contains(pendingId) })?.key {
            pendingIdsByText[text]?.removeAll { $0 == pendingId }
            if pendingIdsByText[text]?.isEmpty == true {
                pendingIdsByText.removeValue(forKey: text)
            }
        }
        fallbacks.removeValue(forKey: pendingId)
    }
}
