import Foundation

/// Shared text formatting for stream metadata, so Home cards, the chat
/// stream header, the Chats list and the channel pill all say "48.2K",
/// "2h 50m" and "Streamed 2 days ago" the same way.
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

    /// Fills Twitch's `{width}x{height}` thumbnail template.
    static func thumbnailURL(_ template: String, width: Int, height: Int) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{width}", with: String(width))
            .replacingOccurrences(of: "{height}", with: String(height)))
    }
}
