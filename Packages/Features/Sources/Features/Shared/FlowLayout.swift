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
    /// Indent applied to every wrapped (non-first) row. 0 = classic flow.
    var hangingIndent: CGFloat

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

    init(spacing: CGFloat = 4, alignment: VerticalAlignment = .firstTextBaseline, hangingIndent: CGFloat = 0) {
        self.spacing = spacing
        self.alignment = alignment
        self.hangingIndent = hangingIndent
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
        return FlowLayoutEngine.layout(
            sizes: cache.sizes,
            containerWidth: containerWidth,
            spacing: spacing,
            hangingIndent: hangingIndent
        ).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let containerWidth = bounds.width
        ensureSizes(subviews: subviews, containerWidth: containerWidth, cache: &cache)
        let result = FlowLayoutEngine.layout(
            sizes: cache.sizes,
            containerWidth: containerWidth,
            spacing: spacing,
            hangingIndent: hangingIndent
        )
        // Group origins by row (same y) to apply per-row vertical alignment.
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            let size = cache.sizes[index]
            let rowHeight = rowHeightForY(origin.y, origins: result.origins, sizes: cache.sizes)
            let yOffset: CGFloat
            switch alignment {
            case .center: yOffset = (rowHeight - size.height) / 2
            default:      yOffset = rowHeight - size.height // baseline/bottom approx (unchanged)
            }
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y + yOffset),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    /// Tallest subview height among those sharing the row at `y`.
    private func rowHeightForY(_ y: CGFloat, origins: [CGPoint], sizes: [CGSize]) -> CGFloat {
        var h: CGFloat = 0
        for (i, o) in origins.enumerated() where o.y == y {
            h = max(h, sizes[i].height)
        }
        return h
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
