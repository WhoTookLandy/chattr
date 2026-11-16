import Testing
import Foundation
import Core
import TwitchKit
@testable import Accounts

// MARK: - URLProtocol stub
//
// Keyed by absolute URL (one unique endpoint per test) rather than a single
// static handler: Swift Testing runs tests in parallel, and a shared handler
// would let one test's response serve another's request. Same pattern as
// EmoteSources' ProviderDecodingTests.

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [URL: (Data, Int)] = [:]
    nonisolated(unsafe) static var requestBodies: [URL: Data] = [:]
    static let lock = NSLock()

    static func register(_ url: URL, json: String, statusCode: Int) {
        lock.lock(); defer { lock.unlock() }
        responses[url] = (Data(json.utf8), statusCode)
    }

    static func lookup(_ url: URL) -> (Data, Int)? {
        lock.lock(); defer { lock.unlock() }
        return responses[url]
    }

    static func recordBody(_ data: Data?, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        requestBodies[url] = data
    }

    static func body(for url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return requestBodies[url]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (data, statusCode) = Self.lookup(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        Self.recordBody(Self.bodyData(of: request), for: url)
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into `httpBodyStream` before the protocol
    /// sees the request, so read whichever is present.
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

@Suite("BridgeTokenRefresh (bridge HTTP contract)")
struct BridgeTokenRefreshTests {

    /// A refresher pointed at a unique stub endpoint that answers `json`
    /// with `statusCode`.
    private static func refresher(json: String, statusCode: Int) -> (BridgeTokenRefresh, URL) {
        let url = URL(string: "https://bridge.test/\(UUID().uuidString)/oauth/refresh")!
        StubURLProtocol.register(url, json: json, statusCode: statusCode)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return (BridgeTokenRefresh(endpoint: url, session: URLSession(configuration: config)), url)
    }

    @Test("200 decodes the snake_case response and posts the refresh_token")
    func successDecodes() async throws {
        let (bridge, url) = Self.refresher(json: """
            {"access_token":"new-access","refresh_token":"new-refresh","expires_in":14400,"scope":["chat:read"],"token_type":"bearer"}
            """, statusCode: 200)

        let token = try await bridge.refresh(using: "old-refresh", login: "landy")

        #expect(token.accessToken == "new-access")
        #expect(token.refreshToken == "new-refresh")
        let body = try #require(StubURLProtocol.body(for: url))
        let posted = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(posted == ["refresh_token": "old-refresh"])
    }

    @Test("A response without refresh_token carries the used one forward")
    func carriesRefreshTokenForward() async throws {
        let (bridge, _) = Self.refresher(json: """
            {"access_token":"new-access","expires_in":14400}
            """, statusCode: 200)

        let token = try await bridge.refresh(using: "old-refresh", login: "landy")

        #expect(token.accessToken == "new-access")
        #expect(token.refreshToken == "old-refresh")
    }

    @Test("4xx is a terminal rejection")
    func clientErrorIsRejected() async throws {
        let (bridge, _) = Self.refresher(json: #"{"error":"invalid refresh token"}"#, statusCode: 400)

        await #expect(throws: BridgeTokenRefresh.Rejected(status: 400)) {
            try await bridge.refresh(using: "old-refresh", login: "landy")
        }
    }

    @Test("5xx is a transient bridge failure, not a rejection")
    func serverErrorIsTransient() async throws {
        let (bridge, _) = Self.refresher(json: "{}", statusCode: 503)

        await #expect(throws: AppError.bridgeRefreshFailed(status: 503)) {
            try await bridge.refresh(using: "old-refresh", login: "landy")
        }
    }
}
