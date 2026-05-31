import Foundation

/// Per-channel chat draft persistence backed by UserDefaults.
///
/// ## Why UserDefaults instead of SwiftData
///
/// Drafts are short, non-sensitive, and inherently transient — the user
/// types "wb", swipes to another channel, comes back to find their "wb"
/// still in the compose bar. UserDefaults is the right storage tool for
/// "small transient user state":
///
///   - **Size**: tens to hundreds of characters per channel × ~10
///     active channels = a few KB at most. Well below the UserDefaults
///     per-key 4MB recommendation.
///   - **Security**: drafts are not credentials. The user can read them
///     directly in the compose bar; persisting them at the same trust
///     level is fine.
///   - **Schema cost**: SwiftData would need either a new @Model or a
///     migration to add a field to `PersistedChatTab`. UserDefaults
///     needs neither.
///   - **Access pattern**: load once on mount, save on each keystroke
///     (UserDefaults batches writes via its internal disk cache, so
///     this is fast in practice).
///
/// ## Storage shape
///
/// All drafts go into a single dictionary under one UserDefaults key.
/// Channel id → draft text. Empty drafts are removed rather than
/// stored as empty strings — keeps the dictionary tight and means
/// "no draft" reads as nil consistently.
public enum DraftStorage {

    /// UserDefaults key for the drafts dictionary. Prefixed to avoid
    /// clashing with any future plist keys other modules might add.
    private static let storageKey = "chattr.drafts.byChannelId"

    /// Returns the persisted draft for a channel, or an empty string
    /// if none. Returning a String (not String?) keeps the call site
    /// simple — the compose bar always needs *something* to seed its
    /// state, and `""` is the correct "no draft" value visually.
    public static func load(forChannelId channelId: String) -> String {
        let dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        return dict[channelId] ?? ""
    }

    /// Saves a draft for a channel. Empty / whitespace-only texts are
    /// REMOVED from storage rather than persisted as empty strings —
    /// the dictionary stays tight and reload-after-empty correctly
    /// reads as "no draft" instead of "empty draft."
    ///
    /// Performance: UserDefaults writes are batched to disk by iOS;
    /// per-keystroke saves don't actually hit storage on every call.
    public static func save(forChannelId channelId: String, text: String) {
        var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dict.removeValue(forKey: channelId)
        } else {
            // Persist the UNTRIMMED text so the user's leading/trailing
            // whitespace (rare but possible — copy-paste from another
            // app might include it) survives. Only the emptiness check
            // uses the trim.
            dict[channelId] = text
        }
        UserDefaults.standard.set(dict, forKey: storageKey)
    }

    /// Clear a specific channel's draft. Equivalent to `save(..., text: "")`
    /// but reads more clearly at call sites that intend to delete.
    /// Used by `TabChatModel.send` after a successful send, so the next
    /// channel-mount doesn't restore a draft the user just sent.
    public static func clear(forChannelId channelId: String) {
        var dict = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        guard dict.removeValue(forKey: channelId) != nil else { return }
        UserDefaults.standard.set(dict, forKey: storageKey)
    }
}
