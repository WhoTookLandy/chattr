/// The chat list's tailing rules: whether the transcript is glued to the
/// newest message, and what each scroll, lifecycle and update event means
/// for it. Pure value type — `ChatListViewController` owns one, reports
/// events to it, and performs the `Effects` it answers with; tests drive it
/// directly (the controller is iOS-only).
///
/// Geometry stays in the controller. Where a rule depends on it (is the
/// offset near the bottom, is a finger on the list, has the view loaded) the
/// controller reads the fact from UIKit and passes it in with the event. The
/// controller also keeps the work itself: applying snapshots, setting
/// offsets, and the two timers behind `Effects.Refresh.later` and
/// `UnreadReport.after`.
struct ChatListTailing {

    /// What the controller does after an event, in this order: cancel the
    /// scheduled refresh, refresh, pin.
    struct Effects: Equatable {
        enum Refresh: Equatable {
            /// Pull everything new from the model and apply it now.
            /// `reconfigureAll` also refreshes every row already listed, in
            /// the same apply.
            case now(reconfigureAll: Bool)
            /// One coalesced refresh an off-screen interval from now. Asked
            /// for again inside the interval, it rides along with the one
            /// already scheduled.
            case later
        }

        /// Drop the scheduled off-screen refresh, if there is one.
        var cancelsScheduledRefresh = false
        /// Nil: no refresh. An event that changes nothing answers `Effects()`.
        var refresh: Refresh? = nil
        /// Re-assert the bottom-pinned offset.
        var pinsToBottom = false
    }

    /// What to tell SwiftUI about the held-back message count.
    enum UnreadReport: Equatable {
        /// Push this count now (dropping any trailing push still pending).
        case now(Int)
        /// Push the then-current count once this much time has passed,
        /// unless a trailing push is already pending.
        case after(Duration)
    }

    // MARK: - State

    /// True while the transcript is "tailing" — glued to the newest message.
    ///
    /// While pinned, every collection-view layout pass re-asserts the
    /// bottom-pinned content offset (see
    /// `ChatListViewController.pinToBottomIfNeeded`). This replaces the old
    /// one-shot `scrollToItem(at:.bottom)`: with `.estimated(44)`
    /// self-sizing rows, a one-shot scroll computes its destination from
    /// estimated attributes and lands wrong whenever real heights differ —
    /// the per-pass re-pin absorbs each estimate→actual correction before
    /// it's ever drawn (the "bounce" on new messages, and the pill jump
    /// landing short of the bottom).
    ///
    /// Cleared the moment the user starts dragging; restored when a drag or
    /// deceleration ends near the bottom, or when a re-pin is requested (the
    /// jump-to-bottom pill, or an own send). Starts true — chat opens tailing.
    ///
    /// Also gates data flow: while unpinned, appends / trims / re-keys are
    /// held back by `ChatListFeed` so the rows being read can't be trimmed
    /// out from under the reader; re-pinning flushes them in one apply.
    private(set) var isPinnedToBottom = true

    /// A re-pin requested while the user's finger was dragging the list
    /// (e.g. a hardware-keyboard send mid-scroll). Applied when the drag
    /// ends: pinning now would make every layout pass yank the offset out
    /// from under the finger.
    private(set) var repinAfterDrag = false

    /// True while the app is in the background — typically the stream
    /// playing on in Picture in Picture. Nothing here is visible then, yet
    /// every model flush would still apply a snapshot and force-lay-out
    /// self-sizing SwiftUI cells at message rate, competing with the video
    /// for the CPU (and the battery). While suspended, updates only record
    /// what they'd need; the model's change log keeps every change, and
    /// returning to the foreground catches up in one apply (or one reset,
    /// if the log no longer reaches back that far).
    private(set) var isSuspended = false

    /// A row-inputs change that arrived while suspended — applied as a
    /// reconfigure-all on resume.
    private(set) var pendingReconfigureAll = false

    /// False while the list is a mounted pager neighbour rather than the
    /// visible page — see `ChatListViewController.isVisible`.
    private(set) var isVisible = true

