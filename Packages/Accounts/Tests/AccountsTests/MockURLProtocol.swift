import Foundation

/// Minimal `URLProtocol` that returns a canned `(status, body)` for any
/// request, so a `URLSession` can be driven without real networking.
///
/// The stub is a shared static because the system instantiates `URLProtocol`
/// subclasses itself (we can't pass per-instance state). Suites that use it
/// must be `.serialized` so only one test sets/reads `stub` at a time; the
/// test sets `stub` before the request and clears it after the await, so the
/// background read in `startLoading` is ordered behind that write.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stub: (status: Int, body: Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A `URLSession` whose only protocol is `MockURLProtocol`.
func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}
