import Testing
import CoreGraphics
@testable import Features

@Suite("ScrollAnchor.isNearBottom")
struct ScrollAnchorTests {

    // distance = contentHeight - offsetY - containerHeight + bottomInset

    @Test("Exactly at the bottom is near-bottom")
    func atBottom() {
        // content 1000, container 600, offset 400 → distance 0
        #expect(ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 400, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Scrolled well up is not near-bottom")
    func scrolledUp() {
        // offset 0 → distance 400
        #expect(!ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 0, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Within the 44pt threshold counts as near-bottom")
    func withinThreshold() {
        // offset 360 → distance 40 (≤ 44)
        #expect(ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 360, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Just past the threshold is not near-bottom")
    func pastThreshold() {
        // offset 355 → distance 45 (> 44)
        #expect(!ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 355, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Bottom inset is added back into the distance")
    func bottomInsetCounted() {
        // distance = 1000 - 380 - 600 + 20 = 40 → near-bottom
        #expect(ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 380, containerHeight: 600, bottomInset: 20
        ))
    }
}

@Suite("ScrollAnchor.bottomPinnedOffsetY")
struct BottomPinnedOffsetTests {

    // pinned offset = contentHeight - containerHeight + bottomInset,
    // floored at -topInset (the scroll view's natural rest position)

    @Test("Tall content pins to content bottom")
    func tallContent() {
        #expect(ScrollAnchor.bottomPinnedOffsetY(
            contentHeight: 1000, containerHeight: 600, topInset: 0, bottomInset: 0
        ) == 400)
    }

    @Test("Bottom inset pushes the pin further down")
    func bottomInset() {
        // The compose bar's safe-area inset means "bottom" is above it:
        // 1000 - 600 + 20 = 420
        #expect(ScrollAnchor.bottomPinnedOffsetY(
            contentHeight: 1000, containerHeight: 600, topInset: 0, bottomInset: 20
        ) == 420)
    }

    @Test("Content shorter than the viewport rests at the top inset")
    func shortContentClampsToTopInset() {
        // 300 - 600 = -300 would over-scroll; clamp to -topInset (-50)
        #expect(ScrollAnchor.bottomPinnedOffsetY(
            contentHeight: 300, containerHeight: 600, topInset: 50, bottomInset: 0
        ) == -50)
    }

    @Test("Short content with no insets rests at zero")
    func shortContentNoInsets() {
        #expect(ScrollAnchor.bottomPinnedOffsetY(
            contentHeight: 300, containerHeight: 600, topInset: 0, bottomInset: 0
        ) == 0)
    }
}
