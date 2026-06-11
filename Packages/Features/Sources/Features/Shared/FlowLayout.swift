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

    /// Per-layout-pass cache of subview sizes AND the wrapping result. SwiftUI
    /// calls `makeCache` once when the Layout's view tree is built and reuses
    /// the storage across repeated `sizeThatFits` / `placeSubviews` calls.
    ///
    /// `containerWidth` is stored alongside the sizes so we can invalidate
    /// if `placeSubviews` is called with a different width than the most
    /// recent `sizeThatFits` (rare — only on container size changes).
    ///
    /// `result` caches `FlowLayoutEngine.layout` for that same width, so the
    /// `sizeThatFits` + `placeSubviews` pair of a layout pass runs the
    /// wrapping math once instead of twice. Invalidated whenever the sizes
    /// are (same lifetime: both derive from sizes + width).
    struct Cache {
        var sizes: [CGSize] = []
        var containerWidth: CGFloat = .nan
        var result: FlowLayoutEngine.Result?
    }

    init(spacing: CGFloat = 4, alignment: VerticalAlignment = .firstTextBaseline, hangingIndent: CGFloat = 0) {
        self.spacing = spacing
        self.alignment = alignment
        self.hangingIndent = hangingIndent
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    /// SwiftUI calls this when the subviews change between layout passes
    /// — and "change" includes a subview's INTRINSIC SIZE changing with
    /// the count staying the same. That happens constantly in chat rows:
    /// a badge goes 0×0 → 18×18 when its image loads, an emote goes
    /// name-as-text → 28pt image. The previous count-only check kept
    /// stale sizes through those transitions, which is exactly the
    /// "truncated orphan word / emote shoved to the right edge" bug:
    /// origins were computed from measurements of subviews that no
    /// longer exist in that form.
    ///
    /// Unconditional invalidation is the correct (and Apple-sample)
    /// pattern. The cache's job is only to dedupe the sizeThatFits +
    /// placeSubviews pair WITHIN one layout pass — that still works,
    /// because `ensureSizes` early-returns on the second call of a pass.
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = []
        cache.containerWidth = .nan
        cache.result = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        ensureLayout(subviews: subviews, containerWidth: containerWidth, cache: &cache)
        return cache.result?.size ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let containerWidth = bounds.width
        ensureLayout(subviews: subviews, containerWidth: containerWidth, cache: &cache)
        guard let result = cache.result else { return }
        // Per-row vertical alignment via the engine's row table — O(1) per
        // item, no origin scanning.
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            let size = cache.sizes[index]
            let rowHeight = result.rowHeights[result.rowIndexByItem[index]]
            let yOffset: CGFloat
            switch alignment {
            case .center: yOffset = (rowHeight - size.height) / 2
            default:      yOffset = rowHeight - size.height // baseline/bottom approx (unchanged)
            }
            // Clamp the width proposal to the space remaining on the row.
            // A single item wider than the container (long URL, unbroken
            // CJK run) would otherwise be proposed its full measured
            // width and overflow the trailing edge; clamping makes Text
            // wrap/truncate inside bounds instead.
            let availableWidth = max(0, bounds.width - origin.x)
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y + yOffset),
                proposal: ProposedViewSize(width: min(size.width, availableWidth), height: size.height)
            )
        }
    }

    /// Populate `cache.sizes` AND `cache.result` if empty OR if the
    /// containerWidth has changed since the last measure. Repeated calls with
    /// the same width are no-ops — the cache is hot across the
    /// `sizeThatFits` + `placeSubviews` pair for any given layout pass.
    private func ensureLayout(subviews: Subviews, containerWidth: CGFloat, cache: inout Cache) {
        if cache.sizes.count == subviews.count,
           cache.containerWidth == containerWidth,
           cache.result != nil {
            return
        }
        if cache.sizes.count != subviews.count || cache.containerWidth != containerWidth {
            cache.sizes = subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
            }
            cache.containerWidth = containerWidth
        }
        cache.result = FlowLayoutEngine.layout(
            sizes: cache.sizes,
            containerWidth: containerWidth,
            spacing: spacing,
            hangingIndent: hangingIndent
        )
    }
}
