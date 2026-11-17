import Testing
import Foundation
import SwiftData
import os
import Core
import TwitchKit
@testable import Accounts

// MARK: - Fixtures

/// An in-memory token store that counts reads, writes and deletes, so a test
/// can prove whether TwitchKit logged an account out behind a call. With
/// `failLoadsAfter`, every read after that many throws, like a Keychain read
/// that fails mid-session.
private final class CountingTokenStore: TwitchTokenStore, Sendable {
    private struct State: Sendable {
        var token: OAuthToken?
        var loads = 0
        var saves = 0
        var deletes = 0
    }

    struct LoadFailed: Error {}

    private let state: OSAllocatedUnfairLock<State>
    private let failLoadsAfter: Int?

    init(_ token: OAuthToken?, failLoadsAfter: Int? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(token: token))
        self.failLoadsAfter = failLoadsAfter
    }

    var token: OAuthToken? { state.withLock { $0.token } }
    var loads: Int { state.withLock { $0.loads } }
    var saves: Int { state.withLock { $0.saves } }
    var deletes: Int { state.withLock { $0.deletes } }

    func loadToken() async throws -> OAuthToken? {
        let (token, loads) = state.withLock { state -> (OAuthToken?, Int) in
            state.loads += 1
            return (state.token, state.loads)
        }
        if let failLoadsAfter, loads > failLoadsAfter {
            throw LoadFailed()
        }
        return token
    }

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

/// Holds one bridge response until the test opens it, so a test can change
/// the account while a refresh is in flight. No sleeps: the test awaits
/// `waitForArrival()`, acts, then calls `open()`.
private final class BridgeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false
    private var opened = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var pendingRelease: (() -> Void)?

    /// Returns once the bridge request has reached the stub.
    func waitForArrival() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if arrived { return true }
                arrivalWaiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    /// Called by the stub when the request arrives; `release` delivers the
    /// response.
    func arrive(release: @escaping () -> Void) {
        let (waiter, releaseNow) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, Bool) in
            arrived = true
            let waiter = arrivalWaiter
            arrivalWaiter = nil
            if !opened { pendingRelease = release }
            return (waiter, opened)
        }
        waiter?.resume()
        if releaseNow { release() }
    }

    /// Lets the held response through.
    func open() {
        let release = lock.withLock { () -> (() -> Void)? in
            opened = true
            let release = pendingRelease
            pendingRelease = nil
            return release
        }
        release?()
    }
}

