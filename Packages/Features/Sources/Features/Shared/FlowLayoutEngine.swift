import CoreGraphics

/// Pure geometry for `FlowLayout`, extracted so the wrapping math is unit-
/// testable without SwiftUI's `Subviews`/`LayoutSubview`. Computes child
/// origins (top-left, before vertical in-row alignment) and the total size.
///
/// `hangingIndent` shifts every WRAPPED (non-first) row's start x, so a
/// chat message whose body wraps aligns under the text instead of snapping
/// back under the badges.
enum FlowLayoutEngine {
    struct Result {
        var origins: [CGPoint]
        var size: CGSize
    }

    static func layout(
        sizes: [CGSize],
        containerWidth: CGFloat,
        spacing: CGFloat,
        hangingIndent: CGFloat
    ) -> Result {
        var origins: [CGPoint] = []
        origins.reserveCapacity(sizes.count)

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        // First row starts flush at x=0; every wrapped row starts at the
        // hanging indent.
        var rowStart: CGFloat = 0
        // Rightmost extent actually used — reported as the width when the
        // container is unbounded (a SwiftUI nil-width probe). Returning
        // `containerWidth` there would propagate infinity to the parent.
        var usedWidth: CGFloat = 0

        for size in sizes {
            // Wrap if this item overflows AND the row already has content.
            if currentX + size.width > containerWidth, currentX > rowStart {
                currentY += rowHeight + spacing
                rowHeight = 0
                rowStart = hangingIndent
                currentX = rowStart
            }
            origins.append(CGPoint(x: currentX, y: currentY))
            usedWidth = max(usedWidth, currentX + size.width)
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        let totalHeight = currentY + rowHeight
        let totalWidth = containerWidth.isFinite ? containerWidth : usedWidth
        return Result(origins: origins, size: CGSize(width: totalWidth, height: totalHeight))
    }
}
