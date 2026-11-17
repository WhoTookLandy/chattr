import Testing
import Foundation
import SwiftData
import os
import Core
import TwitchKit
@testable import Accounts

// MARK: - Fixtures

/// An in-memory token store that counts writes and deletes, so a test can
/// prove whether TwitchKit logged an account out behind a call.
private final class CountingTokenStore: TwitchTokenStore, Sendable {
    private struct State: Sendable {
        var token: OAuthToken?
        var saves = 0
        var deletes = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ token: OAuthToken?) {
        state = OSAllocatedUnfairLock(initialState: State(token: token))
    }

    var token: OAuthToken? { state.withLock { $0.token } }
    var deletes: Int { state.withLock { $0.deletes } }

    func loadToken() async throws -> OAuthToken? { state.withLock { $0.token } }

    func saveToken(_ token: OAuthToken) async throws {
        state.withLock {
            $0.token = token
            $0.saves += 1
        }
    }

    func deleteToken() async throws {
        state.withLock {
            $0.token = nil
            $0.deletes += 1
        }
    }
}

/// Stands in for the network under the interceptor. Helix accepts only the
/// fresh access token (204) and answers anything else with 401. A request
/// to Twitch's token endpoint gets what Twitch really says to a client with
/// no secret, and is recorded so tests can prove it never happens.
private final class HelixStub: HTTPClient, Sendable {
    private let recorded = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private let validAccessToken: String

    init(validAccessToken: String) {
        self.validAccessToken = validAccessToken
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }
    var helixRequests: [URLRequest] { requests.filter { $0.url?.host() == "api.twitch.tv" } }
    var twitchTokenEndpointRequests: Int { requests.filter { $0.url?.host() == "id.twitch.tv" }.count }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recorded.withLock { $0.append(request) }
        let status: Int
        let body: String
        if request.url?.host() == "id.twitch.tv" {
            status = 400
            body = #"{"status":400,"message":"missing client secret"}"#
        } else if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(validAccessToken)" {
            status = 204
            body = ""
        } else {
            status = 401
            body = #"{"error":"Unauthorized","status":401,"message":"Invalid OAuth token"}"#
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(body.utf8), response)
    }
}

/// Counts how many times the interceptor asked for a refresh.
private final class Counter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { value.withLock { $0 } }
    func increment() { value.withLock { $0 += 1 } }
}