/// The bridge, but each response waits for its `BridgeGate`.
private final class GatedBridgeURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Route: Sendable {
        let gate: BridgeGate
        let data: Data
        let statusCode: Int
    }

    private static let routes = OSAllocatedUnfairLock<[URL: Route]>(initialState: [:])

    static func register(_ url: URL, gate: BridgeGate, json: String, statusCode: Int) {
        routes.withLock { $0[url] = Route(gate: gate, data: Data(json.utf8), statusCode: statusCode) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let route = Self.routes.withLock({ $0[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        route.gate.arrive { [self] in
            let response = HTTPURLResponse(url: url, statusCode: route.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: route.data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A token store whose first save or delete stalls inside the underlying
/// store until the test opens `gate`, like a Keychain write still in
/// flight. Later writes go straight through. Counts land in `base`.
private final class HeldTokenStore: TwitchTokenStore, Sendable {
    let base: CountingTokenStore
    private let gate: BridgeGate
    private let heldOne = OSAllocatedUnfairLock(initialState: false)

    init(_ base: CountingTokenStore, gate: BridgeGate) {
        self.base = base
        self.gate = gate
    }

    func loadToken() async throws -> OAuthToken? {
        try await base.loadToken()
    }

    func saveToken(_ token: OAuthToken) async throws {
        await holdIfFirstMutation()
        try await base.saveToken(token)
    }

    func deleteToken() async throws {
        await holdIfFirstMutation()
        try await base.deleteToken()
    }

    private func holdIfFirstMutation() async {
        let first = heldOne.withLock { held -> Bool in
            defer { held = true }
            return !held
        }
        guard first else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.arrive { continuation.resume() }
        }
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

/// What the user gets by signing in again while a refresh is in flight.
private let reauthorizedToken = OAuthToken(
    accessToken: "reauthorized-access",
    refreshToken: "refresh-reauthorized",
    scope: ["user:manage:chat_color"]
)

private let freshBridgeJSON = #"""
{"access_token":"fresh-access","refresh_token":"refresh-2","expires_in":14400,"scope":["user:manage:chat_color"],"token_type":"bearer"}
"""#

private let invalidGrantJSON = #"{"status":400,"message":"Invalid refresh token","error":"invalid_grant"}"#

/// Whether `error` is the `HelixError.networkError` TwitchKit wraps a thrown
/// transport error in.
private func isNetworkError(_ error: any Error) -> Bool {
    if case HelixError.networkError = error { return true }
    return false
}

// MARK: - Interceptor

@Suite("TwitchKitRefreshInterceptor (TwitchKit's 401 refresh)")
struct TwitchKitRefreshInterceptorTests {

    /// A real `TwitchClient` wired the way `TwitchClientCache` wires one:
    /// guarded store, interceptor, shared lifecycle. With
    /// `retireDuringRefresh`, the client is retired while the refresh runs,
    /// as `remove` / re-authorization would.
    private func makeClient(
        answer: TwitchKitRefreshAnswer,
        refreshes: Counter,
        store: CountingTokenStore = CountingTokenStore(staleToken),
        retireDuringRefresh: Bool = false
    ) -> (TwitchClient, HelixStub, CountingTokenStore) {
        let helix = HelixStub(validAccessToken: freshToken.accessToken)
        let lifecycle = TwitchClientLifecycle()
        let http = TwitchKitRefreshInterceptor(base: helix, lifecycle: lifecycle) {
            refreshes.increment()
            if retireDuringRefresh { lifecycle.retire() }
            return answer
        }
        let client = TwitchClient(
            clientId: "test-client",
            tokenStore: LifecycleGuardedTokenStore(base: store, lifecycle: lifecycle, gate: AccountTokenGate()),
            httpClient: http
        )
        return (client, helix, store)
    }

    private func request(_ url: String, method: String = "POST", body: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        return request
    }

    @Test("Recognises TwitchKit's refresh grant and nothing else")
    func recognisesRefreshGrant() {
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

    @Test("Device-code sign-in (/oauth2/device and the device_code grant) passes through to the transport")
    func deviceCodeFlowPassesThrough() async throws {
        let transport = HelixStub(validAccessToken: freshToken.accessToken)
        let refreshes = Counter()
        let interceptor = TwitchKitRefreshInterceptor(base: transport, lifecycle: TwitchClientLifecycle()) {
            refreshes.increment()
            return .discarded
        }
        // Bodies as TwitchKit's `twitchFormEncoded` writes them (':' is not
        // percent-encoded) and as a percent-encoding client would.
        let device = request(
            "https://id.twitch.tv/oauth2/device",
            body: "client_id=abc&scopes=chat:read user:write:chat"
        )
        let deviceGrant = request(
            "https://id.twitch.tv/oauth2/token",
            body: "client_id=abc&device_code=dc-1&grant_type=urn:ietf:params:oauth:grant-type:device_code&scopes=chat:read"
        )
        let encodedDeviceGrant = request(
            "https://id.twitch.tv/oauth2/token",
            body: "client_id=abc&device_code=dc-1&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code"
        )

        #expect(!TwitchKitRefreshInterceptor.isTokenRefresh(device))
        #expect(!TwitchKitRefreshInterceptor.isTokenRefresh(deviceGrant))
        #expect(!TwitchKitRefreshInterceptor.isTokenRefresh(encodedDeviceGrant))

        _ = try await interceptor.data(for: device)
        _ = try await interceptor.data(for: deviceGrant)
        _ = try await interceptor.data(for: encodedDeviceGrant)

        #expect(refreshes.count == 0)
        let paths = transport.requests.map { $0.url?.path() }
        #expect(paths == ["/oauth2/device", "/oauth2/token", "/oauth2/token"])
        let bodies = transport.requests.map { $0.httpBody }
        #expect(bodies == [device.httpBody, deviceGrant.httpBody, encodedDeviceGrant.httpBody])
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

    @Test("An unavailable bridge hands back the current token and surfaces .unauthorized")
    func unavailableKeepsToken() async throws {
        let refreshes = Counter()
        let (client, helix, store) = makeClient(answer: .unavailable(current: staleToken), refreshes: refreshes)

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

    @Test("An unavailable bridge with no token to hand back fails the call without deleting anything")
    func unavailableWithoutTokenDeletesNothing() async throws {
        let refreshes = Counter()
        let (client, helix, store) = makeClient(answer: .unavailable(current: nil), refreshes: refreshes)

        do {
            try await client.api.updateUserChatColor(userID: "42", color: "blue")
            Issue.record("Expected HelixError.networkError")
        } catch {
            #expect(isNetworkError(error), "Expected HelixError.networkError, got \(error)")
        }

        // TwitchKit called logout(); the guarded store dropped its delete.
        #expect(helix.twitchTokenEndpointRequests == 0)
        #expect(helix.helixRequests.count == 1)
        #expect(store.deletes == 0)
        #expect(store.saves == 0)
        #expect(store.token == staleToken)
    }

    @Test("A rejected refresh fails with .oauth; TwitchKit's own delete is dropped (forceSignOut owns it)")
    func rejectedFailsWithoutTwitchKitDelete() async throws {
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
        #expect(store.deletes == 0)
    }

    @Test("Tokens refreshed for a client retired meanwhile are neither saved nor used")
    func refreshForRetiredClientIsDiscarded() async throws {
        let refreshes = Counter()
        let (client, helix, store) = makeClient(
            answer: .refreshed(freshToken),
            refreshes: refreshes,
            retireDuringRefresh: true
        )

        do {
            try await client.api.updateUserChatColor(userID: "42", color: "blue")
            Issue.record("Expected HelixError.networkError")
        } catch {
            #expect(isNetworkError(error), "Expected HelixError.networkError, got \(error)")
        }

        #expect(helix.helixRequests.count == 1)
        #expect(store.saves == 0)
        #expect(store.deletes == 0)
        #expect(store.token == staleToken)
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
        let refreshKeychain: InMemoryRefreshTokenKeychain
        let bridgeURL: URL
        let defaults: UserDefaults
        let suite: String
        // Keeps the in-memory SwiftData store alive for the test.
        let container: ModelContainer

        var userId: String { account.userId }

        func cachedRefreshToken() -> String? {
            OAuthRefreshTokenCache.load(for: account.userId, in: refreshKeychain)
        }
    }

    /// `gate`, when given, holds the bridge's response until the test opens
    /// it. `storeGate`, when given, holds the first token-store write
    /// instead (see `HeldTokenStore`); counts still land in `tokenStore`.
    private func makeHarness(
        bridgeStatus: Int,
        bridgeJSON: String,
        tokenStore: CountingTokenStore = CountingTokenStore(staleToken),
        gate: BridgeGate? = nil,
        storeGate: BridgeGate? = nil
    ) throws -> Harness {
        let container = try ModelContainer(
            for: Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suite = "chattr.tests.twitchkitrefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let bridgeURL = URL(string: "https://bridge.test/\(UUID().uuidString)/oauth/refresh")!
        let config = URLSessionConfiguration.ephemeral
        if let gate {
            GatedBridgeURLProtocol.register(bridgeURL, gate: gate, json: bridgeJSON, statusCode: bridgeStatus)
            config.protocolClasses = [GatedBridgeURLProtocol.self]
        } else {
            BridgeStubURLProtocol.register(bridgeURL, json: bridgeJSON, statusCode: bridgeStatus)
            config.protocolClasses = [BridgeStubURLProtocol.self]
        }

        let helix = HelixStub(validAccessToken: freshToken.accessToken)
        let refreshKeychain = InMemoryRefreshTokenKeychain()
        let backingStore: any TwitchTokenStore
        if let storeGate {
            backingStore = HeldTokenStore(tokenStore, gate: storeGate)
        } else {
            backingStore = tokenStore
        }
        let store = AccountStore(
            modelContainer: container,
            clientId: "test-client",
            defaults: defaults,
            bridgeRefresh: BridgeTokenRefresh(endpoint: bridgeURL, session: URLSession(configuration: config)),
            twitchTransport: helix,
            tokenStoreFactory: { _ in backingStore },
            refreshTokenKeychain: refreshKeychain
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
        OAuthRefreshTokenCache.save(refreshToken: staleToken.refreshToken, for: userId, in: refreshKeychain)

        return Harness(
            store: store,
            account: account,
            helix: helix,
            tokenStore: tokenStore,
            refreshKeychain: refreshKeychain,
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
        let userId = h.userId

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
        #expect(h.cachedRefreshToken() == "refresh-2")
        #expect(!h.account.needsReauth)
    }

    @Test("A bridge outage keeps the token and the account")
    func bridgeOutageKeepsAccount() async throws {
        let h = try makeHarness(bridgeStatus: 503, bridgeJSON: #"{"error":"upstream"}"#)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.userId

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

    @Test("A bridge outage hands TwitchKit its in-memory token, never a fresh Keychain read that can throw")
    func bridgeOutageWithFailingKeychainReadKeepsAccount() async throws {
        // The first read (TwitchKit loading the token for the call) works;
        // every later read throws, like a Keychain error mid-session.
        let tokenStore = CountingTokenStore(staleToken, failLoadsAfter: 1)
        let h = try makeHarness(bridgeStatus: 503, bridgeJSON: #"{"error":"upstream"}"#, tokenStore: tokenStore)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.userId

        do {
            try await h.store.client(forUserId: userId).api.updateUserChatColor(userID: userId, color: "blue")
            Issue.record("Expected HelixError.unauthorized")
        } catch HelixError.unauthorized {
            // Expected: TwitchKit got its own token back, so it retried
            // (still 401) instead of logging out.
        } catch {
            Issue.record("Expected HelixError.unauthorized, got \(error)")
        }

        #expect(tokenStore.loads == 1)
        #expect(tokenStore.deletes == 0)
        #expect(tokenStore.token == staleToken)
        #expect(h.helix.twitchTokenEndpointRequests == 0)
        #expect(!h.account.needsReauth)
    }

    @Test("A revoked refresh token (invalid_grant) surfaces session-expired and marks the account needsReauth")
    func revokedRefreshTokenNeedsReauth() async throws {
        let h = try makeHarness(bridgeStatus: 400, bridgeJSON: invalidGrantJSON)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.userId
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
        #expect(h.cachedRefreshToken() == nil)
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

    @Test("A refresh that settles after the account was removed saves nothing anywhere")
    func refreshSettlingAfterRemovalIsDiscarded() async throws {
        let gate = BridgeGate()
        let h = try makeHarness(bridgeStatus: 200, bridgeJSON: freshBridgeJSON, gate: gate)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.userId
        let client = h.store.client(forUserId: userId)

        let call = Task {
            try await client.api.updateUserChatColor(userID: userId, color: "blue")
        }
        await gate.waitForArrival()

        try await h.store.remove(account: h.account)
        let savesAfterRemoval = h.tokenStore.saves
        let deletesAfterRemoval = h.tokenStore.deletes
        #expect(deletesAfterRemoval == 1)
        #expect(h.tokenStore.token == nil)
        #expect(h.cachedRefreshToken() == nil)

        gate.open()
        let result = await call.result

        switch result {
        case .success:
            Issue.record("Expected the call to fail once its account was removed")
        case .failure(let error):
            #expect(isNetworkError(error), "Expected HelixError.networkError, got \(error)")
        }
        #expect(h.tokenStore.saves == savesAfterRemoval)
        #expect(h.tokenStore.deletes == deletesAfterRemoval)
        #expect(h.tokenStore.token == nil)
        #expect(h.cachedRefreshToken() == nil)
        // No retry with the discarded token.
        #expect(h.helix.helixRequests.count == 1)
        #expect(h.helix.twitchTokenEndpointRequests == 0)
    }

    /// Holds the bridge, re-authorizes the account through the same
    /// `replaceClient` call `add(token:)` makes once it knows the userId,
    /// then lets the stale refresh's response through.
    private func reauthorizeDuringRefresh(bridgeStatus: Int, bridgeJSON: String) async throws -> (Harness, Result<Void, any Error>) {
        let gate = BridgeGate()
        let h = try makeHarness(bridgeStatus: bridgeStatus, bridgeJSON: bridgeJSON, gate: gate)
        let userId = h.userId
        let client = h.store.client(forUserId: userId)

        let call = Task {
            try await client.api.updateUserChatColor(userID: userId, color: "blue")
        }
        await gate.waitForArrival()

        _ = try await h.store.clients.replaceClient(forUserId: userId, seededWith: reauthorizedToken)
        OAuthRefreshTokenCache.save(refreshToken: reauthorizedToken.refreshToken, for: userId, in: h.refreshKeychain)

        gate.open()
        return (h, await call.result)
    }

    @Test("A refresh that succeeds after re-authorization can't overwrite or delete the new token")
    func refreshSucceedingAfterReauthorizationIsDiscarded() async throws {
        let (h, result) = try await reauthorizeDuringRefresh(bridgeStatus: 200, bridgeJSON: freshBridgeJSON)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }

        if case .success = result {
            Issue.record("Expected the stale client's call to fail")
        }
        #expect(h.tokenStore.token == reauthorizedToken)
        // The only save is the re-authorization's own.
        #expect(h.tokenStore.saves == 1)
        #expect(h.tokenStore.deletes == 0)
        #expect(h.cachedRefreshToken() == "refresh-reauthorized")
        #expect(!h.account.needsReauth)
    }

    @Test("A rejection of the pre-re-authorization refresh token doesn't sign the new session out")
    func rejectionAfterReauthorizationIsDiscarded() async throws {
        let (h, result) = try await reauthorizeDuringRefresh(bridgeStatus: 400, bridgeJSON: invalidGrantJSON)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }

        if case .success = result {
            Issue.record("Expected the stale client's call to fail")
        }
        #expect(h.tokenStore.token == reauthorizedToken)
        #expect(h.tokenStore.deletes == 0)
        #expect(h.cachedRefreshToken() == "refresh-reauthorized")
        #expect(!h.account.needsReauth)
        #expect(h.defaults.string(forKey: AccountStore.lastSessionExpiredLoginKey) == nil)
    }

    // MARK: Writes already in the store when the account is re-authorized

    @Test("A save admitted before re-authorization finishes first, so the re-authorized token survives")
    func heldSaveCannotOverwriteReauthorizedToken() async throws {
        let storeGate = BridgeGate()
        let h = try makeHarness(bridgeStatus: 200, bridgeJSON: freshBridgeJSON, storeGate: storeGate)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.userId
        let clients = h.store.clients
        let old = clients.entry(forUserId: userId)
        let oldAuth = old.client.auth

        // The old client saves while it is still the account's client. The
        // write passes the lifecycle check and stalls inside the store.
        let staleSave = Task {
            try await oldAuth.setToken(freshToken)
        }
        await storeGate.waitForArrival()

        // Re-authorize while that write is in flight. It queues behind the
        // write instead of writing around it.
        let reauthorization = Task {
            try await clients.replaceClient(forUserId: userId, seededWith: reauthorizedToken).lifecycle
        }
        await clients.tokenGate(forUserId: userId).waitForWaiters(1)
        #expect(h.tokenStore.saves == 0)
        #expect(h.tokenStore.token == staleToken)

        storeGate.open()
        try await staleSave.value
        let replacement = try await reauthorization.value

        // The stale write landed first; the re-authorization's came after it.
        #expect(h.tokenStore.saves == 2)
        #expect(h.tokenStore.deletes == 0)
        #expect(h.tokenStore.token == reauthorizedToken)
        #expect(old.lifecycle.current == .retired)
        let cached = clients.entry(forUserId: userId)
        #expect(cached.lifecycle === replacement)
        #expect(replacement.isActive)
        let current = try await cached.client.auth.tokenProvider.token()
        #expect(current == reauthorizedToken)
    }

    @Test("A delete admitted before re-authorization finishes first, so the re-authorized token survives")
    func heldDeleteCannotDeleteReauthorizedToken() async throws {
        let storeGate = BridgeGate()
        let h = try makeHarness(bridgeStatus: 200, bridgeJSON: freshBridgeJSON, storeGate: storeGate)
        defer { h.defaults.removePersistentDomain(forName: h.suite) }
        let userId = h.userId
        let clients = h.store.clients
        let old = clients.entry(forUserId: userId)

        // A deliberate sign-out of the old client: its delete is allowed
        // and stalls inside the store.
        let signOut = Task {
            try await clients.logOut(userId: userId)
        }
        await storeGate.waitForArrival()
        #expect(old.lifecycle.current == .signingOut)

        let reauthorization = Task {
            try await clients.replaceClient(forUserId: userId, seededWith: reauthorizedToken).lifecycle
        }
        await clients.tokenGate(forUserId: userId).waitForWaiters(1)
        #expect(h.tokenStore.deletes == 0)
        #expect(h.tokenStore.saves == 0)

        storeGate.open()
        try await signOut.value
        let replacement = try await reauthorization.value

        // The delete landed first; the re-authorized token was written after it.
        #expect(h.tokenStore.deletes == 1)
        #expect(h.tokenStore.saves == 1)
        #expect(h.tokenStore.token == reauthorizedToken)
        #expect(old.lifecycle.current == .retired)
        let cached = clients.entry(forUserId: userId)
        #expect(cached.lifecycle === replacement)
        let current = try await cached.client.auth.tokenProvider.token()
        #expect(current == reauthorizedToken)
    }
}
