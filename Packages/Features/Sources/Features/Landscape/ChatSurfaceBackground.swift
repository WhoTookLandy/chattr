import SwiftUI
import DesignSystem

/// The chat page's surface color. Opaque everywhere except the landscape
/// "chat over video" layout, where it lets the stream show through at the
/// user's chosen opacity.
///
/// Its own view so the `landscapeStage` read invalidates only this
/// background — `ChatScreen`'s body never depends on it.
struct ChatSurfaceBackground: View {
    @Environment(\.landscapeStage) private var stage

    var body: some View {
        Color.chatSurface
            .opacity(stage.surfaceOpacity)
            .ignoresSafeArea()
    }
}

extension View {
    /// Collapses this view while the landscape stage shows the stream —
    /// used for the stream header, whose video has moved to the stage.
    /// Collapsed, not removed: the view stays mounted with its state and
    /// tasks (the header keeps driving playback), and toggling never
    /// changes its identity.
    func hiddenOnLandscapeStage() -> some View {
        modifier(HiddenOnLandscapeStage())
    }
}

private struct HiddenOnLandscapeStage: ViewModifier {
    @Environment(\.landscapeStage) private var stage

    func body(content: Content) -> some View {
        let hidden = stage.isActive
        content
            // Zero height gives the bar's space back to chat; opacity 0
            // hides the overflow. No clip: in portrait the header's black
            // status-bar strip deliberately draws outside its bounds.
            .frame(height: hidden ? 0 : nil, alignment: .top)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}
