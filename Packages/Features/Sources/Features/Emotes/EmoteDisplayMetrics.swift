import CoreGraphics

/// Sizing policy for inline third-party emotes: **fixed line height,
/// natural width** — the convention every major Twitch chat client
/// (Chatterino, Frosty, 7TV's own overlay) follows. A 3:1 "wide" emote
/// renders three times wider than a square one instead of being crushed
/// into the same box.
///
/// Width comes from `Emote.aspectRatio` (provider metadata), so FlowLayout
/// can reserve the right space *before* the image loads — sizing after
/// decode would reflow the whole message when a wide emote pops in.
enum EmoteDisplayMetrics {
    /// The historical emote box (28×24) expressed as a ratio — used when a
    /// provider doesn't report dimensions (BTTV), preserving the
    /// pre-aspect-ratio rendering exactly.
    static let fallbackAspect: CGFloat = 28.0 / 24.0

    /// Sanity bounds. 4:1 covers every legitimately wide emote format
    /// (7TV caps uploads well inside this); the floor keeps a degenerate
    /// or corrupt ratio from collapsing the emote to an invisible sliver.
    static let aspectRange: ClosedRange<CGFloat> = 0.25...4.0

    /// Inline emote line height at the default text size (scale 1).
    static let lineHeight: CGFloat = 24

    /// Twitch native emotes are always square — Twitch only accepts square
    /// uploads — so their box needs no per-emote metadata.
    static let twitchAspectRatio: Double = 1

    /// Display width for an emote rendered at `height`.
    static func width(aspectRatio: Double?, height: CGFloat) -> CGFloat {
        guard let aspectRatio else { return height * fallbackAspect }
        let clamped = min(max(CGFloat(aspectRatio), aspectRange.lowerBound), aspectRange.upperBound)
        return height * clamped
    }

    /// The fixed inline box for an emote. Every state of an inline emote
    /// (loading, failed, loaded, animated) renders at exactly this size, so
    /// a row's layout is final before any image arrives.
    static func size(aspectRatio: Double?, height: CGFloat) -> CGSize {
        CGSize(width: width(aspectRatio: aspectRatio, height: height), height: height)
    }
}
