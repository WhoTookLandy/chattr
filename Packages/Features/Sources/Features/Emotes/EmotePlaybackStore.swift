import Foundation
import Observation

/// Whether the device is in a state where animated emotes should hold still:
/// Low Power Mode, or a serious / critical thermal state.
///
/// Every animated emote on screen is a layer the render server keeps
/// cycling; under those conditions that is exactly the work the system is
/// asking apps to shed. `AnimatedImageView` reads `suspendsAnimation` in its
/// body and treats it like Reduce Motion (poster frame only), so visible
/// emotes stop when the state begins and pick up again when it ends — the
/// read is an Observation dependency, so a change re-renders just those
/// views.
///
/// Main-actor state. The two system notifications arrive on arbitrary
/// threads; each observer only hops to the main actor and re-reads
/// `ProcessInfo`, so the stored value is never written from anywhere else.
@MainActor
@Observable
final class EmotePlaybackStore {
    static let shared = EmotePlaybackStore()

    /// True while animated emotes should show their poster frame.
    private(set) var suspendsAnimation = false

    private init() {
        let info = ProcessInfo.processInfo
        suspendsAnimation = EmotePlaybackStore.shouldSuspend(
            lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)

        // Block observers on the posting thread; the shared instance lives
        // for the process, so the tokens are never removed.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { @MainActor in EmotePlaybackStore.shared.refresh() }
            }
        }
    }

    /// The rule, separate from where the inputs come from.
    nonisolated static func shouldSuspend(
        lowPowerMode: Bool, thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        lowPowerMode || thermalState == .serious || thermalState == .critical
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        let suspended = Self.shouldSuspend(
            lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState)
        // Only on a real change: every write re-renders the visible emotes.
        if suspended != suspendsAnimation {
            suspendsAnimation = suspended
        }
    }
}
