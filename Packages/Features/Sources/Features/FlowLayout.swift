import SwiftUI

/// A SwiftUI Layout that arranges children left-to-right, wrapping to the next
/// line when horizontal space is exhausted. Used by ChatRow to mix Text and
/// emote image subviews in a single natural-reading flow.
///
/// ## Performance: subview-size cache
///
/// SwiftUI's `Layout` protocol invokes both `sizeThatFits` and `placeSubviews`
/// for every layout pass — and crucially, both methods receive the same
/// `subviews` collection. The naive implementation re-measures each subview
/// (`subview.sizeThatFits(...)`) in BOTH calls, doubling the measurement cost.
///
/// For chat rows with 5–15 subviews each, ×10 visible rows in a LazyVStack,
/// that's 100–300 measurements per scroll-induced layout pass — all duplicated.
/// The `Cache` here computes sizes once in `sizeThatFits` and `placeSubviews`
/// reuses them. ~50% reduction in `Layout` work on hot scroll paths.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var alignment: VerticalAlignment

    /// Per-layout-pass cache of subview sizes. SwiftUI calls `makeCache` once
    /// when the Layout's view tree is built and reuses the storage across
    /// repeated `sizeThatFits` / `placeSubviews` calls.
    ///
    /// `containerWidth` is stored alongside the sizes so we can invalidate
    /// if `placeSubviews` is called with a different width than the most
    /// recent `sizeThatFits` (rare — only on container size changes).
    struct Cache {
        var sizes: [CGSize] = []
        var containerWidth: CGFloat = .nan
    }

    init(spacing: CGFloat = 4, alignment: VerticalAlignment = .firstTextBaseline) {
        self.spacing = spacing
        self.alignment = alignment
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// SwiftUI calls this when the subviews collection changes between
    /// layout passes (subview added/removed). We invalidate by clearing
    /// the sizes array; the next `sizeThatFits` repopulates.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if cache.sizes.count != subviews.count {
            cache.sizes = []
            cache.containerWidth = .nan
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        ensureSizes(subviews: subviews, containerWidth: containerWidth, cache: &cache)

        var totalHeight: CGFloat = 0
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for size in cache.sizes {
            if currentX + size.width > containerWidth, currentX > 0 {
                totalHeight += currentRowHeight + spacing
                currentX = 0
                currentRowHeight = 0
            }
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        return CGSize(width: containerWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let containerWidth = bounds.width
        ensureSizes(subviews: subviews, containerWidth: containerWidth, cache: &cache)

        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var rowSubviews: [(subview: LayoutSubview, size: CGSize)] = []

        func flushRow() {
            guard !rowSubviews.isEmpty else { return }
            let rowHeight = rowSubviews.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for (subview, size) in rowSubviews {
                // Align within row based on vertical alignment
                let yOffset: CGFloat
                switch alignment {
                case .firstTextBaseline:
                    // Approximate baseline alignment: bottom-align short items (emote images)
                    // with text. Since we can't query baseline from LayoutSubview directly,
                    // we bottom-align all items within the row height.
                    yOffset = rowHeight - size.height
                case .center:
                    yOffset = (rowHeight - size.height) / 2
                case .bottom:
                    yOffset = rowHeight - size.height
                default:
                    yOffset = 0
                }
                subview.place(
                    at: CGPoint(x: x, y: currentY + yOffset),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            currentY += rowHeight + spacing
            rowSubviews.removeAll()
        }

        for (subview, size) in zip(subviews, cache.sizes) {
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                flushRow()
                currentX = bounds.minX
            }
            rowSubviews.append((subview, size))
            currentX += size.width + spacing
        }
        flushRow()
    }

    /// Populate `cache.sizes` if empty OR if the containerWidth has changed
    /// since the last measure. Repeated calls with the same width are no-ops
    /// — the cache is hot across the `sizeThatFits` + `placeSubviews` pair
    /// for any given layout pass.
    private func ensureSizes(subviews: Subviews, containerWidth: CGFloat, cache: inout Cache) {
        if cache.sizes.count == subviews.count && cache.containerWidth == containerWidth {
            return
        }
        cache.sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
        }
        cache.containerWidth = containerWidth
    }
}
