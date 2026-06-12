import Foundation

/// User toggles for the third-party emote sources (7TV / BTTV / FFZ).
///
/// Lives in Core (not EmoteSources or Features) because both ends of the
/// wiring need it: `ChannelSessionRegistry` (Channels) reads the toggles
/// when constructing a channel's `EmoteIndex`, and the Emotes settings
/// screen (Features) writes them.
///
/// Same shape as `HighlightSettings`: a static-accessor namespace over
/// `UserDefaults`, read once at the consuming object's construction —
/// changes apply the next time a channel's emote index is built (channel
/// reopen), not retroactively to already-open chats. The settings UI
/// says so in its footer.
public enum EmoteSourceSettings {
    private static let sevenTVKey = "chattr.emotes.sevenTVEnabled"
    private static let bttvKey = "chattr.emotes.bttvEnabled"
    private static let ffzKey = "chattr.emotes.ffzEnabled"

    /// All sources default to ON — third-party emotes are the expected
    /// experience in Twitch chat; the toggles exist for users who want
    /// Twitch-only rendering (or to debug a misbehaving source).
    private static func bool(forKey key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    public static func sevenTVEnabled() -> Bool { bool(forKey: sevenTVKey) }
    public static func setSevenTVEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: sevenTVKey)
    }

    public static func bttvEnabled() -> Bool { bool(forKey: bttvKey) }
    public static func setBTTVEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: bttvKey)
    }

    public static func ffzEnabled() -> Bool { bool(forKey: ffzKey) }
    public static func setFFZEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ffzKey)
    }
}
