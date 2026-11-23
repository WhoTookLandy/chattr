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

        #expect(!policy.update(with: makeSnapshot(offsetY: 0)))
        #expect(!policy.update(with: makeSnapshot(offsetY: 20)))
        // First step past topRevealOffset (24): delta = 12 (< 28)
        #expect(!policy.update(with: makeSnapshot(offsetY: 32)))
        // Cumulative downward delta = 24 (< 28)
        #expect(!policy.update(with: makeSnapshot(offsetY: 44)))
        // Cumulative downward delta = 32 (>= 28) -> hides
        #expect(policy.update(with: makeSnapshot(offsetY: 52)))
    }

    @Test("Reappears on upward scroll past show threshold")
    func reappearsOnUpwardScroll() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        // Scroll down until hidden.
        _ = policy.update(with: makeSnapshot(offsetY: 200))
        #expect(policy.update(with: makeSnapshot(offsetY: 240)))

        // Small upward jitter below showThreshold (18) keeps it hidden.
        #expect(policy.update(with: makeSnapshot(offsetY: 230)))
        // Crossing -18 total upward travel reveals the tab bar.
        #expect(!policy.update(with: makeSnapshot(offsetY: 220)))
    }

    @Test("Direction reversal resets accumulated hysteresis distance")
    func directionReversalResetsAccumulatedDelta() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        _ = policy.update(with: makeSnapshot(offsetY: 200))
        // Down 20pt (below 28pt threshold)
        #expect(!policy.update(with: makeSnapshot(offsetY: 220)))
        // Up 4pt resets accumulated downward delta
        #expect(!policy.update(with: makeSnapshot(offsetY: 216)))
        // Down 20pt again is still below 28pt from the reversal
        #expect(!policy.update(with: makeSnapshot(offsetY: 236)))
        // Down 10pt more reaches 30pt -> hides
        #expect(policy.update(with: makeSnapshot(offsetY: 246)))
    }

    @Test("Always reveals near the top, during pull-to-refresh, and on programmatic scroll-to-top")
    func revealsNearTopEvenDuringAnimatingPhase() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        _ = policy.update(with: makeSnapshot(offsetY: 300))
        #expect(policy.update(with: makeSnapshot(offsetY: 340)))

        // Simulate tapping the status bar to scroll back to top (.animating).
        policy.updatePhase(.animating)
        #expect(policy.update(with: makeSnapshot(offsetY: 120)))
        #expect(!policy.update(with: makeSnapshot(offsetY: 10)))

        // Pull-to-refresh overscroll and release back to 0 stay visible.
        policy.updatePhase(.interacting)
        #expect(!policy.update(with: makeSnapshot(offsetY: -60)))
        policy.updatePhase(.decelerating)
        #expect(!policy.update(with: makeSnapshot(offsetY: 0)))
    }

    @Test("Never hides on short feeds and reveals if content shrinks below scrollable minimum")
    func staysVisibleOnShortFeeds() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        // Feed only overflows by 80pt (< 120pt minimum).
        _ = policy.update(with: makeSnapshot(offsetY: 30, maxOffsetY: 80))
        #expect(!policy.update(with: makeSnapshot(offsetY: 75, maxOffsetY: 80)))

        // Hide on a tall feed, then simulate filtering down to a single card.
        _ = policy.update(with: makeSnapshot(offsetY: 200, maxOffsetY: 1000))
        #expect(policy.update(with: makeSnapshot(offsetY: 240, maxOffsetY: 1000)))
        #expect(!policy.update(with: makeSnapshot(offsetY: 40, maxOffsetY: 60)))
    }

    @Test("Ignores bottom-inset changes and bottom clamps so hiding near the end does not bounce back")
    func ignoresBottomInsetChangeAndClamp() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        _ = policy.update(with: makeSnapshot(offsetY: 940, maxOffsetY: 1000, bottomInset: 83))
        // User scrolls down near bottom -> tab bar hides.
        #expect(policy.update(with: makeSnapshot(offsetY: 980, maxOffsetY: 1000, bottomInset: 83)))

        // Hiding the tab bar shrinks bottomInset (83 -> 34) and maxOffsetY (1000 -> 951),
        // clamping offsetY upward by 29pt. Must NOT trigger upward reveal.
        #expect(policy.update(with: makeSnapshot(offsetY: 951, maxOffsetY: 951, bottomInset: 34)))

        // Even if the offset clamp lands on the frame after the inset change,
        // the overscroll guard still prevents a false reveal.
        policy.syncHidden(true)
        policy.recordBaseline(makeSnapshot(offsetY: 980, maxOffsetY: 951, bottomInset: 34))
        #expect(policy.update(with: makeSnapshot(offsetY: 951, maxOffsetY: 951, bottomInset: 34)))
    }

    @Test("Ignores bottom rubber-band overscroll and bounce-back")
    func ignoresBottomRubberBandBounce() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        _ = policy.update(with: makeSnapshot(offsetY: 940, maxOffsetY: 1000))
        #expect(policy.update(with: makeSnapshot(offsetY: 980, maxOffsetY: 1000)))

        // Drag past bottom edge into overscroll, then bounce back during deceleration.
        #expect(policy.update(with: makeSnapshot(offsetY: 1045, maxOffsetY: 1000)))
        policy.updatePhase(.decelerating)
        #expect(policy.update(with: makeSnapshot(offsetY: 1000, maxOffsetY: 1000)))
    }

    @Test("Ignores container-height changes and non-user scroll phases")
    func ignoresLayoutResizeAndNonUserPhases() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.idle)

        // Programmatic / idle downward shift does not hide.
        _ = policy.update(with: makeSnapshot(offsetY: 200))
        #expect(!policy.update(with: makeSnapshot(offsetY: 300)))

        // Tracking before active drag does not hide.
        policy.updatePhase(.tracking)
        #expect(!policy.update(with: makeSnapshot(offsetY: 360)))

        // User drags down -> hides.
        policy.updatePhase(.interacting)
        #expect(policy.update(with: makeSnapshot(offsetY: 400)))

        // Container resize with offset shift does not reveal.
        #expect(policy.update(with: makeSnapshot(offsetY: 340, containerHeight: 500)))
    }

    @Test("syncHidden and recordBaseline allow clean re-hide after an external reset")
    func syncHiddenAndRecordBaselineResyncCleanly() {
        var policy = HomeTabBarScrollPolicy()
        policy.updatePhase(.interacting)

        _ = policy.update(with: makeSnapshot(offsetY: 300))
        #expect(policy.update(with: makeSnapshot(offsetY: 340)))

        // External section switch reveals tab bar while this page goes off-screen.
        policy.syncHidden(false)
        policy.recordBaseline(makeSnapshot(offsetY: 340, bottomInset: 83))
        #expect(!policy.isHidden)

        // Returning to this section and scrolling down again hides immediately past threshold.
        #expect(policy.update(with: makeSnapshot(offsetY: 372, bottomInset: 83)))
    }
}