/// The chattr-auth bridge, keyed by URL so parallel tests don't share
/// responses (same pattern as BridgeTokenRefreshTests).
private final class BridgeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let responses = OSAllocatedUnfairLock<[URL: (Data, Int)]>(initialState: [:])
    private static let bodies = OSAllocatedUnfairLock<[URL: [Data]]>(initialState: [:])

    static func register(_ url: URL, json: String, statusCode: Int) {
        responses.withLock { $0[url] = (Data(json.utf8), statusCode) }
    }

    static func bodies(for url: URL) -> [Data] {
        bodies.withLock { $0[url] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (data, statusCode) = Self.responses.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let body = Self.bodyData(of: request) ?? Data()
        Self.bodies.withLock { $0[url, default: []].append(body) }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private let staleToken = OAuthToken(
    accessToken: "stale-access",
    refreshToken: "refresh-1",
    scope: ["user:manage:chat_color"]
)

private let freshToken = OAuthToken(
    accessToken: "fresh-access",
    refreshToken: "refresh-2",
    expiresIn: 14_400,
    scope: ["user:manage:chat_color"],
    tokenType: "bearer"
)

private let freshBridgeJSON = #"""
{"access_token":"fresh-access","refresh_token":"refresh-2","expires_in":14400,"scope":["user:manage:chat_color"],"token_type":"bearer"}
"""#

// MARK: - Interceptor

@Suite("TwitchKitRefreshInterceptor (TwitchKit's 401 refresh)")
struct TwitchKitRefreshInterceptorTests {

    private func makeClient(
        answer: TwitchKitRefreshAnswer,
        refreshes: Counter
    ) -> (TwitchClient, HelixStub, CountingTokenStore) {
        let helix = HelixStub(validAccessToken: freshToken.accessToken)
        let store = CountingTokenStore(staleToken)
        let http = TwitchKitRefreshInterceptor(base: helix, tokenStore: store) {
            refreshes.increment()
            return answer
        }
        let client = TwitchClient(clientId: "test-client", tokenStore: store, httpClient: http)
        return (client, helix, store)
    }

    @Test("Recognises TwitchKit's refresh grant and nothing else")
    func recognisesRefreshGrant() {
        func request(_ url: String, method: String = "POST", body: String? = nil) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            return request
        }

        #expect(TwitchKitRefreshInterceptor.isTokenRefresh(request(
            "https://id.twitch.tv/oauth2/token",
            body: "client_id=abc&grant_type=refresh_token&refresh_token=r1"
        )))
        #expect(!TwitchKitRefreshInterceptor.isTokenRefresh(request(
            "https://id.twitch.tv/oauth2/token",
            body: "client_id=abc&grant_type=authorization_code&code=xyz"
        )))
        #expect(!TwitchKitRefreshInterceptor.isTokenRefresh(request(
            "https://id.twitch.tv/oauth2/validate", method: "GET"
        )))
        #expect(!TwitchKitRefreshInterceptor.isTokenRefresh(request(
            "https://api.twitch.tv/helix/users", method: "GET"
        )))
    }

    @Test("A 401 is refreshed through the handler: Twitch's token endpoint is never called and nothing is deleted")
    func refreshedRetriesWithNewToken() async throws {
        let refreshes = Counter()
        let (client, helix, store) = makeClient(answer: .refreshed(freshToken), refreshes: refreshes)

        try await client.api.updateUserChatColor(userID: "42", color: "blue")

        #expect(refreshes.count == 1)
        #expect(helix.twitchTokenEndpointRequests == 0)
        #expect(helix.helixRequests.count == 2)
        #expect(helix.helixRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
        #expect(store.deletes == 0)
        #expect(store.token == freshToken)
    }

    @Test("An unavailable bridge leaves the token in place and surfaces .unauthorized")
    func unavailableKeepsToken() async throws {
        let refreshes = Counter()
        let (client, helix, store) = makeClient(answer: .unavailable, refreshes: refreshes)

        do {
            try await client.api.updateUserChatColor(userID: "42", color: "blue")
            Issue.record("Expected HelixError.unauthorized")
        } catch HelixError.unauthorized {
            // Expected: the retry with the unchanged token still 401s.
        } catch {
            Issue.record("Expected HelixError.unauthorized, got \(error)")
        }

        #expect(refreshes.count == 1)
        #expect(helix.twitchTokenEndpointRequests == 0)
        #expect(store.deletes == 0)
        #expect(store.token == staleToken)
    }

    @Test("A rejected refresh lets TwitchKit clear its store, still without calling Twitch")
    func rejectedClearsStore() async throws {
        let refreshes = Counter()
        let (client, helix, store) = makeClient(answer: .rejected, refreshes: refreshes)

        do {
            try await client.api.updateUserChatColor(userID: "42", color: "blue")
            Issue.record("Expected HelixError.oauth")
        } catch HelixError.oauth {
            // Expected.
        } catch {
            Issue.record("Expected HelixError.oauth, got \(error)")
        }

        #expect(helix.twitchTokenEndpointRequests == 0)
        #expect(store.deletes == 1)
        #expect(store.token == nil)
    }
}

// MARK: - AccountStore end to end

@Suite("AccountStore keeps accounts signed in through TwitchKit's 401 refresh")
@MainActor
struct AccountStoreTwitchKitRefreshTests {

    private struct Harness {
        let store: AccountStore
        let account: Account
        let helix: HelixStub
        let tokenStore: CountingTokenStore
        let bridgeURL: URL
        let defaults: UserDefaults
        let suite: String
        // Keeps the in-memory SwiftData store alive for the test.
        let container: ModelContainer
    }

    private func makeHarness(bridgeStatus: Int, bridgeJSON: String) throws -> Harness {
        let container = try ModelContainer(
            for: Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suite = "chattr.tests.twitchkitrefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let bridgeURL = URL(string: "https://bridge.test/\(UUID().uuidString)/oauth/refresh")!
        BridgeStubURLProtocol.register(bridgeURL, json: bridgeJSON, statusCode: bridgeStatus)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BridgeStubURLProtocol.self]

        let helix = HelixStub(validAccessToken: freshToken.accessToken)
        let tokenStore = CountingTokenStore(staleToken)
        let store = AccountStore(
            modelContainer: container,
            clientId: "test-client",
            defaults: defaults,
            bridgeRefresh: BridgeTokenRefresh(endpoint: bridgeURL, session: URLSession(configuration: config)),
            twitchTransport: helix,
            tokenStoreFactory: { _ in tokenStore }
        )

        let userId = "refresh-\(UUID().uuidString)"
        let account = Account(
            userId: userId,
            login: "login\(userId)",
            displayName: "Name",
            profileImageURL: "",
            tokenNamespace: AccountStore.namespace(for: userId)
        )
        container.mainContext.insert(account)
        try container.mainContext.save()
        store.selectAccount(account)

        return Harness(
            store: store,
            account: account,
            helix: helix,
            tokenStore: tokenStore,
            bridgeURL: bridgeURL,
            defaults: defaults,
            suite: suite,
            container: container
        )
    }

    @Test("A Helix 401 refreshes via the bridge, never Twitch, and the account stays signed in")
    func expiredTokenRefreshesThroughBridge() async throws {
        let h = try makeHarness(bridgeStatus: 200, bridgeJSON: freshBridgeJSON)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.account.userId

        // A plain call: no withTokenRefresh around it, so only TwitchKit's
        // own 401 handling is in play.
        try await h.store.client(forUserId: userId).api.updateUserChatColor(userID: userId, color: "blue")

        #expect(h.helix.twitchTokenEndpointRequests == 0)
        let bridgeBodies = BridgeStubURLProtocol.bodies(for: h.bridgeURL)
        #expect(bridgeBodies.count == 1)
        let sent = try JSONDecoder().decode([String: String].self, from: try #require(bridgeBodies.first))
        #expect(sent["refresh_token"] == "refresh-1")
        #expect(h.tokenStore.deletes == 0)
        #expect(h.tokenStore.token?.accessToken == "fresh-access")
        #expect(h.tokenStore.token?.refreshToken == "refresh-2")
        #expect(!h.account.needsReauth)
    }

    @Test("A bridge outage keeps the token and the account")
    func bridgeOutageKeepsAccount() async throws {
        let h = try makeHarness(bridgeStatus: 503, bridgeJSON: #"{"error":"upstream"}"#)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.account.userId

        do {
            try await h.store.client(forUserId: userId).api.updateUserChatColor(userID: userId, color: "blue")
            Issue.record("Expected HelixError.unauthorized")
        } catch HelixError.unauthorized {
            // Expected.
        } catch {
            Issue.record("Expected HelixError.unauthorized, got \(error)")
        }

        #expect(h.helix.twitchTokenEndpointRequests == 0)
        #expect(h.tokenStore.deletes == 0)
        #expect(h.tokenStore.token == staleToken)
        #expect(!h.account.needsReauth)
    }

    @Test("A revoked refresh token (invalid_grant) surfaces session-expired and marks the account needsReauth")
    func revokedRefreshTokenNeedsReauth() async throws {
        let h = try makeHarness(
            bridgeStatus: 400,
            bridgeJSON: #"{"status":400,"message":"Invalid refresh token","error":"invalid_grant"}"#
        )
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.account.userId
        let login = h.account.login
        let client = h.store.client(forUserId: userId)

        await #expect(throws: AppError.sessionExpired(login: login)) {
            try await h.store.withTokenRefresh(for: h.account) {
                try await client.api.updateUserChatColor(userID: userId, color: "blue")
            }
        }

        #expect(h.helix.twitchTokenEndpointRequests == 0)
        #expect(h.account.needsReauth)
        #expect(h.tokenStore.token == nil)
        #expect(h.defaults.string(forKey: AccountStore.lastSessionExpiredLoginKey) == login)
    }

    @Test("A deliberate sign-out still deletes the token")
    func deliberateSignOutDeletes() async throws {
        let h = try makeHarness(bridgeStatus: 200, bridgeJSON: freshBridgeJSON)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }

        try await h.store.remove(account: h.account)

        #expect(h.tokenStore.deletes >= 1)
        #expect(h.tokenStore.token == nil)
        #expect(try await h.store.allAccounts().isEmpty)
    }
}
