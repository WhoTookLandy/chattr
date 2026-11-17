import Foundation
import Channels

/// Device-wide toggles for the live-event banners at the top of chat
/// (polls, predictions, Hype Trains). All default ON.
///
/// Same storage shape as `ChatFilterSettings`: `UserDefaults.standard` keys
/// the settings screen binds with `@AppStorage`, plus static accessors for
/// non-view readers. Unlike the filters these apply live — the banner area
/// binds the same keys with `@AppStorage`, so flipping one hides or shows an
/// open chat's banner immediately.
///
/// The rows live in Settings → Chat → Filters (`ChatFiltersScreen`) and are
/// registered in `SettingsRegistry` (`livePolls`, `livePredictions`,
/// `liveHypeTrain`).
public enum LiveEventsSettings {
    static let pollsKey = "chattr.liveEvents.polls"
    static let predictionsKey = "chattr.liveEvents.predictions"
    static let hypeTrainKey = "chattr.liveEvents.hypeTrain"

    static func key(for kind: LiveEventKind) -> String {
        switch kind {
        case .poll: return pollsKey
        case .prediction: return predictionsKey
        case .hypeTrain: return hypeTrainKey
        }
    }

    /// Whether `kind`'s banner shows. Unset reads as true (the default).
    public static func isEnabled(_ kind: LiveEventKind) -> Bool {
        UserDefaults.standard.object(forKey: key(for: kind)) as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, for kind: LiveEventKind) {
        UserDefaults.standard.set(enabled, forKey: key(for: kind))
    }
}
