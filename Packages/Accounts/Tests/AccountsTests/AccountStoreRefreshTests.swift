import Testing
import Foundation
import Core
@testable import Accounts

/// Branch-tree coverage for the Vercel-bridge refresh, via the pure
/// `AccountStore.performBridgeRefresh(refreshToken:using:)` extracted from
/// `refreshTokens`. This is the part that previously had zero coverage and is
/// most prone to silent regression: HTTP status → outcome classification, JSON
/// parsing, and the refresh-token carry-forward rule.
///
/// Network is stubbed via `MockURLProtocol`. The surrounding token-sourcing and
/// sign-out side effects in `refreshTokens` depend on the system Keychain +
/// TwitchKit, which a SwiftPM test bundle can't reach (no entitlement) — those
/// are deliberately out of scope here; this tests the logic, not the OS plumbing.
///
/// `.serialized` because `MockURLProtocol.stub` is shared process-wide.
@Suite("AccountStore.performBridgeRefresh (bridge branch tree)", .serialized)
struct AccountStoreRefreshTests {

    @Test("200 → refreshed with the parsed token")
    func success() async throws {
        let json = #"{"access_token":"at-new","refresh_token":"rt-new","expires_in":14400,"scope":["chat:read"],"token_type":"bearer"}"#
        MockURLProtocol.stub = (status: 200, body: Data(json.utf8))
        defer { MockURLProtocol.stub = nil }

        let outcome = try await AccountStore.performBridgeRefresh(refreshToken: "rt-old", using: makeMockSession())
        guard case let .refreshed(token) = outcome else {
            Issue.record("expected .refreshed, got \(outcome)")
            return
        }
        #expect(token.accessToken == "at-new")
        #expect(token.refreshToken == "rt-new")
        #expect(token.expiresIn == 14400)
        #expect(token.scope == ["chat:read"])
    }

    @Test("200 without a rotated refresh_token carries the sent one forward")
    func successCarryForward() async throws {
        // Twitch sometimes omits refresh_token; we must reuse the one we sent
        // rather than persist nil and strand the next refresh.
        let json = #"{"access_token":"at-new2","expires_in":14400,"token_type":"bearer"}"#
        MockURLProtocol.stub = (status: 200, body: Data(json.utf8))
        defer { MockURLProtocol.stub = nil }

        let outcome = try await AccountStore.performBridgeRefresh(refreshToken: "rt-carry", using: makeMockSession())
        guard case let .refreshed(token) = outcome else {
            Issue.record("expected .refreshed, got \(outcome)")
            return
        }
        #expect(token.accessToken == "at-new2")
        #expect(token.refreshToken == "rt-carry")
    }

    @Test("4xx → rejected (terminal: caller signs the user out)")
    func rejected() async throws {
        MockURLProtocol.stub = (status: 401, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        defer { MockURLProtocol.stub = nil }

        let outcome = try await AccountStore.performBridgeRefresh(refreshToken: "rt", using: makeMockSession())
        guard case let .rejected(status, body) = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
        #expect(status == 401)
        #expect(body.contains("invalid_grant"))
    }

    @Test("422 (other 4xx) is also rejected, not transient")
    func rejectedBoundary() async throws {
        MockURLProtocol.stub = (status: 422, body: Data("nope".utf8))
        defer { MockURLProtocol.stub = nil }

        let outcome = try await AccountStore.performBridgeRefresh(refreshToken: "rt", using: makeMockSession())
        guard case .rejected = outcome else {
            Issue.record("expected .rejected, got \(outcome)")
            return
        }
    }

    @Test("5xx → transient (caller may retry, does NOT sign out)")
    func transient() async throws {
        MockURLProtocol.stub = (status: 503, body: Data("service unavailable".utf8))
        defer { MockURLProtocol.stub = nil }

        let outcome = try await AccountStore.performBridgeRefresh(refreshToken: "rt", using: makeMockSession())
        guard case let .transient(status, _) = outcome else {
            Issue.record("expected .transient, got \(outcome)")
            return
        }
        #expect(status == 503)
    }
}
