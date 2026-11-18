import Testing
@testable import Features

/// `ChatListTailing` is the decision half of `ChatListViewController`: what
/// each scroll, visibility, app-lifecycle and update event does to the pin
/// and to the list's refreshes. The controller (iOS-only) reads the geometry
/// and performs the effects; these tests hand the facts in and check the
/// state and the effects that come back.
@Suite("ChatListTailing")
struct ChatListTailingTests {

    private typealias Effects = ChatListTailing.Effects

    private let inputs = ChatRowInputs(badgeEntryCount: 0, canModerate: false)
    private let loadedInputs = ChatRowInputs(badgeEntryCount: 12, canModerate: false)

    /// Flush what was held back, then glue to the bottom.
    private let resume = Effects(refresh: .now(reconfigureAll: false), pinsToBottom: true)
    /// An on-screen, foreground update with nothing special about it.
    private let applyNow = Effects(cancelsScheduledRefresh: true, refresh: .now(reconfigureAll: false))

    /// A list past its first update (which primes it, and is never coalesced
    /// or reconfigured).
    private func primed(visible: Bool = true) -> ChatListTailing {
        var tailing = ChatListTailing()
        _ = tailing.setVisible(visible, isViewLoaded: false)
        _ = tailing.update(rowInputs: inputs, scrollToBottomToken: 0, isDragging: false)
        return tailing
    }

    /// A primed list whose reader has dragged up into scrollback.
    private func readingScrollback() -> ChatListTailing {
        var tailing = primed()
        tailing.dragBegan()
        _ = tailing.dragEnded(willDecelerate: false, isNearBottom: false)
        return tailing
    }

    // MARK: - Dragging

    @Test("Chat opens tailing")
    func startsPinned() {
        let tailing = ChatListTailing()
        #expect(tailing.isPinnedToBottom)
        #expect(!tailing.repinAfterDrag)
    }

    @Test("A finger on the list unpins at once")
    func dragUnpins() {
        var tailing = primed()
        tailing.dragBegan()
        #expect(!tailing.isPinnedToBottom)
    }

    @Test("A drag released near the bottom without momentum resumes tailing: flush, then pin")
    func releaseNearBottomResumes() {
        var tailing = primed()
        tailing.dragBegan()
        let effects = tailing.dragEnded(willDecelerate: false, isNearBottom: true)
        #expect(effects == resume)
        #expect(tailing.isPinnedToBottom)
    }

    @Test("A drag released up in scrollback stays unpinned")
    func releaseInScrollbackStaysUnpinned() {
        var tailing = primed()
        tailing.dragBegan()
        let effects = tailing.dragEnded(willDecelerate: false, isNearBottom: false)
        #expect(effects == Effects())
        #expect(!tailing.isPinnedToBottom)
    }

    @Test("A release with momentum waits for the deceleration to settle")
    func momentumWaitsForDeceleration() {
        var tailing = primed()
        tailing.dragBegan()
        // Near the bottom right now, but still moving.
        let released = tailing.dragEnded(willDecelerate: true, isNearBottom: true)
        #expect(released == Effects())
        #expect(!tailing.isPinnedToBottom)

        let settled = tailing.decelerationEnded(isNearBottom: true)
        #expect(settled == resume)
        #expect(tailing.isPinnedToBottom)
    }

    @Test("Momentum that settles up in scrollback stays unpinned")
    func decelerationInScrollbackStaysUnpinned() {
        var tailing = primed()
        tailing.dragBegan()
        _ = tailing.dragEnded(willDecelerate: true, isNearBottom: false)
        let settled = tailing.decelerationEnded(isNearBottom: false)
        #expect(settled == Effects())
        #expect(!tailing.isPinnedToBottom)
    }

    @Test("isAtBottom is reported on a flip only, starting from at-bottom")
    func atBottomReportedOnFlip() {
        var tailing = ChatListTailing()
        let stillAtBottom = tailing.scrolled(isNearBottom: true)
        let leftBottom = tailing.scrolled(isNearBottom: false)
        let stillAway = tailing.scrolled(isNearBottom: false)
        let cameBack = tailing.scrolled(isNearBottom: true)
        #expect(stillAtBottom == nil)
        #expect(leftBottom == false)
        #expect(stillAway == nil)
        #expect(cameBack == true)
    }

    // MARK: - Re-pin requests