    /// Last-seen scroll-to-bottom token — the jump pill and own sends
    /// increment the value to request a re-pin; we act only when it changes.
    private var lastScrollToBottomToken = 0

    /// Last row inputs (badges loaded, can moderate) — an update
    /// reconfigures every row when they change. Nil before the first update.
    private var rowInputs: ChatRowInputs?

    /// Last `isAtBottom` value pushed to SwiftUI — reported on a flip only,
    /// never per scroll frame (matches the old onScrollGeometryChange).
    private var lastReportedAtBottom = true

    /// Last unread count pushed to SwiftUI — report on change only.
    private var lastReportedUnread = 0

    /// When the unread count was last pushed.
    private var lastUnreadReportAt: ContinuousClock.Instant?

    /// A growing unread count reaches SwiftUI at most this often. Each push
    /// writes `ChatTranscript`'s state and re-renders the jump pill; in a
    /// busy channel the count changes with every flush, far faster than
    /// "N new" needs to tick.
    static let unreadReportInterval: Duration = .milliseconds(500)

    // MARK: - Scrolling

    /// A finger on the transcript always wins over tailing — unpin
    /// immediately so a layout pass mid-drag can't yank the offset back
    /// to the bottom while the user is reading scrollback.
    mutating func dragBegan() {
        isPinnedToBottom = false
    }

    /// Drag released. A re-pin requested mid-drag (see `repinAfterDrag`)
    /// applies now, momentum or not; otherwise resume tailing if the drag
    /// ended near the bottom without momentum (within the same 44pt the pill
    /// logic uses).
    mutating func dragEnded(willDecelerate: Bool, isNearBottom: Bool) -> Effects {
        if repinAfterDrag {
            repinAfterDrag = false
            return resumeTailing()
        } else if !willDecelerate, isNearBottom {
            return resumeTailing()
        }
        return Effects()
    }

    /// Momentum settled — same near-bottom check as the direct release.
    mutating func decelerationEnded(isNearBottom: Bool) -> Effects {
        guard isNearBottom else { return Effects() }
        return resumeTailing()
    }

    /// Back to the live edge: flush everything held back while reading right
    /// now — the next model publish may be a while away on a quiet channel —
    /// then glue the offset to the (new) bottom, which also snaps the
    /// remaining ≤44pt so "near the bottom" and "tailing" can't drift apart.
    private mutating func resumeTailing() -> Effects {
        isPinnedToBottom = true
        return Effects(refresh: .now(reconfigureAll: false), pinsToBottom: true)
    }

    /// The scroll position moved. Returns the new `isAtBottom` when it
    /// flipped, nil when there is nothing to report.
    mutating func scrolled(isNearBottom: Bool) -> Bool? {
        guard isNearBottom != lastReportedAtBottom else { return nil }
        lastReportedAtBottom = isNearBottom
        return isNearBottom
    }

    // MARK: - Updates

    /// A SwiftUI update: a model flush, new row inputs, or a re-pin request
    /// (`scrollToBottomToken` moved). `isDragging`: a finger is on the list.
    mutating func update(
        rowInputs: ChatRowInputs,
        scrollToBottomToken: Int,
        isDragging: Bool
    ) -> Effects {
        // Row inputs changed (badges finished loading, mod status flipped):
        // reconfigure every row already in the list, in the same apply as
        // whatever data arrived. Not on the first update — every row is
        // fresh then.
        let isFirstUpdate = self.rowInputs == nil
        let inputsChanged = !isFirstUpdate && self.rowInputs != rowInputs
        self.rowInputs = rowInputs

        var jumpRequested = scrollToBottomToken != lastScrollToBottomToken
        if jumpRequested {
            lastScrollToBottomToken = scrollToBottomToken
            if isDragging {
                // A finger is on the list: honour the request when it lifts
                // (see `repinAfterDrag`).
                repinAfterDrag = true
                jumpRequested = false
            } else {
                // Re-pin request (jump pill, own send): re-enter tailing
                // BEFORE pulling, so the backlog held back while reading
                // flushes in this same apply. The controller's per-pass pin
                // (and the explicit one after its apply) glue the offset to
                // the live edge from here — same mechanism as
                // `resumeTailing`.
                isPinnedToBottom = true
            }
        }
        // Backgrounded (see `isSuspended`): the row inputs and any re-pin
        // request are recorded above; the data waits for the resume.
        if isSuspended {
            if inputsChanged { pendingReconfigureAll = true }
            return Effects()
        }
        // Off-screen pager neighbour (see `isVisible`): coalesce plain data
        // updates. The first update (priming the list, so the page is ready
        // before it's swiped in) and the rare row-input / re-pin changes
        // still apply at once.
        if !isVisible, !isFirstUpdate, !inputsChanged, !jumpRequested {
            return Effects(refresh: .later)
        }
        return Effects(
            cancelsScheduledRefresh: true,
            refresh: .now(reconfigureAll: inputsChanged),
            pinsToBottom: jumpRequested
        )
    }

