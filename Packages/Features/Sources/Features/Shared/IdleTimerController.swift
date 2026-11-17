#if os(iOS)
import SwiftUI
import UIKit

/// Owns `UIApplication.isIdleTimerDisabled` for Settings → Video & Device → Keep
/// Screen Awake.
///
/// Refcounted: anything that should keep the screen on while it's visible
/// (today the chat pager and the mini player, via `.keepsScreenAwake(_:)`)
/// takes a hold. The screen stays awake only while there's at least one
/// hold, the app is active, and the preference is on; leaving the app or
/// dropping the last hold restores the system idle timer. Everything is
/// event-driven (holds + app-state notifications), nothing polls, and the
/// UIKit property is written only when the answer changes.
@MainActor
final class IdleTimerController: NSObject {
    static let shared = IdleTimerController()

    private var holds = 0
    private var isAppActive: Bool

    private override init() {
        isAppActive = UIApplication.shared.applicationState == .active
        super.init()
        let notifications = NotificationCenter.default
        notifications.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        notifications.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    func acquire() {
        holds += 1
        apply()
    }

    func release() {
        guard holds > 0 else { return }
        holds -= 1
        apply()
    }

    /// Re-reads the preference (Settings calls this when it's toggled).
    func refresh() {
        apply()
    }

    @objc private func didBecomeActive() {
        isAppActive = true
        apply()
    }

    @objc private func didEnterBackground() {
        isAppActive = false
        apply()
    }

    private func apply() {
        let disable = holds > 0 && isAppActive && PlaybackPreferences.keepScreenAwake
        if UIApplication.shared.isIdleTimerDisabled != disable {
            UIApplication.shared.isIdleTimerDisabled = disable
        }
    }
}

extension View {
    /// Holds the screen awake (if the user turned that on) while `active`
    /// and this view is on screen.
    func keepsScreenAwake(_ active: Bool) -> some View {
        modifier(KeepScreenAwakeModifier(active: active))
    }

    /// Same, but `isActive` is evaluated inside the modifier's body, so any
    /// observable state it reads invalidates only this modifier, not the
    /// view it's attached to.
    func keepsScreenAwake(while isActive: @escaping @MainActor () -> Bool) -> some View {
        modifier(DeferredKeepScreenAwakeModifier(isActive: isActive))
    }
}

private struct DeferredKeepScreenAwakeModifier: ViewModifier {
    let isActive: @MainActor () -> Bool

    func body(content: Content) -> some View {
        content.keepsScreenAwake(isActive())
    }
}

private struct KeepScreenAwakeModifier: ViewModifier {
    let active: Bool
    /// Whether this view currently owns a hold — keeps acquire / release
    /// balanced across appear, change and disappear.
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear { setHolding(active) }
            .onChange(of: active) { _, newValue in setHolding(newValue) }
            .onDisappear { setHolding(false) }
    }

    private func setHolding(_ wanted: Bool) {
        guard wanted != holding else { return }
        holding = wanted
        if wanted {
            IdleTimerController.shared.acquire()
        } else {
            IdleTimerController.shared.release()
        }
    }
}
#endif
