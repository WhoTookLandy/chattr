import Testing
import CoreGraphics
@testable import Features

@Suite("FlowLayoutEngine")
struct FlowLayoutEngineTests {
    @Test("Single row that fits: origins advance by width+spacing, height = tallest")
    func singleRow() {
        let sizes = [CGSize(width: 20, height: 10), CGSize(width: 30, height: 14)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 100, spacing: 4, hangingIndent: 0)
        #expect(r.origins[0].x == 0)
        #expect(r.origins[1].x == 24) // 20 + 4
        #expect(r.size.height == 14)
        #expect(r.origins[0].y == 0)
        #expect(r.origins[1].y == 0)
    }

    @Test("Wrap when an item exceeds the container width")
    func wraps() {
        let sizes = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 10)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 50, spacing: 4, hangingIndent: 0)
        #expect(r.origins[0].y == 0)
        #expect(r.origins[1].y == 14) // 10 + 4 spacing
        #expect(r.origins[1].x == 0)  // no hanging indent
        #expect(r.size.height == 24)  // two rows of 10 + 4 spacing
    }

    @Test("Hanging indent offsets wrapped rows only, not the first row")
    func hangingIndent() {
        let sizes = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 10)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 50, spacing: 4, hangingIndent: 12)
        #expect(r.origins[0].x == 0)   // first row flush
        #expect(r.origins[1].x == 12)  // wrapped row indented
    }

    @Test("A lone over-wide item still places (no infinite wrap)")
    func loneOverwide() {
        let sizes = [CGSize(width: 200, height: 10)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 50, spacing: 4, hangingIndent: 12)
        #expect(r.origins[0].x == 0)
        #expect(r.size.height == 10)
    }

    @Test("Infinite container returns used width, not infinity")
    func infiniteContainerWidth() {
        // SwiftUI probes layouts with nil width proposals (→ infinity).
        // Returning .infinity as our size breaks the parent's layout math;
        // the ideal size is the single-row used width.
        let sizes = [CGSize(width: 20, height: 10), CGSize(width: 30, height: 14)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: .infinity, spacing: 4, hangingIndent: 0)
        #expect(r.size.width == 54)   // 20 + 4 + 30
        #expect(r.size.height == 14)
    }

    @Test("Finite container still reports the container width (rows fill it)")
    func finiteContainerWidthUnchanged() {
        let sizes = [CGSize(width: 20, height: 10)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 100, spacing: 4, hangingIndent: 0)
        #expect(r.size.width == 100)
    }
}