    /// The scheduled off-screen refresh came due.
    func scheduledRefreshFired() -> Effects {
        guard !isSuspended else { return Effects() }
        return Effects(refresh: .now(reconfigureAll: false))
    }

    /// Whether to force the layout and pin right after a pinned apply.
    ///
    /// Not for an off-screen neighbour's incremental edits: nobody sees the
    /// page, so nothing needs its geometry settled inside that call.
    /// Whenever UIKit next lays the list out on its own, the per-pass pin
    /// catches it, and becoming visible refreshes and pins again. A reset
    /// (the mount that readies the page for a swipe, and feeds the row-height
    /// estimate) still lays out at once.
    func settlesLayoutAfterApply(isReset: Bool) -> Bool {
        isVisible || isReset
    }

    // MARK: - Visibility and app lifecycle

    /// The page became the visible one, or stopped being it. Becoming
    /// visible catches up immediately. `isViewLoaded`: before the view has
    /// loaded there is nothing to catch up — the first update primes it.
    mutating func setVisible(_ visible: Bool, isViewLoaded: Bool) -> Effects {
        let changed = visible != isVisible
        isVisible = visible
        guard isViewLoaded, changed, visible else { return Effects() }
        var effects = Effects(cancelsScheduledRefresh: true)
        guard !isSuspended else { return effects }
        effects.refresh = .now(reconfigureAll: false)
        effects.pinsToBottom = true
        return effects
    }

    /// The app entered the background.
    mutating func enteredBackground() -> Effects {
        isSuspended = true
        // Nothing may wake up for this list while backgrounded: the resume
        // refreshes unconditionally.
        return Effects(cancelsScheduledRefresh: true)
    }

    /// The app is about to return to the foreground: catch up before the
    /// first foreground frame, so the transcript is already current when the
    /// app (or the PiP restore) comes back.
    mutating func willEnterForeground() -> Effects {
        guard isSuspended else { return Effects() }
        isSuspended = false
        let reconfigureAll = pendingReconfigureAll
        pendingReconfigureAll = false
        return Effects(refresh: .now(reconfigureAll: reconfigureAll), pinsToBottom: true)
    }

    // MARK: - Unread count

    /// Called after each refresh with the feed's held-back count: what, if
    /// anything, to push to SwiftUI. `limit` is the transcript's line cap —
    /// arrivals beyond it were trimmed before the reader could jump down to
    /// them.
    mutating func unreadReport(
        heldBack: Int,
        limit: Int,
        now: ContinuousClock.Instant
    ) -> UnreadReport? {
        let count = min(heldBack, limit)
        guard count != lastReportedUnread else { return nil }
        // Zero (caught up — the pill must clear at once) is never delayed;
        // a count that is still climbing is (see `unreadReportInterval`).
        if count != 0, let last = lastUnreadReportAt, now - last < Self.unreadReportInterval {
            return .after(Self.unreadReportInterval - (now - last))
        }
        lastUnreadReportAt = now
        lastReportedUnread = count
        return .now(count)
    }
}
