import Foundation

/// Whether a user is currently banned or timed out in a channel, as GET
/// /moderation/banned reports it (or as a just-performed ban / timeout /
/// unban implies). Drives the user card's Unban affordance.
public enum UserBanState: Sendable, Equatable {
    case notBanned
    /// Timed out until `until`. Past `until` the user can chat again.
    case timedOut(until: Date)
    case banned

    /// From a GET /moderation/banned entry's `expires_at`: Twitch sends an
    /// empty string (or omits it) for a permanent ban and an RFC 3339
    /// timestamp for a timeout. An unparseable timestamp is still a
    /// restriction — reported as a ban rather than silently as "not banned".
    public init(expiresAt: String?) {
        guard let raw = expiresAt, !raw.isEmpty else {
            self = .banned
            return
        }
        if let date = Self.parse(raw) {
            self = .timedOut(until: date)
        } else {
            self = .banned
        }
    }

    /// True while the user can't chat (`now` defaults to the wall clock).
    public func isRestricted(at now: Date = .now) -> Bool {
        switch self {
        case .notBanned: return false
        case .banned: return true
        case .timedOut(let until): return until > now
        }
    }

    /// Twitch timestamps come with and without fractional seconds.
    static func parse(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
