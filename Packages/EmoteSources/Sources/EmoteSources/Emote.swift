import Foundation

/// A third-party emote, normalized across 7TV/BTTV/FFZ.
///
/// Twitch native emotes are NOT modeled here — they arrive pre-resolved inside
/// `TwitchKit.ChatMessage.fragments` as `.emote(EmoteReference)` already. This
/// type is only for emote *names* that appear as plain text in Twitch's payload
/// but should render as inline images from a third-party CDN.
public struct Emote: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Provider-namespaced unique id (e.g., "7tv:6042089ce42d", "bttv:54fa90b80...").
    /// Uses a prefix so collisions across providers can't happen.
    public let id: String

    /// The literal text token that triggers this emote — case-sensitive match against
    /// whitespace-delimited words in chat message text fragments.
    public let name: String

    /// URLs for the emote, keyed by display size (1x, 2x, 4x). 7TV serves animated
    /// WebP; BTTV is PNG/GIF (note: BTTV uses "3x" not "4x" — we map to .x4 anyway
    /// for consistent API); FFZ is mostly static PNG.
    public let urls: [Size: URL]

    /// True when the emote is animated (7TV WebP with animation, BTTV GIF). Affects
    /// which image view variant a renderer chooses (static vs animated).
    public let isAnimated: Bool

    /// True for 7TV "zero-width" overlays (e.g., RainTime stacks on top of the
    /// previous emote). `ChatRow` draws one stacked on the emote it follows;
    /// with no emote before it, it renders as an ordinary emote.
    public let isZeroWidth: Bool

    /// Which provider issued this emote. Used for collision precedence
    /// (channel > global, then 7TV > BTTV > FFZ) and analytics.
    public let source: Source

    /// If the emote is channel-specific (vs global), the broadcaster_user_id whose
    /// channel emote set includes it. nil for global emotes.
    public let ownerChannelId: String?

    /// Native width÷height of the emote image, from provider metadata
    /// (7TV: per-file dimensions; FFZ: emoticon dimensions; BTTV: none —
    /// nil). Lets the renderer give wide emotes their natural width at a
    /// fixed line height AND reserve correct layout space before the
    /// image loads. Optional so cache entries persisted before this field
    /// existed keep decoding (missing key → nil → square-ish fallback box).
    public let aspectRatio: Double?

    /// Still-image URLs for an animated emote, keyed like `urls`, when the
    /// provider's response lists a separate static file (FFZ does). A
    /// renderer that will not animate loads this instead of downloading the
    /// animation to pull one frame out of it. `nil` when the provider has no
    /// static variant, and for cache entries persisted before the field
    /// existed (missing key → nil → the animated file is used, as before).
    public let staticURLs: [Size: URL]?

    /// Raw values are persisted in the on-disk emote cache — renaming a case or
    /// changing a raw value is a breaking change; bump the cache version if you do.
    public enum Size: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case x1, x2, x4
    }

    /// Raw values are persisted in the on-disk emote cache — renaming a case or
    /// changing a raw value is a breaking change; bump the cache version if you do.
    public enum Source: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        case sevenTV
        case bttv
        case ffz
    }

    public init(
        id: String,
        name: String,
        urls: [Size: URL],
        isAnimated: Bool,
        isZeroWidth: Bool,
        source: Source,
        ownerChannelId: String? = nil,
        aspectRatio: Double? = nil,
        staticURLs: [Size: URL]? = nil
    ) {
        self.id = id
        self.name = name
        self.urls = urls
        self.isAnimated = isAnimated
        self.isZeroWidth = isZeroWidth
        self.source = source
        self.ownerChannelId = ownerChannelId
        self.aspectRatio = aspectRatio
        self.staticURLs = staticURLs
    }
}
