import Foundation
import TwitchKit

/// What a broadcaster's chat settings say about who can post and how.
/// Surfaces only the restrictions that block (or rate-limit) sending —
/// `uniqueChatMode` and other esoteric settings are skipped because the
/// compose bar doesn't have a meaningful "this is what your message
/// can't be" message for them, and the user finds out via `dropReason`
/// anyway.
///
/// Why a chattr-side wrapper instead of using `TwitchKit.ChatSettings`
/// directly: the wrapper has a `hasAny` computed property that lets the
/// compose bar render in one branch ("any restriction → show strip"),
/// and the field names map to user-facing language ("followersOnly"
/// rather than "followerMode") which makes the renderer cleaner.
public struct ChatRestrictions: Sendable, Equatable {

    /// Slow mode is on; the user can send at most one message per
    /// `slowModeSeconds`. nil duration means it's off.
    public let slowModeSeconds: Int?

    /// Followers-only is on. Users must follow the channel to chat;
    /// `followersDurationMinutes` is how long they need to have been
    /// following (Twitch sometimes sets a "must have followed 30 days"
    /// threshold for high-traffic broadcasters).
    public let followersOnly: Bool
    public let followersDurationMinutes: Int?

    /// Subscribers-only is on — only paid subscribers + the broadcaster
    /// can post. Bypassed by mods, VIPs, broadcaster.
    public let subscribersOnly: Bool

    /// Emote-only is on — only Twitch / 7TV / BTTV / FFZ emotes can be
    /// sent. Plain text is rejected.
    public let emoteOnly: Bool

    /// Convenience: true if ANY of the restrictions are active. The
    /// compose bar branches on this for its "show restrictions strip"
    /// rendering decision.
    public var hasAny: Bool {
        slowModeSeconds != nil || followersOnly || subscribersOnly || emoteOnly
    }

    public init(
        slowModeSeconds: Int? = nil,
        followersOnly: Bool = false,
        followersDurationMinutes: Int? = nil,
        subscribersOnly: Bool = false,
        emoteOnly: Bool = false
    ) {
        self.slowModeSeconds = slowModeSeconds
        self.followersOnly = followersOnly
        self.followersDurationMinutes = followersDurationMinutes
        self.subscribersOnly = subscribersOnly
        self.emoteOnly = emoteOnly
    }

    /// Construct from TwitchKit's wire shape. Reads only the fields the
    /// compose bar surfaces; the rest stay encapsulated here so the
    /// rest of chattr doesn't depend on `TwitchKit.ChatSettings`'s shape.
    init(from settings: ChatSettings) {
        self.slowModeSeconds = settings.slowMode ? settings.slowModeWaitTime : nil
        self.followersOnly = settings.followerMode
        self.followersDurationMinutes = settings.followerMode ? settings.followerModeDuration : nil
        self.subscribersOnly = settings.subscriberMode
        self.emoteOnly = settings.emoteMode
    }
}
