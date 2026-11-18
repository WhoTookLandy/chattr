#if os(iOS)
import Foundation
import WebKit

/// The viewer's twitch.tv website session, if they've signed in to one
/// (Settings → Video & Device → Twitch.tv Session).
///
/// Why a second sign-in: chattr's own account token is a third-party OAuth
/// token, and Twitch's playback-token endpoint (`TwitchHLS`) only accepts
/// the website's own first-party token. Without that, the native player
/// asks for streams as a logged-out viewer, so subscriptions and Turbo
/// don't count and ads play. With it, the token Twitch signs carries the
/// viewer's entitlements and ad-free benefits apply.
///
/// The session lives where twitch.tv put it: the `auth-token` cookie in
/// the app's default WebKit cookie store. Nothing copies it elsewhere, so
/// signing out of it (`signOut()`) is deleting the cookies. The web player
/// (`TwitchWebPlayer`) uses the same store, so it plays signed in too.
enum TwitchWebSession {
    /// The parts of a twitch.tv session chattr uses.
    struct Credential: Equatable, Sendable {
        /// The `auth-token` cookie: the website's OAuth token.
        let token: String
        /// The `login` cookie, shown in Settings so the viewer can tell
        /// which Twitch account the session is (it needn't be chattr's).
        let login: String?
    }

    /// Where the viewer signs in. The website sets the cookies on success.
    static let signInURL = URL(string: "https://www.twitch.tv/login")!

    /// The session in `cookies`, or nil when there's no usable `auth-token`
    /// for twitch.tv. Expired cookies don't count.
    static func credential(from cookies: [HTTPCookie], now: Date = .now) -> Credential? {
        let twitch = cookies.filter { isTwitch($0) && !isExpired($0, now: now) }
        guard let token = twitch.first(where: { $0.name == "auth-token" })?.value,
              !token.isEmpty
        else { return nil }
        let login = twitch.first(where: { $0.name == "login" })?.value
        return Credential(token: token, login: login?.isEmpty == false ? login : nil)
    }

    /// The current session, read from the cookie store.
    @MainActor
    static func current() async -> Credential? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return credential(from: cookies)
    }

    /// Ends the session on this device: deletes every twitch.tv cookie, so
    /// both players go back to playing logged out. Doesn't revoke the
    /// token on Twitch's side (Twitch's account settings do that).
    @MainActor
    static func signOut() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for cookie in await store.allCookies() where isTwitch(cookie) {
            await store.deleteCookie(cookie)
        }
    }

    private static func isTwitch(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "twitch.tv" || domain.hasSuffix(".twitch.tv")
    }

    private static func isExpired(_ cookie: HTTPCookie, now: Date) -> Bool {
        guard let expires = cookie.expiresDate else { return false }
        return expires <= now
    }
}
#endif
