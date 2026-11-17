import Testing
import Foundation
import os
import Core
import TwitchKit
@testable import Accounts

// MARK: - URLProtocol stub
//
// Same keyed-by-URL pattern as BridgeTokenRefreshTests (Swift Testing runs
// tests in parallel, so a single shared handler would cross-serve). Each URL
// holds a FIFO of responses so polling tests can script a sequence; the last
// response repeats once the queue is down to one.

private final class DeviceCodeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let responses = OSAllocatedUnfairLock<[URL: [(Data, Int)]]>(initialState: [:])
    private static let requestBodies = OSAllocatedUnfairLock<[URL: [String]]>(initialState: [:])

    static func register(_ url: URL, _ sequence: [(json: String, status: Int)]) {
        responses.withLock { $0[url] = sequence.map { (Data($0.json.utf8), $0.status) } }
    }

    static func next(_ url: URL) -> (Data, Int)? {
        responses.withLock { map in
            guard var queue = map[url], let first = queue.first else { return nil }
            if queue.count > 1 { queue.removeFirst(); map[url] = queue }
            return first
        }
    }

    static func bodies(for url: URL) -> [String] {
        requestBodies.withLock { $0[url] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (data, statusCode) = Self.next(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let body = Self.bodyData(of: request).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Self.requestBodies.withLock { $0[url, default: []].append(body) }
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

/// Records every requested sleep instead of sleeping.
private final class SleepRecorder: Sendable {
    private let recorded = OSAllocatedUnfairLock<[Duration]>(initialState: [])
    var durations: [Duration] { recorded.withLock { $0 } }
    var sleep: @Sendable (Duration) async throws -> Void {
        { [recorded] duration in recorded.withLock { $0.append(duration) } }
    }
}

@Suite("DeviceCodeGrant (Twitch device-code wire protocol + polling)")
struct DeviceCodeGrantTests {

    private static let pending = (json: #"{"status":400,"message":"authorization_pending"}"#, status: 400)
    private static let slowDown = (json: #"{"status":400,"message":"slow_down"}"#, status: 400)
    private static let success = (
        json: #"{"access_token":"dcf-access","refresh_token":"dcf-refresh","expires_in":14400,"scope":["chat:read","user:read:email"],"token_type":"bearer"}"#,
        status: 200
    )

    /// A grant whose device + token endpoints are unique stub URLs.
    private static func grant(
        device: [(json: String, status: Int)] = [],
        token: [(json: String, status: Int)] = []
    ) -> (DeviceCodeGrant, deviceURL: URL, tokenURL: URL) {
        let id = UUID().uuidString
        let deviceURL = URL(string: "https://id.test/\(id)/oauth2/device")!
        let tokenURL = URL(string: "https://id.test/\(id)/oauth2/token")!
        DeviceCodeStubURLProtocol.register(deviceURL, device)
        DeviceCodeStubURLProtocol.register(tokenURL, token)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeviceCodeStubURLProtocol.self]
        let grant = DeviceCodeGrant(
            clientId: "client-123",
            rawScopes: ["chat:read", "user:read:email"],
            deviceEndpoint: deviceURL,
            tokenEndpoint: tokenURL,
            session: URLSession(configuration: config)
        )
        return (grant, deviceURL, tokenURL)
    }

    private static func prompt(interval: Int = 5, expiresAt: Date = .distantFuture) -> DeviceCodePrompt {
        DeviceCodePrompt(
            deviceCode: "dev-code",
            userCode: "ABCDEFGH",
            verificationURL: URL(string: "https://www.twitch.tv/activate")!,
            interval: interval,
            expiresAt: expiresAt
        )
    }

    // MARK: Device request

    @Test("start() decodes the device response and posts client_id + scopes")
    func startDecodes() async throws {
        let (grant, deviceURL, _) = Self.grant(device: [(
            json: #"{"device_code":"dev-code","expires_in":1800,"interval":5,"user_code":"ABCDEFGH","verification_uri":"https://www.twitch.tv/activate?public=true&device-code=ABCDEFGH"}"#,
            status: 200
        )])
        let now = Date(timeIntervalSince1970: 1_000_000)

        let prompt = try await grant.start(now: now)

        #expect(prompt.deviceCode == "dev-code")
        #expect(prompt.userCode == "ABCDEFGH")
        #expect(prompt.verificationURL.absoluteString == "https://www.twitch.tv/activate?public=true&device-code=ABCDEFGH")
        #expect(prompt.interval == 5)
        #expect(prompt.expiresAt == now.addingTimeInterval(1800))
        let body = try #require(DeviceCodeStubURLProtocol.bodies(for: deviceURL).first)
        #expect(body == "client_id=client-123&scopes=chat:read%20user:read:email")
    }

    @Test("A missing interval defaults to 5 seconds")
    func missingIntervalDefaults() throws {
        let data = Data(#"{"device_code":"d","expires_in":600,"user_code":"U","verification_uri":"https://www.twitch.tv/activate"}"#.utf8)
        let prompt = try DeviceCodeGrant.parsePrompt(data, now: Date())
        #expect(prompt.interval == 5)
    }

    @Test("start() maps a 4xx to a terminal rejection carrying Twitch's message")
    func startRejected() async throws {
        let (grant, _, _) = Self.grant(device: [(json: #"{"status":400,"message":"invalid client"}"#, status: 400)])
        await #expect(throws: DeviceCodeGrant.Failure.rejected("invalid client")) {
            try await grant.start()
        }
    }

    @Test("start() maps a 5xx to a retryable network error")
    func startServerError() async throws {
        let (grant, _, _) = Self.grant(device: [(json: "{}", status: 503)])
        await #expect(throws: AppError.network(.badServerResponse)) {
            try await grant.start()
        }
    }

    // MARK: Token response parsing

    @Test("200 decodes the token response")
    func tokenDecodes() throws {
        let outcome = try DeviceCodeGrant.parseTokenResponse(Data(Self.success.json.utf8), status: 200)
        #expect(outcome == .authorized(OAuthToken(
            accessToken: "dcf-access",
            refreshToken: "dcf-refresh",
            expiresIn: 14400,
            scope: ["chat:read", "user:read:email"],
            tokenType: "bearer"
        )))
    }

    @Test("Pending / slow_down / expired / denied are classified from Twitch- and RFC-style bodies", arguments: [
        (#"{"status":400,"message":"authorization_pending"}"#, 400, .pending),
        (#"{"error":"authorization_pending"}"#, 400, .pending),
        (#"{"status":400,"message":"slow_down"}"#, 400, .slowDown),
        (#"{"status":429,"message":"Too Many Requests"}"#, 429, .slowDown),
        (#"{"status":400,"message":"invalid device code"}"#, 400, .expired),
        (#"{"error":"expired_token"}"#, 400, .expired),
        (#"{"error":"access_denied"}"#, 400, .denied),
    ] as [(String, Int, DeviceCodeGrant.PollOutcome)])
    func classifiesPollStates(json: String, status: Int, expected: DeviceCodeGrant.PollOutcome) throws {
        #expect(try DeviceCodeGrant.parseTokenResponse(Data(json.utf8), status: status) == expected)
    }

    @Test("An unrecognised 4xx is a terminal rejection")
    func unknownClientErrorRejected() {
        #expect(throws: DeviceCodeGrant.Failure.rejected("invalid client")) {
            try DeviceCodeGrant.parseTokenResponse(Data(#"{"status":400,"message":"invalid client"}"#.utf8), status: 400)
        }
    }

    @Test("A 5xx while polling is a retryable network error, not a terminal state")
    func serverErrorWhilePolling() {
        #expect(throws: AppError.network(.badServerResponse)) {
            try DeviceCodeGrant.parseTokenResponse(Data("{}".utf8), status: 502)
        }
    }

    @Test("exchange() posts the device-code grant")
    func exchangePostsGrant() async throws {
        let (grant, _, tokenURL) = Self.grant(token: [Self.pending])
        #expect(try await grant.exchange(deviceCode: "dev-code") == .pending)
        let body = try #require(DeviceCodeStubURLProtocol.bodies(for: tokenURL).first)
        #expect(body.contains("device_code=dev-code"))
        #expect(body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
        #expect(body.contains("client_id=client-123"))
    }

    // MARK: Polling loop

    @Test("Polls at `interval`, adds 5 s on slow_down, and returns the token")
    func pollingHonoursIntervalAndSlowDown() async throws {
        let (grant, _, tokenURL) = Self.grant(token: [Self.pending, Self.slowDown, Self.pending, Self.success])
        let sleeps = SleepRecorder()

        let token = try await grant.waitForApproval(Self.prompt(interval: 5), sleep: sleeps.sleep)

        #expect(token.accessToken == "dcf-access")
        #expect(token.refreshToken == "dcf-refresh")
        #expect(sleeps.durations == [.seconds(5), .seconds(5), .seconds(10), .seconds(10)])
        #expect(DeviceCodeStubURLProtocol.bodies(for: tokenURL).count == 4)
    }

    @Test("pollImmediately skips the first sleep")
    func pollImmediately() async throws {
        let (grant, _, _) = Self.grant(token: [Self.success])
        let sleeps = SleepRecorder()

        _ = try await grant.waitForApproval(Self.prompt(), pollImmediately: true, sleep: sleeps.sleep)

        #expect(sleeps.durations.isEmpty)
    }

    @Test("Server-reported expiry ends polling with .expired")
    func serverExpiry() async throws {
        let (grant, _, _) = Self.grant(token: [Self.pending, (json: #"{"status":400,"message":"invalid device code"}"#, status: 400)])
        let sleeps = SleepRecorder()

        await #expect(throws: DeviceCodeGrant.Failure.expired) {
            try await grant.waitForApproval(Self.prompt(), sleep: sleeps.sleep)
        }
        #expect(sleeps.durations.count == 2)
    }

    @Test("Denial ends polling with .denied")
    func denial() async throws {
        let (grant, _, _) = Self.grant(token: [(json: #"{"error":"access_denied"}"#, status: 400)])
        await #expect(throws: DeviceCodeGrant.Failure.denied) {
            try await grant.waitForApproval(Self.prompt(), sleep: SleepRecorder().sleep)
        }
    }

    @Test("A locally-expired code throws .expired without polling")
    func localExpiry() async throws {
        let (grant, _, tokenURL) = Self.grant(token: [Self.success])
        let expiresAt = Date(timeIntervalSince1970: 1_000)

        await #expect(throws: DeviceCodeGrant.Failure.expired) {
            try await grant.waitForApproval(
                Self.prompt(expiresAt: expiresAt),
                now: { Date(timeIntervalSince1970: 2_000) },
                sleep: SleepRecorder().sleep
            )
        }
        #expect(DeviceCodeStubURLProtocol.bodies(for: tokenURL).isEmpty)
    }

    @Test("Cancellation during the sleep stops polling without a request")
    func cancellationStopsPolling() async throws {
        let (grant, _, tokenURL) = Self.grant(token: [Self.success])

        await #expect(throws: CancellationError.self) {
            try await grant.waitForApproval(Self.prompt(), sleep: { _ in throw CancellationError() })
        }
        #expect(DeviceCodeStubURLProtocol.bodies(for: tokenURL).isEmpty)
    }

    @Test("slow_down adds five seconds")
    func slowedInterval() {
        #expect(DeviceCodeGrant.slowedInterval(5) == 10)
        #expect(DeviceCodeGrant.slowedInterval(10) == 15)
    }
}
