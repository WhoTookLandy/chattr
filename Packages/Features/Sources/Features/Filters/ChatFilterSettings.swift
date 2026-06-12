import Foundation

/// User toggles for dropping noise from the transcript: command messages
/// (`!so`, `!drops`, …) and messages from well-known chat bots.
///
/// Same shape and lifecycle as `HighlightSettings`: static accessors over
/// `UserDefaults`, read once by `TabChatModel.attach(...)` and applied to
/// every message that channel session ingests afterwards — live arrivals
/// AND re-primed history. Changes apply the next time a chat attaches
/// (reopen / app relaunch); the Filters screen's footer says so.
///
/// Filtered messages are dropped *before* normalization — they never
/// enter the ring buffer, never trigger the highlight sound, and never
/// count toward unread state. The user's own messages are always exempt
/// (hiding your own "!drops" the moment you send it reads as a bug).
public enum ChatFilterSettings {
    private static let hideCommandsKey = "chattr.filters.hideCommands"
    private static let hideBotsKey = "chattr.filters.hideBots"

    // MARK: - Toggles

    /// Hide messages that start with "!" (channel-bot commands). Default
    /// off — commands are signal in some communities.
    public static func hideCommands() -> Bool {
        UserDefaults.standard.bool(forKey: hideCommandsKey)
    }
    public static func setHideCommands(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: hideCommandsKey)
    }

    /// Hide messages from well-known chat bots. Default off.
    public static func hideBots() -> Bool {
        UserDefaults.standard.bool(forKey: hideBotsKey)
    }
    public static func setHideBots(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: hideBotsKey)
    }

    // MARK: - Matching

    /// Curated logins of the bots ~every Twitch viewer recognizes.
    /// Lowercased; compare with a lowercased login. Deliberately short —
    /// false positives (hiding a human) are much worse than false
    /// negatives (a niche bot slipping through).
    public static let knownBotLogins: Set<String> = [
        "nightbot", "fossabot", "streamelements", "streamlabs",
        "moobot", "wizebot", "botisimo", "sery_bot", "soundalerts",
        "pokemoncommunitygame", "creatisbot", "tangiabot",
    ]

    /// The one decision point both ingest paths share. Pure function of
    /// the message + the at-attach snapshot of the toggles, so live and
    /// priming paths can't drift.
    public static func shouldHide(
        authorLogin: String,
        text: String,
        hideCommands: Bool,
        hideBots: Bool
    ) -> Bool {
        if hideCommands, text.hasPrefix("!") { return true }
        if hideBots, knownBotLogins.contains(authorLogin.lowercased()) { return true }
        return false
    }
}
