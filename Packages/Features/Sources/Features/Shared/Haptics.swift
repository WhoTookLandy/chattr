import SwiftUI

/// Settings → Video & Device → Haptic Feedback. Every haptic in the app goes through
/// `.appSensoryFeedback(_:trigger:)` so this one switch silences them all.
enum HapticSettings {
    /// Default on (the system default for feedback).
    static let enabledKey = "chattr.device.haptics"
}

extension View {
    /// `.sensoryFeedback(_:trigger:)`, gated on the Haptic Feedback
    /// setting. Use this instead of calling `sensoryFeedback` directly.
    func appSensoryFeedback<Trigger: Equatable>(_ feedback: SensoryFeedback, trigger: Trigger) -> some View {
        modifier(AppSensoryFeedback(feedback: feedback, trigger: trigger, condition: { _, _ in true }))
    }

    /// `.sensoryFeedback(_:trigger:condition:)`, gated on the Haptic
    /// Feedback setting.
    func appSensoryFeedback<Trigger: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: Trigger,
        condition: @escaping (_ oldValue: Trigger, _ newValue: Trigger) -> Bool
    ) -> some View {
        modifier(AppSensoryFeedback(feedback: feedback, trigger: trigger, condition: condition))
    }
}

private struct AppSensoryFeedback<Trigger: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: Trigger
    let condition: (Trigger, Trigger) -> Bool
    @AppStorage(HapticSettings.enabledKey) private var enabled = true

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: trigger) { old, new in
            enabled && condition(old, new)
        }
    }
}
