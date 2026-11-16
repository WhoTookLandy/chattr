import TwitchKit
import ChatModel
import Core
import os

private let logger = AppLogger.make("Features.OutgoingMessages")

/// The user's own sends as they play out in one transcript:
/// `OutgoingMessageReconciler`'s decisions applied to the `TranscriptStore`,
/// plus the one task that wakes at the stuck-send deadline.
///
/// The reconciler stays a pure state machine; this is the thin main-actor
/// glue around it — it owns the clock-driven wake-up and turns each decision
/// into the matching row edit. Callers still own *when* to publish batches
/// that span several edits (a drained batch, a reprime); each step that
/// stands alone (begin, fail, fallback) publishes itself.
@MainActor
final class OutgoingMessages {

    private let store: TranscriptStore
    private var reconciler: OutgoingMessageReconciler

    /// Sleeps until the earliest armed stuck-send deadline.
    private var fallbackWake: Task<Void, Never>?

    init(store: TranscriptStore, reconciler: OutgoingMessageReconciler = OutgoingMessageReconciler()) {
        self.store = store
        self.reconciler = reconciler
    }

    // MARK: - Send lifecycle

    /// Starts a send of `text` (already canonical — trimmed as the session
    /// trims) and shows its optimistic row, built by `makeRow` from the
    /// minted pending id. Returns that id.
    func begin(text: String, makeRow: (String) -> ChatLine) -> String {
        let pendingId = reconciler.begin(text: text)
        store.append(makeRow(pendingId))
        store.publishPending()
        return pendingId
    }

    /// Helix accepted the send: Helix's id becomes the primary echo key and
    /// the stuck-send deadline is armed (unless the echo already settled it).
    func accepted(pendingId: String, messageId: String) {
        let armed = reconciler.accepted(
            pendingId: pendingId,
            messageId: messageId,
            rowState: { store.deliveryState(ofRow: $0) }
        )
        if armed { scheduleFallbackWake() }
    }

    /// The send was dropped or threw: its row turns `.failed` in place, with
    /// the reason and the text Retry re-sends. A row that's already gone
    /// (aged out, or settled by a rebuild) isn't resurrected.
    func failed(pendingId: String, reason: String, retryText: String) {
        reconciler.failed(pendingId: pendingId)
        guard let row = store.line(id: pendingId) else { return }
        store.replace(id: pendingId, with: row.with(deliveryState: .failed(reason: reason, retryText: retryText)))
        store.publishPending()
    }

    /// Reconciles a live chat message against the pending sends. Returns
    /// true when it was consumed — an echo whose session row (`upgradedRow`,
    /// built only when needed) took its optimistic row's slot, or a
    /// duplicate dropped. False: the caller appends it like any message.
    func reconcileEcho(of message: ChatMessage, isOwn: Bool, upgradedRow: () -> ChatLine) -> Bool {
        let match = reconciler.matchEcho(
            messageId: message.messageId,
            text: message.message.text,
            isOwn: isOwn,
            rowState: { store.deliveryState(ofRow: $0) }
        )
        switch match {
        case .upgrade(let pendingId):
            // The session's row — the same row its ring holds, so a later
            // reprime replays it identically.
            store.replace(id: pendingId, with: upgradedRow())
            return true
        case .duplicate:
            return true
        case .unmatched:
            return false
        }
    }

    // MARK: - Rebuild support (see `ChatTranscriptModel.reprime`)

    /// Whether `line` exists only in this transcript (in flight, failed, or
    /// settled locally) and must survive a rebuild from the session's ring.
    func isLocalOnly(_ line: ChatLine) -> Bool {
        reconciler.isLocalOnly(line)
    }

    /// Settles the send an own echo found in a rebuild snapshot answers;
    /// returns its pending id so the caller drops that optimistic row.
    func settlePending(answeredBy message: ChatMessage) -> String? {
        reconciler.settlePending(
            answeredBy: message.messageId,
            text: message.message.text,
            isOwn: true
        )
    }

    func forgetLocallySettled() {
        reconciler.forgetLocallySettled()
    }

    /// Drops locally settled ids the transcript no longer holds.
    func pruneLocallySettled() {
        reconciler.pruneLocallySettled { store.contains(id: $0) }
    }

    // MARK: - Stuck-send fallback

    /// Disarms every deadline and the wake (detach). Correlation keys stay —
    /// a late echo or Helix response can still land.
    func cancelFallbacks() {
        fallbackWake?.cancel()
        fallbackWake = nil
        reconciler.cancelFallbacks()
    }

    /// One task covers every armed send: it sleeps until the earliest
    /// deadline, settles whatever is overdue, and re-arms for the next.
    private func scheduleFallbackWake() {
        fallbackWake?.cancel()
        guard let deadline = reconciler.nextFallbackDeadline else {
            fallbackWake = nil
            return
        }
        fallbackWake = Task { @MainActor [weak self] in
            // `try?`: a re-arm or detach cancels the sleep; the check below
            // then bails.
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.settleOverdueSends()
        }
    }

    /// Each overdue row settles as `.delivered` under its Helix id (so a late
    /// echo dedups against it) — or, if that id is already on a row, the
    /// optimistic copy is dropped instead of duplicating it.
    private func settleOverdueSends() {
        fallbackWake = nil
        while let outcome = reconciler.nextDueFallback(rowState: { store.deliveryState(ofRow: $0) }) {
            switch outcome {
            case .settleLocally(let pendingId, let messageId):
                logger.warning("Echo never arrived for messageId=\(messageId, privacy: .public); settling the optimistic row locally")
                if let row = store.line(id: pendingId) {
                    store.replace(id: pendingId, with: row.with(deliveryState: .delivered, id: messageId))
                }
            case .dropOptimistic(let pendingId, let messageId):
                logger.warning("Settling would duplicate id \(messageId, privacy: .public); removing the optimistic row only")
                store.remove(id: pendingId)
            }
            store.publishPending()
        }
        scheduleFallbackWake()
    }
}
