import CoreGraphics
import SwiftUI

/// Pure state machine deciding whether Home's bottom tab bar should hide on
/// downward scroll and reappear on upward scroll.
///
/// Kept free of SwiftUI view state so hysteresis, top/bottom rubber-band
/// bounces, bottom-inset shifts caused by the tab bar hiding/reappearing,
/// short feeds, and programmatic scroll-to-top are unit-tested directly in
/// `FeaturesTests`.
struct HomeTabBarScrollPolicy: Sendable {
    /// Metrics captured from a single `ScrollGeometry` update.
    struct Snapshot: Equatable, Sendable {
        /// Distance scrolled below the resting top edge
        /// (`contentOffset.y + contentInsets.top`). Zero at rest at the top,
        /// positive when scrolled down, negative during pull-to-refresh.
        let offsetY: CGFloat
        /// Total vertical distance the content can scroll
        /// (`max(0, contentHeight + topInset + bottomInset - containerHeight)`).
        let maxOffsetY: CGFloat
        /// Bottom content inset, used to ignore offset clamps caused when the
        /// tab bar hides or reappears.
        let bottomInset: CGFloat
        /// Viewport height, used to ignore rotation / split-view resize shifts.
        let containerHeight: CGFloat
    }

    /// Scroll phase taxonomy matching `SwiftUI.ScrollPhase`.
    enum Phase: Equatable, Sendable {
        case idle
        case tracking
        case interacting
        case decelerating
        case animating

        /// True while the user is actively dragging or coasting from a drag.
        var isUserDriven: Bool {
            self == .interacting || self == .decelerating
        }

        init(_ phase: ScrollPhase) {
            if phase == .interacting {
                self = .interacting
            } else if phase == .decelerating {
                self = .decelerating
            } else if phase == .tracking {
                self = .tracking
            } else if phase == .animating {
                self = .animating
            } else {
                self = .idle
            }
        }
    }

    /// Downward travel required before hiding the tab bar (absorbs thumb
    /// jitter and the start of horizontal Live / Following swipes).
    static let hideThreshold: CGFloat = 28
    /// Upward travel required before revealing the tab bar again.
    static let showThreshold: CGFloat = 18
    /// Distance from the top within which the tab bar is always visible.
    static let topRevealOffset: CGFloat = 24
    /// Minimum content overflow beyond the viewport (excluding `bottomInset`)
    /// required before auto-hide engages. Measuring `maxOffsetY - bottomInset`
    /// keeps the threshold invariant when the tab bar hides or reappears and
    /// changes `bottomInset`, while still immediately revealing if content
    /// genuinely shrinks.
    static let minContentOverflow: CGFloat = 60
    /// Tolerance for treating layout / inset metrics as changed.
    private static let layoutChangeTolerance: CGFloat = 0.5

    private(set) var isHidden = false
    private var phase: Phase = .idle
    private var lastSnapshot: Snapshot?
    private var accumulatedDeltaY: CGFloat = 0

    init() {}

    /// Updates the current scroll phase (from `.onScrollPhaseChange`).
    mutating func updatePhase(_ newPhase: Phase) {
        guard newPhase != phase else { return }
        phase = newPhase
        if newPhase == .idle || newPhase == .tracking {
            accumulatedDeltaY = 0
        }
    }

    /// Synchronizes hidden state after an external reset (section switch, tab
    /// switch, navigation push, or size-class change).
    mutating func syncHidden(_ hidden: Bool) {
        isHidden = hidden
        accumulatedDeltaY = 0
    }

    /// Records the latest geometry baseline without changing `isHidden`
    /// (used while a Home section is off-screen in the horizontal pager).
    mutating func recordBaseline(_ snapshot: Snapshot) {
        lastSnapshot = snapshot
        accumulatedDeltaY = 0
    }

