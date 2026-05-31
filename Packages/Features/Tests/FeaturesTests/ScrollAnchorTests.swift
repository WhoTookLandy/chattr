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
