import SwiftUI

/// The draggable divider between the landscape video stage and the chat
/// column.
///
/// ## Why the chat doesn't resize while you drag
///
/// Changing the chat column's width re-lays out the transcript: every
/// self-sizing `UICollectionView` cell re-measures at the new width. Doing
/// that per frame of a drag, while 100+ messages a second stream in, is
/// exactly the hitch the chat list is built to avoid. So the drag is
/// entirely local to this view: a `@GestureState` translation moves the
/// handle and a guide line showing where the edge will land, the chat stays
/// put, and the new width is committed ONCE on release (`onCommit`). Only
/// this small body re-runs per frame; the stage, the chat page and the
/// models are never invalidated by the drag.
struct LandscapeDividerHandle: View {
    let side: LandscapeChatSide
    /// The chat width currently laid out (already clamped).
    let committedWidth: CGFloat
    /// The page width, for the upper clamp.
    let containerWidth: CGFloat
    let onCommit: (CGFloat) -> Void

    /// Touch target width; the visible grabber is much thinner.
    static let hitWidth: CGFloat = 28

    /// Live drag translation — resets to 0 automatically when the gesture
    /// ends or is cancelled, so an interrupted drag can't leave a stale
    /// offset behind.
    @GestureState private var dragX: CGFloat = 0
    /// True while the drag is pinned against the min / max width. Flips
    /// only at the clamp boundary — the haptic's trigger.
    @State private var isPinned = false

    var body: some View {
        let target = clamped(proposedWidth(for: dragX))
        let dragging = dragX != 0
        ZStack {
            // Guide: where the chat's edge will land on release.
            if dragging {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            Capsule()
                .fill(.white.opacity(dragging ? 1 : 0.7))
                .frame(width: dragging ? 6 : 4, height: 44)
                .shadow(color: .black.opacity(0.5), radius: 3)
        }
        .frame(width: Self.hitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        // Visual offset only — doesn't feed back into layout.
        .offset(x: edgeOffset(for: target))
        // High priority so the drag wins over the pager's horizontal
        // paging when it starts on the handle. Global space: the handle
        // moves under the finger, which would skew local coordinates.
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($dragX) { value, state, _ in
                    state = value.translation.width
                }
                .onChanged { value in
                    let raw = proposedWidth(for: value.translation.width)
                    let pinned = raw != clamped(raw)
                    if pinned != isPinned { isPinned = pinned }
                }
                .onEnded { value in
                    if isPinned { isPinned = false }
                    onCommit(clamped(proposedWidth(for: value.translation.width)))
                }
        )
        .appSensoryFeedback(.impact(weight: .medium), trigger: isPinned) { _, pinned in pinned }
        .animation(.snappy(duration: 0.15), value: dragging)
        .accessibilityElement()
        .accessibilityLabel("Chat width")
        .accessibilityValue("\(Int(committedWidth)) points")
        .accessibilityHint("Swipe up or down to resize the chat")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 40
            switch direction {
            case .increment: onCommit(clamped(committedWidth + step))
            case .decrement: onCommit(clamped(committedWidth - step))
            @unknown default: break
            }
        }
    }

    /// Chat width for a horizontal drag of `dx`: dragging toward the chat
    /// shrinks it, away from it widens it.
    private func proposedWidth(for dx: CGFloat) -> CGFloat {
        switch side {
        case .right: committedWidth - dx
        case .left: committedWidth + dx
        }
    }

    private func clamped(_ width: CGFloat) -> CGFloat {
        LandscapeSettings.clampedChatWidth(width, containerWidth: containerWidth)
    }

    /// How far the chat's edge moves for a width of `target`.
    private func edgeOffset(for target: CGFloat) -> CGFloat {
        switch side {
        case .right: committedWidth - target
        case .left: target - committedWidth
        }
    }
}