    /// Processes a new scroll geometry snapshot and returns the updated
    /// `isHidden` state.
    @discardableResult
    mutating func update(with snapshot: Snapshot) -> Bool {
        defer { lastSnapshot = snapshot }

        // Always keep the tab bar visible when the feed barely overflows the
        // viewport (independent of bottom-inset changes from the tab bar
        // itself) or when at / near the top (including pull-to-refresh and
        // status-bar scroll-to-top animations).
        let contentOverflow = snapshot.maxOffsetY - snapshot.bottomInset
        if contentOverflow < Self.minContentOverflow || snapshot.offsetY <= Self.topRevealOffset {
            isHidden = false
            accumulatedDeltaY = 0
            return isHidden
        }

        guard let previous = lastSnapshot else {
            return isHidden
        }

        // Ignore geometry shifts caused by the tab bar's own bottom-inset
        // animation or viewport resizes. Without this, hiding near the bottom
        // shrinks `bottomInset`, clamping `offsetY` upward and triggering a
        // hide / show bounce loop.
        if abs(snapshot.bottomInset - previous.bottomInset) > Self.layoutChangeTolerance
            || abs(snapshot.containerHeight - previous.containerHeight) > Self.layoutChangeTolerance
        {
            accumulatedDeltaY = 0
            return isHidden
        }

        // Ignore bottom rubber-band overscroll and its upward bounce-back.
        if previous.offsetY > previous.maxOffsetY || snapshot.offsetY > snapshot.maxOffsetY {
            accumulatedDeltaY = 0
            return isHidden
        }

        // Only respond to user-driven vertical scrolls (dragging or coasting).
        guard phase.isUserDriven else {
            accumulatedDeltaY = 0
            return isHidden
        }

        let deltaY = snapshot.offsetY - previous.offsetY
        guard deltaY != 0 else { return isHidden }

        // Reversing direction resets accumulated travel so hysteresis applies
        // cleanly in the new direction.
        if (deltaY > 0 && accumulatedDeltaY < 0) || (deltaY < 0 && accumulatedDeltaY > 0) {
            accumulatedDeltaY = 0
        }
        accumulatedDeltaY += deltaY

        if !isHidden, accumulatedDeltaY >= Self.hideThreshold {
            isHidden = true
            accumulatedDeltaY = 0
        } else if isHidden, accumulatedDeltaY <= -Self.showThreshold {
            isHidden = false
            accumulatedDeltaY = 0
        }

        return isHidden
    }
}

extension View {
    /// Drives `isHidden` from this scroll view's vertical scroll direction
    /// (hide on scroll down, reappear on scroll up or near top) while
    /// `isActive` is true. No-op on macOS or when `isHidden` is nil.
    @ViewBuilder
    func autoHideHomeTabBar(isActive: Bool, isHidden: Binding<Bool>?) -> some View {
        #if os(iOS)
        if let isHidden {
            modifier(HomeTabBarAutoHideModifier(isActive: isActive, isHidden: isHidden))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Reference holder for `HomeTabBarScrollPolicy` so per-frame scroll updates
/// mutate in place without invalidating any SwiftUI view body. Only an actual
/// hidden-state flip writes through to `isHidden`.
@MainActor
private final class HomeTabBarScrollPolicyBox {
    var policy = HomeTabBarScrollPolicy()
}

private struct HomeTabBarAutoHideModifier: ViewModifier {
    let isActive: Bool
    let isHidden: Binding<Bool>

    @State private var box = HomeTabBarScrollPolicyBox()

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, newPhase in
                box.policy.updatePhase(HomeTabBarScrollPolicy.Phase(newPhase))
            }
            .onScrollGeometryChange(for: HomeTabBarScrollPolicy.Snapshot.self) { geo in
                HomeTabBarScrollPolicy.Snapshot(
                    offsetY: geo.contentOffset.y + geo.contentInsets.top,
                    maxOffsetY: max(
                        0,
                        geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom - geo.containerSize.height
                    ),
                    bottomInset: geo.contentInsets.bottom,
                    containerHeight: geo.containerSize.height
                )
            } action: { _, snapshot in
                guard isActive else {
                    box.policy.recordBaseline(snapshot)
                    return
                }
                let wanted = box.policy.update(with: snapshot)
                guard isHidden.wrappedValue != wanted else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    isHidden.wrappedValue = wanted
                }
            }
            .onChange(of: isActive) { _, active in
                box.policy.syncHidden(active ? isHidden.wrappedValue : false)
            }
            .onChange(of: isHidden.wrappedValue) { _, externalValue in
                if box.policy.isHidden != externalValue {
                    box.policy.syncHidden(externalValue)
                }
            }
    }
}
#endif