    @Test("A jump request while reading scrollback re-pins before the pull, then pins")
    func jumpRequestRepins() {
        var tailing = readingScrollback()
        let effects = tailing.update(rowInputs: inputs, scrollToBottomToken: 1, isDragging: false)
        #expect(tailing.isPinnedToBottom)
        #expect(effects == Effects(
            cancelsScheduledRefresh: true,
            refresh: .now(reconfigureAll: false),
            pinsToBottom: true
        ))
    }

    @Test("The same token again is not a new request")
    func sameTokenIsNotARequest() {
        var tailing = readingScrollback()
        _ = tailing.update(rowInputs: inputs, scrollToBottomToken: 1, isDragging: false)
        tailing.dragBegan()
        let effects = tailing.update(rowInputs: inputs, scrollToBottomToken: 1, isDragging: true)
        #expect(effects == applyNow)
        #expect(!tailing.isPinnedToBottom)
        #expect(!tailing.repinAfterDrag)
    }

    @Test("A jump request with a finger on the list waits for the finger to lift")
    func jumpRequestMidDragIsDeferred() {
        var tailing = primed()
        tailing.dragBegan()
        let requested = tailing.update(rowInputs: inputs, scrollToBottomToken: 1, isDragging: true)
        // Applies the update, but neither pins nor re-enters tailing yet.
        #expect(requested == applyNow)
        #expect(!tailing.isPinnedToBottom)
        #expect(tailing.repinAfterDrag)

        // Momentum or not, near the bottom or not.
        let released = tailing.dragEnded(willDecelerate: true, isNearBottom: false)
        #expect(released == resume)
        #expect(tailing.isPinnedToBottom)
        #expect(!tailing.repinAfterDrag)

        // The momentum settling later doesn't undo it.
        let settled = tailing.decelerationEnded(isNearBottom: false)
        #expect(settled == Effects())
        #expect(tailing.isPinnedToBottom)
    }

    // MARK: - Row inputs

    @Test("The first update applies at once and reconfigures nothing")
    func firstUpdate() {
        var tailing = ChatListTailing()
        let effects = tailing.update(rowInputs: loadedInputs, scrollToBottomToken: 0, isDragging: false)
        #expect(effects == applyNow)
    }

    @Test("Changed row inputs reconfigure every row in the same apply; unchanged ones don't")
    func rowInputsChange() {
        var tailing = primed()
        let changed = tailing.update(rowInputs: loadedInputs, scrollToBottomToken: 0, isDragging: false)
        #expect(changed == Effects(cancelsScheduledRefresh: true, refresh: .now(reconfigureAll: true)))

        let unchanged = tailing.update(rowInputs: loadedInputs, scrollToBottomToken: 0, isDragging: false)
        #expect(unchanged == applyNow)
    }

    // MARK: - Off-screen pager neighbour

    @Test("An off-screen neighbour's first update still applies at once")
    func offscreenFirstUpdatePrimes() {
        var tailing = ChatListTailing()
        _ = tailing.setVisible(false, isViewLoaded: false)
        let effects = tailing.update(rowInputs: inputs, scrollToBottomToken: 0, isDragging: false)
        #expect(effects == applyNow)
    }

    @Test("Off-screen, plain data updates are coalesced into a later refresh")
    func offscreenUpdatesAreCoalesced() {
        var tailing = primed(visible: false)
        let effects = tailing.update(rowInputs: inputs, scrollToBottomToken: 0, isDragging: false)
        // Doesn't cancel: a refresh already scheduled carries this one too.
        #expect(effects == Effects(refresh: .later))
    }

    @Test("Off-screen, a row-input change still applies at once")
    func offscreenRowInputsApplyNow() {
        var tailing = primed(visible: false)
        let effects = tailing.update(rowInputs: loadedInputs, scrollToBottomToken: 0, isDragging: false)
        #expect(effects == Effects(cancelsScheduledRefresh: true, refresh: .now(reconfigureAll: true)))
    }

    @Test("Off-screen, a re-pin request still applies at once")
    func offscreenJumpAppliesNow() {
        var tailing = primed(visible: false)
        let effects = tailing.update(rowInputs: inputs, scrollToBottomToken: 1, isDragging: false)
        #expect(effects == Effects(
            cancelsScheduledRefresh: true,
            refresh: .now(reconfigureAll: false),
            pinsToBottom: true
        ))
    }

    @Test("The scheduled refresh applies when it comes due, without pinning")
    func scheduledRefreshFires() {
        let tailing = primed(visible: false)
        #expect(tailing.scheduledRefreshFired() == Effects(refresh: .now(reconfigureAll: false)))
    }

    @Test("Becoming visible drops the scheduled refresh and catches up at once")
    func becomingVisibleCatchesUp() {
        var tailing = primed(visible: false)
        let effects = tailing.setVisible(true, isViewLoaded: true)
        #expect(tailing.isVisible)
        #expect(effects == Effects(
            cancelsScheduledRefresh: true,
            refresh: .now(reconfigureAll: false),
            pinsToBottom: true
        ))
    }

    @Test("Going off screen, or being told the same visibility again, does nothing")
    func otherVisibilityChangesDoNothing() {
        var tailing = primed()
        let same = tailing.setVisible(true, isViewLoaded: true)
        #expect(same == Effects())

        let hidden = tailing.setVisible(false, isViewLoaded: true)
        #expect(hidden == Effects())
        #expect(!tailing.isVisible)
    }

    @Test("Before the view has loaded, visibility is only recorded")
    func visibilityBeforeViewLoads() {
        var tailing = ChatListTailing()
        _ = tailing.setVisible(false, isViewLoaded: false)
        let effects = tailing.setVisible(true, isViewLoaded: false)
        #expect(effects == Effects())
        #expect(tailing.isVisible)
    }

    @Test("After a pinned apply, only a visible list or a reset settles its layout at once")
    func layoutSettlesForVisibleOrReset() {
        let visible = primed()
        #expect(visible.settlesLayoutAfterApply(isReset: false))
        #expect(visible.settlesLayoutAfterApply(isReset: true))

        let neighbour = primed(visible: false)
        #expect(!neighbour.settlesLayoutAfterApply(isReset: false))
        #expect(neighbour.settlesLayoutAfterApply(isReset: true))
    }

    // MARK: - Background

    @Test("Backgrounded, the scheduled refresh is dropped and updates apply nothing")
    func backgroundSuspends() {
        var tailing = primed(visible: false)
        let backgrounded = tailing.enteredBackground()
        #expect(backgrounded == Effects(cancelsScheduledRefresh: true))
        #expect(tailing.isSuspended)

        let update = tailing.update(rowInputs: inputs, scrollToBottomToken: 0, isDragging: false)
        #expect(update == Effects())
        // A refresh that came due anyway applies nothing either.
        #expect(tailing.scheduledRefreshFired() == Effects())
    }

    @Test("Returning to the foreground catches up in one refresh and pins")
    func foregroundCatchesUp() {
        var tailing = primed()
        _ = tailing.enteredBackground()
        _ = tailing.update(rowInputs: inputs, scrollToBottomToken: 0, isDragging: false)

        let effects = tailing.willEnterForeground()
        #expect(effects == resume)
        #expect(!tailing.isSuspended)
    }

    @Test("A row-input change while backgrounded becomes a reconfigure-all on resume, once")
    func rowInputsWhileBackgrounded() {
        var tailing = primed()
        _ = tailing.enteredBackground()
        let update = tailing.update(rowInputs: loadedInputs, scrollToBottomToken: 0, isDragging: false)
        #expect(update == Effects())
        #expect(tailing.pendingReconfigureAll)

        let resumed = tailing.willEnterForeground()
        #expect(resumed == Effects(refresh: .now(reconfigureAll: true), pinsToBottom: true))
        #expect(!tailing.pendingReconfigureAll)

        // The next trip to the background has nothing left over.
        _ = tailing.enteredBackground()
        let again = tailing.willEnterForeground()
        #expect(again == resume)
    }

    @Test("A re-pin request while backgrounded is recorded for the resume")
    func jumpRequestWhileBackgrounded() {
        var tailing = readingScrollback()
        _ = tailing.enteredBackground()
        let update = tailing.update(rowInputs: inputs, scrollToBottomToken: 1, isDragging: false)
        #expect(update == Effects())
        #expect(tailing.isPinnedToBottom)
    }

    @Test("A foreground notification with no background before it does nothing")
    func foregroundWithoutBackground() {
        var tailing = primed()
        let effects = tailing.willEnterForeground()
        #expect(effects == Effects())
    }

    @Test("Becoming visible while backgrounded leaves the catch-up to the resume")
    func becomingVisibleWhileBackgrounded() {
        var tailing = primed(visible: false)
        _ = tailing.enteredBackground()
        let effects = tailing.setVisible(true, isViewLoaded: true)
        #expect(effects == Effects(cancelsScheduledRefresh: true))
    }

    // MARK: - Unread count

    @Test("The first unread count is pushed at once; an unchanged one is not pushed again")
    func unreadFirstReport() {
        var tailing = primed()
        let start = ContinuousClock.now
        let first = tailing.unreadReport(heldBack: 3, limit: .max, now: start)
        let same = tailing.unreadReport(heldBack: 3, limit: .max, now: start + .seconds(5))
        #expect(first == .now(3))
        #expect(same == nil)
    }

    @Test("A count still climbing inside the interval is held for a trailing push")
    func unreadClimbingIsThrottled() {
        var tailing = primed()
        let start = ContinuousClock.now
        _ = tailing.unreadReport(heldBack: 1, limit: .max, now: start)

        let soon = tailing.unreadReport(heldBack: 5, limit: .max, now: start + .milliseconds(200))
        #expect(soon == .after(.milliseconds(300)))
        // Not recorded as pushed: asked again, it is still owed.
        let stillSoon = tailing.unreadReport(heldBack: 6, limit: .max, now: start + .milliseconds(400))
        #expect(stillSoon == .after(.milliseconds(100)))

        let due = tailing.unreadReport(heldBack: 6, limit: .max, now: start + .milliseconds(500))
        #expect(due == .now(6))
    }

    @Test("Zero — caught up — is never delayed")
    func unreadZeroIsImmediate() {
        var tailing = primed()
        let start = ContinuousClock.now
        _ = tailing.unreadReport(heldBack: 4, limit: .max, now: start)
        let caughtUp = tailing.unreadReport(heldBack: 0, limit: .max, now: start + .milliseconds(100))
        #expect(caughtUp == .now(0))
    }

    @Test("The count stops at the transcript's line cap")
    func unreadClampedToLimit() {
        var tailing = primed()
        let start = ContinuousClock.now
        let capped = tailing.unreadReport(heldBack: 900, limit: 500, now: start)
        let beyond = tailing.unreadReport(heldBack: 1_200, limit: 500, now: start + .seconds(5))
        #expect(capped == .now(500))
        #expect(beyond == nil)
    }
}
