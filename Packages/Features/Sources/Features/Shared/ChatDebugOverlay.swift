import SwiftUI

/// Opt-in live diagnostic HUD overlaid on `ChatScreen` when Developer →
/// "Chat Debug HUD" is enabled.
///
/// Renders `EmptyView()` with zero timers and zero observation cost when off.
/// When enabled, polls `ChatDiagnostics.shared` (and active playback latency on
/// iOS) twice a second so a single TestFlight screenshot captures the exact
/// SwiftUI branch, attach state, line counts, `UICollectionView` geometry, and
/// native `AVPlayer` live-edge / buffer metrics.
struct ChatDebugOverlay: View {
    let channelLoginName: String

    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif
    @AppStorage(DeveloperSettings.chatDebugHUDKey) private var showHUD = false
    @AppStorage(DeveloperSettings.devToolsUnlockedKey) private var devToolsUnlocked = false

    private var isEnabled: Bool {
        showHUD && (DeveloperSettings.isAutomaticallyUnlocked || devToolsUnlocked)
    }

    var body: some View {
        if isEnabled {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let lines = ChatDiagnostics.shared.hudLines(for: channelLoginName)
                #if os(iOS)
                let playbackLine = playback?
                    .latencySnapshot(forChannelLogin: channelLoginName, now: context.date)
                    .map { $0.snapshot.compactHUDLine(showChannel: $0.isOtherChannel) }
                #else
                let playbackLine: String? = nil
                #endif
                VStack(alignment: .leading, spacing: 2) {
                    Text(lines.top)
                    Text(lines.bottom)
                    if let playbackLine {
                        Text(playbackLine)
                    }
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
