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
        /// Row membership per item (parallel to `origins`), so callers can
        /// resolve an item's row height in O(1) instead of scanning all
        /// origins for matching y values (which also relied on fragile
        /// floating-point equality of accumulated offsets).
        var rowIndexByItem: [Int]
        /// Tallest item height per row, indexed by `rowIndexByItem`.
        var rowHeights: [CGFloat]
    }

    static func layout(
        sizes: [CGSize],
        containerWidth: CGFloat,
        spacing: CGFloat,
        hangingIndent: CGFloat
    ) -> Result {
        var origins: [CGPoint] = []
        origins.reserveCapacity(sizes.count)
        var rowIndexByItem: [Int] = []
        rowIndexByItem.reserveCapacity(sizes.count)
        var rowHeights: [CGFloat] = []
        var currentRow = 0

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
                rowHeights.append(rowHeight)
                currentRow += 1
                currentY += rowHeight + spacing
                rowHeight = 0
                rowStart = hangingIndent
                currentX = rowStart
            }
            origins.append(CGPoint(x: currentX, y: currentY))
            rowIndexByItem.append(currentRow)
            usedWidth = max(usedWidth, currentX + size.width)
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if !sizes.isEmpty {
            rowHeights.append(rowHeight)
        }

        let totalHeight = currentY + rowHeight
        let totalWidth = containerWidth.isFinite ? containerWidth : usedWidth
        return Result(
            origins: origins,
            size: CGSize(width: totalWidth, height: totalHeight),
            rowIndexByItem: rowIndexByItem,
            rowHeights: rowHeights
        )
    }
}
