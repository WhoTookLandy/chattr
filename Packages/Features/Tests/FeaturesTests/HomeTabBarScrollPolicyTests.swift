import CoreGraphics
import Testing
@testable import Features

@Suite("Home tab bar scroll visibility policy")
struct HomeTabBarScrollPolicyTests {

    private func makeSnapshot(
        offsetY: CGFloat,
        maxOffsetY: CGFloat = 1200,
        bottomInset: CGFloat = 83,
        containerHeight: CGFloat = 760
    ) -> HomeTabBarScrollPolicy.Snapshot {
        HomeTabBarScrollPolicy.Snapshot(
            offsetY: offsetY,
            maxOffsetY: maxOffsetY,
            bottomInset: bottomInset,
            containerHeight: containerHeight
        )
    }

    @Test("Hides after scrolling down past top zone and hide threshold")
    func hidesOnDownwardScroll() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        policy.update(with: makeSnapshot(offsetY: 0))
        #expect(!policy.isHidden)

        policy.update(with: makeSnapshot(offsetY: 20))
        #expect(!policy.isHidden)

        // First step past topRevealOffset (24): delta = 12 (< 28)
        policy.update(with: makeSnapshot(offsetY: 32))
        #expect(!policy.isHidden)

        // Cumulative downward delta = 24 (< 28)
        policy.update(with: makeSnapshot(offsetY: 44))
        #expect(!policy.isHidden)

