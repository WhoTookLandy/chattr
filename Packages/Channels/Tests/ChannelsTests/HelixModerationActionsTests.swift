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

    private struct FixedTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { OAuthToken(accessToken: "test-token") }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

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
        refreshes: RefreshCounter = RefreshCounter()
    ) -> (HelixChatActions, RecordingHTTPClient) {
        let http = RecordingHTTPClient(status: status, json: json)
        let client = TwitchClient(clientId: "test-client", tokenStore: FixedTokenStore(), httpClient: http)
        let actions = HelixChatActions(
            client: client,
            channelId: "chan-1",
            accountUserId: accountUserId,
            authRetry: HelixAuthRetry(refreshTokenHandler: { refreshes.increment() })
        )
        return (actions, http)
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
        let (actions, http) = makeActions(json: banResponse)

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
        let (actions, http) = makeActions(json: banResponse)

        try await actions.banUser(userId: "target-9", durationSeconds: nil, reason: "   ")

        let data = try bodyData(try #require(http.requests.first))
        #expect(data["user_id"] as? String == "target-9")
        #expect(data["duration"] == nil)
        #expect(data["reason"] == nil)
    }

    @Test("A 2xx ban with Twitch's real (undecodable) body still succeeds")
    func banUndecodableBodyIsSuccess() async throws {
        let (actions, _) = makeActions(json: banResponse)
        // Would throw HelixError.decodingFailed without the workaround.
        try await actions.banUser(userId: "target-9", durationSeconds: nil, reason: nil)
    }

    @Test("A refused ban surfaces Twitch's message")
    func banRefused() async throws {
        let (actions, _) = makeActions(
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
        let (actions, http) = makeActions(status: 204, json: "")

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
        let (actions, http) = makeActions(json: """
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
        let (actions, http) = makeActions()
        await #expect(throws: (any Error).self) {
            try await actions.warnUser(userId: "target-9", reason: "  ")
        }
        #expect(http.requests.isEmpty)
    }

    // MARK: - Banned lookup

    @Test("Ban state: a moderator (not the broadcaster) makes no request — unknown")
    func banStateSkippedForModerators() async {
        let (actions, http) = makeActions(json: #"{"data":[],"pagination":{}}"#)

        let state = await actions.banState(userId: "target-9")

        #expect(state == nil)
        #expect(http.requests.isEmpty)
    }

    @Test("Ban state: a 401 is unknown and never triggers a token refresh")
    func banStateUnauthorizedNoRefresh() async {
        let refreshes = RefreshCounter()
        let (actions, http) = makeActions(
            status: 401,
            json: #"{"error":"Unauthorized","status":401,"message":"The ID in broadcaster_id must match the user ID found in the request's OAuth token."}"#,
            accountUserId: "chan-1",
            refreshes: refreshes
        )

        let state = await actions.banState(userId: "target-9")

        #expect(state == nil)
        #expect(http.requests.count == 1)
        #expect(refreshes.count == 0)
    }

    @Test("Ban state: the broadcaster's GET /moderation/banned filtered to the user")
    func banStateRequest() async throws {
        let (actions, http) = makeActions(json: #"{"data":[],"pagination":{}}"#, accountUserId: "chan-1")

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
        let (banned, _) = makeActions(json: entry(expiresAt: ""), accountUserId: "chan-1")
        #expect(await banned.banState(userId: "target-9") == .banned)

        let (timedOut, _) = makeActions(json: entry(expiresAt: "2026-11-17T10:10:00Z"), accountUserId: "chan-1")
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
