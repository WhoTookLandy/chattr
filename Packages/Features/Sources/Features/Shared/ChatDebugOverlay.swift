import SwiftUI

/// Opt-in live diagnostic HUD overlaid on `ChatScreen` when Developer →
/// "Chat Debug HUD" is enabled.
///
/// Renders `EmptyView()` with zero timers and zero observation cost when off.
/// When enabled, polls `ChatDiagnostics.shared` twice a second so a single
/// TestFlight screenshot captures the exact SwiftUI branch, attach state,
/// line counts, and `UICollectionView` bounds/offset/cell counts.
struct ChatDebugOverlay: View {
    let channelLoginName: String

    @AppStorage(DeveloperSettings.chatDebugHUDKey) private var showHUD = false
    @AppStorage(DeveloperSettings.devToolsUnlockedKey) private var devToolsUnlocked = false

    private var isEnabled: Bool {
        showHUD && (DeveloperSettings.isAutomaticallyUnlocked || devToolsUnlocked)
    }

    var body: some View {
        if isEnabled {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let lines = ChatDiagnostics.shared.hudLines(for: channelLoginName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lines.top)
                    Text(lines.bottom)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, 8)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}