        // Cumulative downward delta = 32 (>= 28) -> hides
        policy.update(with: makeSnapshot(offsetY: 52))
        #expect(policy.isHidden)
    }

    @Test("Reappears on upward scroll past show threshold")
    func reappearsOnUpwardScroll() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        // Scroll down until hidden.
        policy.update(with: makeSnapshot(offsetY: 200))
        policy.update(with: makeSnapshot(offsetY: 240))
        #expect(policy.isHidden)

        // Small upward jitter below showThreshold (18) keeps it hidden.
        policy.update(with: makeSnapshot(offsetY: 230))
        #expect(policy.isHidden)

        // Crossing -18 total upward travel reveals the tab bar.
        policy.update(with: makeSnapshot(offsetY: 220))
        #expect(!policy.isHidden)
    }

    @Test("Direction reversal resets accumulated hysteresis distance")
    func directionReversalResetsAccumulatedDelta() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        policy.update(with: makeSnapshot(offsetY: 200))
        // Down 20pt (below 28pt threshold)
        policy.update(with: makeSnapshot(offsetY: 220))
        #expect(!policy.isHidden)

        // Up 4pt resets accumulated downward delta
        policy.update(with: makeSnapshot(offsetY: 216))
        #expect(!policy.isHidden)

        // Down 20pt again is still below 28pt from the reversal
        policy.update(with: makeSnapshot(offsetY: 236))
        #expect(!policy.isHidden)

        // Down 10pt more reaches 30pt -> hides
        policy.update(with: makeSnapshot(offsetY: 246))
        #expect(policy.isHidden)
    }

    @Test("Always reveals near the top, during pull-to-refresh, and on programmatic scroll-to-top")
    func revealsNearTopEvenDuringAnimatingPhase() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        policy.update(with: makeSnapshot(offsetY: 300))
        policy.update(with: makeSnapshot(offsetY: 340))
        #expect(policy.isHidden)

        // Simulate tapping the status bar to scroll back to top (.animating).
        policy.updatePhase(.animating)
        policy.update(with: makeSnapshot(offsetY: 120))
        #expect(policy.isHidden)

        policy.update(with: makeSnapshot(offsetY: 10))
        #expect(!policy.isHidden)

        // Pull-to-refresh overscroll and release back to 0 stay visible.
        policy.updatePhase(.interacting)
        policy.update(with: makeSnapshot(offsetY: -60))
        #expect(!policy.isHidden)

        policy.updatePhase(.decelerating)
        policy.update(with: makeSnapshot(offsetY: 0))
        #expect(!policy.isHidden)
    }

    @Test("Stays visible on short feeds, stays hidden across tab-bar inset range shrink, and reveals on real content shrinkage")
    func shortFeedDetectionStableAcrossInsetChanges() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        // Feed only overflows viewport by 47pt (130 - 83 < 60pt minimum).
        policy.update(with: makeSnapshot(offsetY: 30, maxOffsetY: 130, bottomInset: 83))
        policy.update(with: makeSnapshot(offsetY: 75, maxOffsetY: 130, bottomInset: 83))
        #expect(!policy.isHidden)

        // With maxOffsetY = 150 and bottomInset = 83 (overflow = 67 >= 60),
        // scrolling down hides the tab bar.
        policy.update(with: makeSnapshot(offsetY: 100, maxOffsetY: 150, bottomInset: 83))
        policy.update(with: makeSnapshot(offsetY: 140, maxOffsetY: 150, bottomInset: 83))
        #expect(policy.isHidden)

        // Hiding removes 49pt of bottom inset -> maxOffsetY drops 150 -> 101 -> 101.
        // Content overflow is still 67pt (101 - 34), so the tab bar must stay hidden.
        policy.update(with: makeSnapshot(offsetY: 101, maxOffsetY: 101, bottomInset: 34))
        #expect(policy.isHidden)
        policy.update(with: makeSnapshot(offsetY: 101, maxOffsetY: 101, bottomInset: 34))
        #expect(policy.isHidden)

        // Genuine content shrinkage (e.g., category filter drops overflow to 26pt)
        // immediately reveals the tab bar.
        policy.update(with: makeSnapshot(offsetY: 40, maxOffsetY: 60, bottomInset: 34))
        #expect(!policy.isHidden)
    }

    @Test("Ignores bottom-inset changes and bottom clamps so hiding near the end does not bounce back")
    func ignoresBottomInsetChangeAndClamp() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        policy.update(with: makeSnapshot(offsetY: 940, maxOffsetY: 1000, bottomInset: 83))
        // User scrolls down near bottom -> tab bar hides.
        policy.update(with: makeSnapshot(offsetY: 980, maxOffsetY: 1000, bottomInset: 83))
        #expect(policy.isHidden)

        // Hiding the tab bar shrinks bottomInset (83 -> 34) and maxOffsetY (1000 -> 951),
        // clamping offsetY upward by 29pt. Must NOT trigger upward reveal.
        policy.update(with: makeSnapshot(offsetY: 951, maxOffsetY: 951, bottomInset: 34))
        #expect(policy.isHidden)

        // Even if the offset clamp lands on the frame after the inset change,
        // the overscroll guard still prevents a false reveal.
        policy.syncHidden(true)
        policy.recordBaseline(makeSnapshot(offsetY: 980, maxOffsetY: 951, bottomInset: 34))
        policy.update(with: makeSnapshot(offsetY: 951, maxOffsetY: 951, bottomInset: 34))
        #expect(policy.isHidden)
    }

    @Test("Ignores bottom rubber-band overscroll and bounce-back")
    func ignoresBottomRubberBandBounce() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        policy.update(with: makeSnapshot(offsetY: 940, maxOffsetY: 1000))
        policy.update(with: makeSnapshot(offsetY: 980, maxOffsetY: 1000))
        #expect(policy.isHidden)

        // Drag past bottom edge into overscroll, then bounce back during deceleration.
        policy.update(with: makeSnapshot(offsetY: 1045, maxOffsetY: 1000))
        #expect(policy.isHidden)

        policy.updatePhase(.decelerating)
        policy.update(with: makeSnapshot(offsetY: 1000, maxOffsetY: 1000))
        #expect(policy.isHidden)
    }

    @Test("Ignores container-height changes and non-user scroll phases")
    func ignoresLayoutResizeAndNonUserPhases() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.idle)

        // Programmatic / idle downward shift does not hide.
        policy.update(with: makeSnapshot(offsetY: 200))
        policy.update(with: makeSnapshot(offsetY: 300))
        #expect(!policy.isHidden)

        // Tracking before active drag does not hide.
        policy.updatePhase(.tracking)
        policy.update(with: makeSnapshot(offsetY: 360))
        #expect(!policy.isHidden)

        // User drags down -> hides.
        policy.updatePhase(.interacting)
        policy.update(with: makeSnapshot(offsetY: 400))
        #expect(policy.isHidden)

        // Container resize with offset shift does not reveal.
        policy.update(with: makeSnapshot(offsetY: 340, containerHeight: 500))
        #expect(policy.isHidden)
    }

    @Test("syncHidden and recordBaseline allow clean re-hide after an external reset")
    func syncHiddenAndRecordBaselineResyncCleanly() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        policy.update(with: makeSnapshot(offsetY: 300))
        policy.update(with: makeSnapshot(offsetY: 340))
        #expect(policy.isHidden)

        // External section switch reveals tab bar while this page goes off-screen.
        policy.syncHidden(false)
        policy.recordBaseline(makeSnapshot(offsetY: 340, bottomInset: 83))
        #expect(!policy.isHidden)

        // Returning to this section and scrolling down again hides immediately past threshold.
        policy.update(with: makeSnapshot(offsetY: 372, bottomInset: 83))
        #expect(policy.isHidden)
    }
}
