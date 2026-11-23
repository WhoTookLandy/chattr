import Foundation
import Nuke

/// Shared text formatting for stream metadata, so Home cards, the chat
/// stream header, the Chats list and the channel pill all say "48.2K",
/// "2h 50m" and "Streamed 2 days ago" the same way — and the one place live
/// preview images are requested from.
enum StreamFormatting {

    /// Compact viewer count: 41 → "41", 48213 → "48K".
    static func viewers(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }

    /// Compact uptime for list surfaces: "2h 50m", "45m", "<1m". Static
    /// (not a ticking timer) — list rows shouldn't re-render every second.
    static func uptime(since start: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        guard minutes > 0 else { return "<1m" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// "Streamed 2 days ago" / "Streamed 7 hours ago".
    static func lastLive(_ date: Date) -> String {
        let relative = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        return "Streamed \(relative)"
    }

    /// Short form for tight captions: "2d ago", "7h ago".
    static func lastLiveShort(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        return "\(days / 7)w ago"
    }

    /// Fills Twitch's `{width}x{height}` (live stream) or `%{width}x%{height}`
    /// (VOD archive) thumbnail template.
    static func thumbnailURL(_ template: String, width: Int, height: Int) -> URL? {
        guard !template.isEmpty else { return nil }
        let resolved = template
            .replacingOccurrences(of: "%{width}", with: String(width))
            .replacingOccurrences(of: "%{height}", with: String(height))
            .replacingOccurrences(of: "{width}", with: String(width))
            .replacingOccurrences(of: "{height}", with: String(height))
        return URL(string: resolved)
    }

    /// The image request for an archived VOD thumbnail (static, so normal Nuke
    /// caching applies). Nil if the template is empty or malformed.
    static func vodThumbnailRequest(
        _ template: String?,
        width: Int,
        height: Int
    ) -> ImageRequest? {
        guard let template, let url = thumbnailURL(template, width: width, height: height) else {
            return nil
        }
        return ImageRequest(url: url)
    }

    /// How long a fetched live preview keeps being shown before the next
    /// request for it fetches a new frame.
    static let thumbnailLifetime: TimeInterval = 5 * 60

    /// The image request for a live preview (same template as
    /// `thumbnailURL`).
    ///
    /// Twitch serves a stream's preview from one URL for the whole
    /// broadcast and only the picture behind it changes, so the URL alone
    /// can't be the cache identity — the first frame fetched would be shown
    /// until it was evicted, across refreshes and relaunches. Instead:
    ///
    ///   - the request skips the disk cache in both directions (a preview is
    ///     worthless by the next launch, and it would only crowd out emotes);
    ///   - its identity carries a time bucket, so the memory cache serves a
    ///     frame for at most `thumbnailLifetime` and every size and surface
    ///     of one stream rolls over together.
    static func thumbnailRequest(
        _ template: String,
        width: Int,
        height: Int,
        now: Date = Date()
    ) -> ImageRequest? {
        guard let url = thumbnailURL(template, width: width, height: height) else { return nil }
        var request = ImageRequest(url: url, options: [.disableDiskCache])
        request.imageID = thumbnailCacheIdentity(for: url, now: now)
        return request
    }

    /// `url` plus the index of the `thumbnailLifetime`-long window `now`
    /// falls in.
    static func thumbnailCacheIdentity(for url: URL, now: Date) -> String {
        let bucket = Int((now.timeIntervalSince1970 / thumbnailLifetime).rounded(.down))
        return "\(url.absoluteString)#\(bucket)"
    }
}
