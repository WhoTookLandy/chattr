import Testing
import Foundation
import os
import TwitchKit
@testable import Channels

/// Request building for the user-card moderation calls (ban / timeout /
/// unban / warn / banned-lookup), driven through a real `TwitchClient` over
/// a recording `HTTPClient` — so the assertions are on the exact HTTP
/// requests Twitch would receive, and the canned responses use Twitch's
/// real wire shapes (including the ban response TwitchKit can't decode).
@Suite("HelixChatActions moderation requests")
struct HelixModerationActionsTests {

    // MARK: - Fixtures

    /// A token store over one fixed token that counts writes and deletes,
    /// so a test can prove TwitchKit never refreshed (save) or logged out
    /// (delete) behind a call.
    private final class FixedTokenStore: TwitchTokenStore, Sendable {
        private let token: OAuthToken
        private let saveCount = OSAllocatedUnfairLock(initialState: 0)
        private let deleteCount = OSAllocatedUnfairLock(initialState: 0)

        init(_ token: OAuthToken) {
            self.token = token
        }

        var saves: Int { saveCount.withLock { $0 } }
        var deletes: Int { deleteCount.withLock { $0 } }

        func loadToken() async throws -> OAuthToken? { token }
        func saveToken(_ token: OAuthToken) async throws { saveCount.withLock { $0 += 1 } }
        func deleteToken() async throws { deleteCount.withLock { $0 += 1 } }
    }

    /// No recorded scope list: the action pre-checks can't judge, so the
    /// request goes out (and the banned lookup stays unknown).
    private static let plainToken = OAuthToken(accessToken: "test-token")

    /// What a current sign-in carries: a refresh token and the moderation
    /// scopes.
    private static let fullyScopedToken = OAuthToken(
        accessToken: "test-token",
        refreshToken: "test-refresh",
        scope: [
            "moderator:manage:banned_users",
            "moderator:manage:warnings",
            "moderator:read:banned_users",
        ]
    )

    /// An account signed in before the moderation tools shipped.
    private static let preModerationToken = OAuthToken(
        accessToken: "test-token",
        refreshToken: "test-refresh",
        scope: ["user:read:chat", "user:write:chat", "moderator:manage:chat_messages"]
    )

    /// Records every request and answers with a canned status + body.
    private final class RecordingHTTPClient: HTTPClient, Sendable {
        private let recorded = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
        private let status: Int
        private let body: Data

        init(status: Int, json: String) {
            self.status = status
            self.body = Data(json.utf8)
        }

        var requests: [URLRequest] { recorded.withLock { $0 } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            recorded.withLock { $0.append(request) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        }
    }

