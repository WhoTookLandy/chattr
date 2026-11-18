import Foundation

/// A destination requested from outside the view tree. Today that is a
/// `chattr://open/...` link; `AppNavigation.handle` carries it out.
///
///   - `chattr://open/channel/<login>` — open that channel's chat
///   - `chattr://open/following` — Home → Following
///   - `chattr://open/settings` — Settings (see `AppNavigation.homePath`
///     for how far that goes today)
enum NavigationIntent: Equatable, Sendable {
    case openChannel(login: String)
    case showFollowing
    case showSettings

    /// The intent a link asks for, or nil for anything that isn't one of the
    /// links above. The `chattr` scheme is also the browser sign-in callback
    /// (`chattr://oauth-complete?...`); that host, like every other, is not
    /// a navigation link.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "chattr",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "open"
        else { return nil }
        // The undecoded path: a percent-escape is never part of a valid
        // link, and decoding one could smuggle a "/" into a segment.
        let segments = components.percentEncodedPath
            .split(separator: "/")
            .map(String.init)
        if segments == ["following"] {
            self = .showFollowing
        } else if segments == ["settings"] {
            self = .showSettings
        } else if segments.count == 2, segments[0] == "channel",
                  let login = Self.normalizedLogin(segments[1]) {
            self = .openChannel(login: login)
        } else {
            return nil
        }
    }

    /// `candidate` as a Twitch login — 1 to 25 characters of `a-z`, `0-9`
    /// and `_` — or nil when it can't be one. ASCII capitals are folded
    /// (logins are lowercase; links are often typed with the display
    /// casing); nothing else is.
    static func normalizedLogin(_ candidate: String) -> String? {
        let bytes = candidate.utf8
        guard (1...25).contains(bytes.count) else { return nil }
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "_"):
                continue
            default:
                return nil
            }
        }
        return candidate.lowercased()
    }
}
