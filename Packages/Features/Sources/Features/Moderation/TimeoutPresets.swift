import Foundation
import Channels

/// The user card's one-tap timeout durations, persisted per device in
/// UserDefaults (`storageKey`) as comma-separated seconds — e.g.
/// "60,600,3600,86400". Pure helpers, so the parsing and labels are testable
/// without the views.
enum TimeoutPresets {

    /// `@AppStorage` key. Per device, not per account: it's a habit of the
    /// person holding the phone, not a property of the channel.
    static let storageKey = "chattr.moderation.timeoutPresets"

    /// 1m, 10m, 1h, 1d.
    static let defaults: [Int] = [60, 600, 3_600, 86_400]
    static let defaultRaw = encode(defaults)

    /// Keeps the chip row a single compact line.
    static let maxCount = 8

    /// Stored string → durations: positive, within Twitch's 2-week cap,
    /// de-duplicated, ascending. Garbage entries are dropped; an empty result
    /// falls back to the defaults so the row is never blank by accident.
    static func decode(_ raw: String) -> [Int] {
        let values = raw
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let cleaned = normalize(values)
        return cleaned.isEmpty ? defaults : cleaned
    }

    static func encode(_ seconds: [Int]) -> String {
        normalize(seconds).map(String.init).joined(separator: ",")
    }

    /// Valid, unique, sorted, capped at `maxCount`.
    static func normalize(_ seconds: [Int]) -> [Int] {
        let valid = seconds.filter { $0 > 0 && $0 <= ChannelSession.maxTimeoutSeconds }
        return Array(Array(Set(valid)).sorted().prefix(maxCount))
    }

    /// Compact chip label in the largest unit that divides evenly:
    /// 30 → "30s", 600 → "10m", 5400 → "90m", 86400 → "1d", 1209600 → "2w".
    static func label(forSeconds seconds: Int) -> String {
        for (unit, size) in [("w", 604_800), ("d", 86_400), ("h", 3_600), ("m", 60)]
        where seconds >= size && seconds % size == 0 {
            return "\(seconds / size)\(unit)"
        }
        return "\(seconds)s"
    }

    /// VoiceOver / confirmation phrasing: "10 minutes", "1 day".
    static func spokenLabel(forSeconds seconds: Int) -> String {
        for (unit, size) in [("week", 604_800), ("day", 86_400), ("hour", 3_600), ("minute", 60)]
        where seconds >= size && seconds % size == 0 {
            let count = seconds / size
            return "\(count) \(unit)\(count == 1 ? "" : "s")"
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}
