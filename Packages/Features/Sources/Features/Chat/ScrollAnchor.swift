import CoreGraphics

/// Pure scroll-geometry helpers for the chat list. Kept UIKit-free so it
/// compiles and unit-tests on every platform (the UICollectionView code in
/// `ChatListView.swift` is iOS-only behind `#if canImport(UIKit)`).
enum ScrollAnchor {

    /// Distance below which the scroll is considered "tailing" the live edge.
    /// 44pt absorbs the small offset jitter during rapid appends so the
    /// jump-to-bottom pill doesn't flicker at the exact bottom. Mirrors the
    /// value `ChatScreen` used with `.onScrollGeometryChange`.
    static let nearBottomThreshold: CGFloat = 44

    /// True when the viewport is at (or within `threshold` of) the bottom of
    /// the content. The arithmetic matches the geometry `ChatScreen` computed
    /// inline: `contentHeight - offsetY - containerHeight + bottomInset`.
    static func isNearBottom(
        contentHeight: CGFloat,
        offsetY: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        threshold: CGFloat = nearBottomThreshold
    ) -> Bool {
        let distanceFromBottom = contentHeight - offsetY - containerHeight + bottomInset
        return distanceFromBottom <= threshold
    }

    /// The `contentOffset.y` that pins the content's bottom edge to the
    /// viewport's bottom edge. Floored at `-topInset` so content shorter than
    /// the viewport rests at its natural top position instead of over-scrolling.
    ///
    /// Re-asserted on every layout pass while tailing (see
    /// `ChatListViewController`): self-sizing cells report their real heights
    /// AFTER a one-shot scroll lands, so any single scroll into unmaterialized
    /// rows lands wrong by construction — re-pinning per pass absorbs each
    /// estimate→actual correction before it's drawn.
    static func bottomPinnedOffsetY(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        max(-topInset, contentHeight - containerHeight + bottomInset)
    }
}