    /// Counts bridge refreshes, so tests can prove a call never triggers one.
    private final class RefreshCounter: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: 0)
        var count: Int { value.withLock { $0 } }
        func increment() { value.withLock { $0 += 1 } }
    }

    private func makeActions(
        status: Int = 200,
        json: String = "{\"data\":[]}",
        accountUserId: String = "mod-1",
        token: OAuthToken = HelixModerationActionsTests.plainToken,
        refreshes: RefreshCounter = RefreshCounter()
    ) -> (HelixChatActions, RecordingHTTPClient, FixedTokenStore) {
        let http = RecordingHTTPClient(status: status, json: json)
        let tokenStore = FixedTokenStore(token)
        let client = TwitchClient(clientId: "test-client", tokenStore: tokenStore, httpClient: http)
        let actions = HelixChatActions(
            client: client,
            channelId: "chan-1",
            accountUserId: accountUserId,
            authRetry: HelixAuthRetry(refreshTokenHandler: { refreshes.increment() }),
            http: http
        )
        return (actions, http, tokenStore)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    /// The `data` object of a `{"data": {...}}` request body.
    private func bodyData(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try #require(object["data"] as? [String: Any])
    }

    /// What Twitch actually returns from POST /moderation/bans — NOT the
    /// GET /moderation/banned shape TwitchKit's `BannedUser` expects.
    private let banResponse = """
    {"data":[{"broadcaster_id":"chan-1","moderator_id":"mod-1","user_id":"target-9",
    "created_at":"2026-11-17T10:00:00Z","end_time":"2026-11-17T10:10:00Z"}]}
    """

    // MARK: - Ban / timeout

    @Test("Timeout POSTs /moderation/bans with user, duration and reason")
    func timeoutRequest() async throws {
        let (actions, http, _) = makeActions(json: banResponse)

        try await actions.banUser(userId: "target-9", durationSeconds: 600, reason: "  spam  ")

        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/helix/moderation/bans")
        #expect(query(request) == ["broadcaster_id": "chan-1", "moderator_id": "mod-1"])
        let data = try bodyData(request)
        #expect(data["user_id"] as? String == "target-9")
        #expect(data["duration"] as? Int == 600)
        #expect(data["reason"] as? String == "spam")
    }

    @Test("Ban omits duration (permanent) and a blank reason")
    func banRequest() async throws {
        let (actions, http, _) = makeActions(json: banResponse)

        try await actions.banUser(userId: "target-9", durationSeconds: nil, reason: "   ")

        let data = try bodyData(try #require(http.requests.first))
        #expect(data["user_id"] as? String == "target-9")
        #expect(data["duration"] == nil)
        #expect(data["reason"] == nil)
    }

    @Test("A 2xx ban with Twitch's real (undecodable) body still succeeds")
    func banUndecodableBodyIsSuccess() async throws {
        let (actions, _, _) = makeActions(json: banResponse)
        // Would throw HelixError.decodingFailed without the workaround.
        try await actions.banUser(userId: "target-9", durationSeconds: nil, reason: nil)
    }

    @Test("A refused ban surfaces Twitch's message")
    func banRefused() async throws {
        let (actions, _, _) = makeActions(
            status: 400,
            json: #"{"error":"Bad Request","status":400,"message":"The user specified in the user_id field is already banned."}"#
        )
        await #expect(throws: HelixError.self) {
            try await actions.banUser(userId: "target-9", durationSeconds: nil, reason: nil)
        }
    }

    // MARK: - Unban

    @Test("Unban DELETEs /moderation/bans with the user in the query")
    func unbanRequest() async throws {
        let (actions, http, _) = makeActions(status: 204, json: "")

        try await actions.unbanUser(userId: "target-9")

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/helix/moderation/bans")
        #expect(query(request) == ["broadcaster_id": "chan-1", "moderator_id": "mod-1", "user_id": "target-9"])
        #expect(request.httpBody == nil)
    }

    // MARK: - Warn

    @Test("Warn POSTs /moderation/warnings with user and trimmed reason")
    func warnRequest() async throws {
        let (actions, http, _) = makeActions(json: """
        {"data":[{"broadcaster_id":"chan-1","user_id":"target-9","moderator_id":"mod-1","reason":"be nice"}]}
        """)

        try await actions.warnUser(userId: "target-9", reason: " be nice ")

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/helix/moderation/warnings")
        #expect(query(request) == ["broadcaster_id": "chan-1", "moderator_id": "mod-1"])
        let data = try bodyData(request)
        #expect(data["user_id"] as? String == "target-9")
        #expect(data["reason"] as? String == "be nice")
    }

    @Test("Warn with a blank reason throws before any request")
    func warnBlankReason() async throws {
        let (actions, http, _) = makeActions()
        await #expect(throws: (any Error).self) {
            try await actions.warnUser(userId: "target-9", reason: "  ")
        }
        #expect(http.requests.isEmpty)
    }

    // MARK: - Banned lookup

    @Test("Ban state: a moderator (not the broadcaster) makes no request — unknown")
    func banStateSkippedForModerators() async {
        let (actions, http, _) = makeActions(json: #"{"data":[],"pagination":{}}"#)

        let state = await actions.banState(userId: "target-9")

        #expect(state == nil)
        #expect(http.requests.isEmpty)
    }

    @Test("Ban state: a 401 is unknown — no TwitchKit refresh, no logout, no bridge refresh")
    func banStateUnauthorizedNoRefresh() async throws {
        let refreshes = RefreshCounter()
        // The credential HAS a refresh token, so TwitchKit's HelixClient
        // would POST /oauth2/token on a 401 (same transport → a second
        // recorded request), fail, and delete the token.
        let (actions, http, store) = makeActions(
            status: 401,
            json: #"{"error":"Unauthorized","status":401,"message":"Missing scope: moderation:read or moderator:manage:banned_users"}"#,
            accountUserId: "chan-1",
            token: Self.fullyScopedToken,
            refreshes: refreshes
        )

        let state = await actions.banState(userId: "target-9")

        #expect(state == nil)
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.url?.host == "api.twitch.tv")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Client-Id") == "test-client")
        #expect(refreshes.count == 0)
        #expect(store.saves == 0)
        #expect(store.deletes == 0)
    }

    @Test("Ban state: a 403 is unknown too")
    func banStateForbiddenIsUnknown() async {
        let (actions, http, store) = makeActions(
            status: 403,
            json: #"{"error":"Forbidden","status":403,"message":"nope"}"#,
            accountUserId: "chan-1",
            token: Self.fullyScopedToken
        )

        #expect(await actions.banState(userId: "target-9") == nil)
        #expect(http.requests.count == 1)
        #expect(store.deletes == 0)
    }

    @Test("Ban state: a token without the scope (or with no scope list) makes no request")
    func banStateSkippedWithoutScope() async {
        let (older, olderHTTP, _) = makeActions(accountUserId: "chan-1", token: Self.preModerationToken)
        #expect(await older.banState(userId: "target-9") == nil)
        #expect(olderHTTP.requests.isEmpty)

        let (unknown, unknownHTTP, _) = makeActions(accountUserId: "chan-1", token: Self.plainToken)
        #expect(await unknown.banState(userId: "target-9") == nil)
        #expect(unknownHTTP.requests.isEmpty)
    }

    // MARK: - Scope pre-check

    @Test("Ban / timeout / unban / warn without the scope: sign-in-again, no request, token kept")
    func actionsWithoutScopeNeverHitTwitch() async {
        let refreshes = RefreshCounter()
        let (actions, http, store) = makeActions(
            status: 401,
            json: #"{"error":"Unauthorized","status":401,"message":"Missing scope"}"#,
            token: Self.preModerationToken,
            refreshes: refreshes
        )

        await #expect(throws: ModerationActionError.needsSignInAgain) {
            try await actions.banUser(userId: "target-9", durationSeconds: 600, reason: nil)
        }
        await #expect(throws: ModerationActionError.needsSignInAgain) {
            try await actions.banUser(userId: "target-9", durationSeconds: nil, reason: nil)
        }
        await #expect(throws: ModerationActionError.needsSignInAgain) {
            try await actions.unbanUser(userId: "target-9")
        }
        await #expect(throws: ModerationActionError.needsSignInAgain) {
            try await actions.warnUser(userId: "target-9", reason: "be nice")
        }

        #expect(http.requests.isEmpty)
        #expect(refreshes.count == 0)
        #expect(store.saves == 0)
        #expect(store.deletes == 0)
    }

    @Test("With the scope granted, the action goes out")
    func actionsWithScopeProceed() async throws {
        let (actions, http, _) = makeActions(json: banResponse, token: Self.fullyScopedToken)

        try await actions.banUser(userId: "target-9", durationSeconds: 600, reason: nil)

        #expect(http.requests.count == 1)
    }

    @Test("The pre-check's error survives the session's error mapping")
    func preCheckErrorMapsToItself() {
        #expect(ModerationActionError.from(ModerationActionError.needsSignInAgain) == .needsSignInAgain)
    }

    @Test("Ban state: the broadcaster's GET /moderation/banned filtered to the user")
    func banStateRequest() async throws {
        let (actions, http, _) = makeActions(json: #"{"data":[],"pagination":{}}"#, accountUserId: "chan-1", token: Self.fullyScopedToken)

        let state = await actions.banState(userId: "target-9")

        #expect(state == .notBanned)
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/helix/moderation/banned")
        #expect(query(request)["broadcaster_id"] == "chan-1")
        #expect(query(request)["user_id"] == "target-9")
    }

    @Test("Ban state: empty expires_at is a permanent ban, a timestamp a timeout")
    func banStateParsing() async throws {
        func entry(expiresAt: String) -> String {
            """
            {"data":[{"user_id":"target-9","user_login":"t","user_name":"T","expires_at":"\(expiresAt)",
            "created_at":"2026-11-17T10:00:00Z","reason":"","moderator_id":"mod-1",
            "moderator_login":"m","moderator_name":"M"}],"pagination":{}}
            """
        }
        let (banned, _, _) = makeActions(json: entry(expiresAt: ""), accountUserId: "chan-1", token: Self.fullyScopedToken)
        #expect(await banned.banState(userId: "target-9") == .banned)

        let (timedOut, _, _) = makeActions(json: entry(expiresAt: "2026-11-17T10:10:00Z"), accountUserId: "chan-1", token: Self.fullyScopedToken)
        let state = await timedOut.banState(userId: "target-9")
        guard case .timedOut(let until)? = state else {
            Issue.record("Expected .timedOut, got \(String(describing: state))")
            return
        }
        #expect(until == Date(timeIntervalSince1970: 1_794_910_200))
    }

    // MARK: - Error mapping

    @Test("Auth-shaped failures after the retry mean the token lacks the scope")
    func mapsAuthToSignInAgain() {
        #expect(ModerationActionError.from(HelixError.unauthorized) == .needsSignInAgain)
        #expect(ModerationActionError.from(HelixError.notAuthenticated) == .needsSignInAgain)
    }

    @Test("Twitch refusals keep Twitch's message; transport errors pass through")
    func mapsRefusals() {
        let apiError = TwitchAPIError(error: "Forbidden", status: 403, message: "Not a moderator")
        #expect(ModerationActionError.from(HelixError.forbidden(apiError)) == .rejected("Not a moderator"))
        #expect(ModerationActionError.from(HelixError.networkError("offline")) == nil)
        #expect(ModerationActionError.from(CancellationError()) == nil)
    }
}
