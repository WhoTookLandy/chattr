#if os(iOS)
import Testing
import Foundation
@testable import Features

/// The session the native player asks for playback as, so the viewer's
/// subscriptions and Turbo skip ads: reading a twitch.tv website session
/// out of cookies, and sending a session with the playback token request.
@Suite("Twitch.tv session for ad-free playback")
struct TwitchWebSessionTests {
    static func cookie(_ name: String, _ value: String, domain: String = ".twitch.tv", expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    @Test("Reads the auth token and login")
    func readsSession() {
        let credential = TwitchWebSession.credential(from: [
            Self.cookie("login", "viewer"),
            Self.cookie("auth-token", "abc123"),
        ])
        #expect(credential == .init(token: "abc123", login: "viewer"))
    }

    @Test("No auth token, no session")
    func noToken() {
        #expect(TwitchWebSession.credential(from: [Self.cookie("login", "viewer")]) == nil)
        #expect(TwitchWebSession.credential(from: [Self.cookie("auth-token", "")]) == nil)
    }

    @Test("Ignores other sites' cookies")
    func otherDomains() {
        #expect(TwitchWebSession.credential(from: [Self.cookie("auth-token", "abc", domain: "nottwitch.tv")]) == nil)
        #expect(TwitchWebSession.credential(from: [Self.cookie("auth-token", "abc", domain: "www.twitch.tv")])?.token == "abc")
    }

    @Test("Ignores an expired session")
    func expired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cookies = [Self.cookie("auth-token", "abc", expires: now.addingTimeInterval(-1))]
        #expect(TwitchWebSession.credential(from: cookies, now: now) == nil)
    }

    @Test("Signed in, the token request carries the session and its client")
    func signedInRequest() throws {
        let auth = TwitchHLS.Auth(token: "abc123", clientId: "tv-client")
        let request = try TwitchHLS.tokenRequest(login: "somechannel", auth: auth)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "OAuth abc123")
        #expect(request.value(forHTTPHeaderField: "Client-ID") == "tv-client")
    }

    @Test("Signed out, the token request is anonymous under the web client")
    func signedOutRequest() throws {
        for auth in [nil, TwitchHLS.Auth(token: "", clientId: "tv-client")] {
            let request = try TwitchHLS.tokenRequest(login: "somechannel", auth: auth)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Client-ID") == TwitchHLS.webClientID)
        }
    }
}
#endif
