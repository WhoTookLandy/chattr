import Foundation
import Core

/// The device's per-platform active-account selection, persisted in
/// UserDefaults.
///
/// Per-device UI state by design — not a SwiftData field (see Account.swift):
/// you might be on account A on iPhone and B on iPad. RootView observes the
/// Twitch key through `@AppStorage`, so writing it here re-renders the app
/// into the selected account. Empty / missing = no explicit selection, and
/// RootView falls back to the most-recently-added healthy account.
///
/// A value type over a `UserDefaults` handle so tests can point it at a
/// throwaway suite; production uses `.standard` (what `@AppStorage` reads).
struct ActiveAccountSelection {

    /// UserDefaults key holding the userId of the active **Twitch** account.
    ///
    /// Kept as the bare legacy constant (no `.twitch` suffix) so existing
    /// devices keep their selection across the multi-platform migration —
    /// every pre-existing selection IS a Twitch selection. Other platforms
    /// get suffixed keys via `key(for:)`.
    static let twitchKey = "chattr.activeAccountUserId"

    /// Per-platform UserDefaults key. `.twitch` maps to the legacy
    /// unsuffixed key (see `twitchKey`).
    static func key(for platform: ChatPlatform) -> String {
        switch platform {
        case .twitch: return twitchKey
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The selected userId on `platform`, or nil when nothing is selected.
    func selectedUserId(on platform: ChatPlatform) -> String? {
        defaults.string(forKey: Self.key(for: platform))
    }

    /// Makes `userId` the active account on `platform`.
    func select(userId: String, on platform: ChatPlatform) {
        defaults.set(userId, forKey: Self.key(for: platform))
    }

    /// Clears the selection on `platform` if it currently points at
    /// `userId`, so RootView's fallback picks another (healthy) account
    /// instead of re-resolving one that was removed or expired.
    func clear(ifSelected userId: String, on platform: ChatPlatform) {
        guard selectedUserId(on: platform) == userId else { return }
        defaults.removeObject(forKey: Self.key(for: platform))
    }
}
