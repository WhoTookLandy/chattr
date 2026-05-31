import Foundation

/// User-configurable highlight settings, backed by UserDefaults.
///
/// Two knobs today:
///   - `keywords`: case-insensitive substrings that, when matched in a
///     message, give the row a highlighted treatment AND (if sounds are
///     on) play the highlight sound. Self-mentions (`@yourlogin`) are
///     ALWAYS highlighted regardless of this list — the keywords are
///     additive on top of that.
///   - `soundEnabled`: whether a highlighted *live* message plays the
///     notification sound.
///
/// ## Why UserDefaults
///
/// Same rationale as `DraftStorage`: small, non-sensitive, per-device
/// user preferences. A handful of keyword strings + one bool. No schema
/// migration, no SwiftData relationship — a couple of plist reads.
///
/// ## Reactivity
///
/// `keywords` is read by `ChatScreen` at attach time (passed into
/// `TabChatModel.attach(highlightKeywords:)`). Changing keywords
/// mid-session doesn't re-attach already-open chats — the new list
/// applies the next time a chat attaches (channel reopen / app
/// relaunch). Acceptable for MVP; keywords are typically set once.
/// The editor screen (`HighlightKeywordsScreen`) owns its own
/// `@State` for live add/remove UI and writes through here.
public enum HighlightSettings {

    private static let keywordsKey = "chattr.highlight.keywords"
    private static let soundEnabledKey = "chattr.highlight.soundEnabled"

    // MARK: - Keywords

    /// The current highlight keyword list. UserDefaults stores
    /// `[String]` natively, so no JSON encoding needed. Returns empty
    /// when unset (the common default — no extra highlights beyond
    /// self-mentions).
    public static func keywords() -> [String] {
        UserDefaults.standard.stringArray(forKey: keywordsKey) ?? []
    }

    /// Persist the full keyword list. The editor screen calls this
    /// after every add/remove. We store the list verbatim — trimming
    /// and empty-filtering happen in the editor before it calls here,
    /// so storage stays a dumb passthrough.
    public static func setKeywords(_ keywords: [String]) {
        UserDefaults.standard.set(keywords, forKey: keywordsKey)
    }

    // MARK: - Sound toggle

    /// Whether highlighted live messages play the notification sound.
    /// Defaults to `true` — a new user who sets a keyword expects the
    /// audible ping (that's the point of the feature). They can turn
    /// it off in Profile.
    ///
    /// `object(forKey:) == nil ? true : bool(forKey:)` distinguishes
    /// "never set" (→ default true) from "explicitly set to false".
    /// A plain `bool(forKey:)` would return false for the unset case,
    /// silently defaulting sound OFF.
    public static func soundEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: soundEnabledKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: soundEnabledKey)
    }

    /// Persist the sound toggle.
    public static func setSoundEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: soundEnabledKey)
    }
}
