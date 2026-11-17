import Testing
import Foundation
import os
import TwitchKit
@testable import Channels

/// The live-event Helix reconcile's cancellation and coalescing, driven
/// through the real `TwitchClient` / `HelixClient` path: a fixture token
/// gets past auth, and a recording `HTTPClient` answers every request with
/// an empty page and can park one until the test releases it.
@Suite("ChannelSession live-event reconcile", .timeLimit(.minutes(1)))
struct ChannelSessionLiveEventsReconcileTests {

    /// Records each Helix request's endpoint (`polls`, `predictions`,
    /// `hypetrain/status`) and parks requests marked with `hold(_:)`.
    private final class RecordingHelixHTTP: HTTPClient {
        private struct State: Sendable {
            var requests: [String] = []
            var holdNext: Set<String> = []
            var held: Set<String> = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        /// Every endpoint as its request reaches the transport.
        let arrivals: AsyncStream<String>
        private let arrival: AsyncStream<String>.Continuation

        init() {
            let stream = AsyncStream.makeStream(of: String.self)
            arrivals = stream.stream
            arrival = stream.continuation
        }

        var requests: [String] { state.withLock { $0.requests } }

        /// Parks the next request to `endpoint` until `release(_:)`.
        func hold(_ endpoint: String) {
            state.withLock { _ = $0.holdNext.insert(endpoint) }
        }

        func release(_ endpoint: String) {
            state.withLock { _ = $0.held.remove(endpoint) }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            let endpoint = String(url.path.dropFirst("/helix/".count))
            let parks = state.withLock { s -> Bool in
                s.requests.append(endpoint)
                guard s.holdNext.remove(endpoint) != nil else { return false }
                s.held.insert(endpoint)
                return true
            }
            arrival.yield(endpoint)
            if parks {
                // Like a slow request on the wire: cancelling the caller
                // doesn't cut the wait short (it runs detached), but once it
                // settles a cancelled caller sees the cancellation, as
                // URLSession reports it.
                let state = self.state
                await Task.detached {
                    while state.withLock({ $0.held.contains(endpoint) }) {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }.value
                if Task.isCancelled { throw URLError(.cancelled) }
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":[]}"#.utf8), response)
        }
    }

    private static let fullPass = ["polls", "predictions", "hypetrain/status"]

    private func makeSession(http: RecordingHelixHTTP, foreground: AppForegroundSignal) -> ChannelSession {
        let client = TwitchClient(
            clientId: "test-client",
            tokenStore: InMemoryTokenStore(token: OAuthToken(accessToken: "fixture-token")),
            httpClient: http
        )
        // Own channel: the only place live events are fetched.
        return ChannelSession(
            client: client,
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "1",
            fetchBackfill: { _, _ in [] },
            appForeground: foreground
        )
    }

    @Test("a foreground pass fetches each kind once")
    func fullPassFetchesEachKind() async {
        let http = RecordingHelixHTTP()
        let session = makeSession(http: http, foreground: AppForegroundSignal())
        await session.reconcileLiveEvents()
        #expect(http.requests == Self.fullPass)
    }

    @Test("not on the own channel: no request at all")
    func otherChannelFetchesNothing() async {
        let http = RecordingHelixHTTP()
        let client = TwitchClient(
            clientId: "test-client",
            tokenStore: InMemoryTokenStore(token: OAuthToken(accessToken: "fixture-token")),
            httpClient: http
        )
        let session = ChannelSession(
            client: client,
            channelId: "2",
            channelLoginName: "other",
            accountUserId: "1",
            fetchBackfill: { _, _ in [] }
        )
        await session.reconcileLiveEvents()
        #expect(http.requests.isEmpty)
    }

    @Test("backgrounding while the poll fetch is in flight cancels the pass: no prediction or Hype Train fetch starts")
    func backgroundingCancelsInFlightPass() async {
        let http = RecordingHelixHTTP()
        let foreground = AppForegroundSignal()
        let session = makeSession(http: http, foreground: foreground)
        var arrivals = http.arrivals.makeAsyncIterator()
        http.hold("polls")

        let pass = Task { await session.reconcileLiveEvents() }
        let first = await arrivals.next()
        #expect(first == "polls")

        foreground.set(false)
        await session.appForegroundDidChange()
        http.release("polls")
        await pass.value
        await session.waitForLiveEventsReconcile()

        #expect(http.requests == ["polls"])
        #expect(await !session.isLiveEventsReconcilePending)
    }

    @Test("the foreground is re-checked before every fetch, even before the session's nudge arrives")
    func foregroundRecheckedBeforeEachFetch() async {
        let http = RecordingHelixHTTP()
        let foreground = AppForegroundSignal()
        let session = makeSession(http: http, foreground: foreground)
        var arrivals = http.arrivals.makeAsyncIterator()
        http.hold("polls")

        let pass = Task { await session.reconcileLiveEvents() }
        let first = await arrivals.next()
        #expect(first == "polls")

        // The flag flips but nothing cancels the pass: the poll answer
        // lands, then the pass stops before the next request.
        foreground.set(false)
        http.release("polls")
        await pass.value

        #expect(http.requests == ["polls"])
    }

    @Test("rapid background → foreground while a pass is in flight: the catch-up runs once, after the cancelled pass exits")
    func rapidBackgroundForegroundRunsCatchUp() async {
        let http = RecordingHelixHTTP()
        let foreground = AppForegroundSignal()
        let session = makeSession(http: http, foreground: foreground)
        var arrivals = http.arrivals.makeAsyncIterator()
        http.hold("polls")

        let pass = Task { await session.reconcileLiveEvents() }
        let first = await arrivals.next()
        #expect(first == "polls")

        // Backgrounded: the parked pass is cancelled but hasn't exited.
        foreground.set(false)
        await session.appForegroundDidChange()

        // Foregrounded before it exits: the catch-up is queued, not dropped.
        foreground.set(true)
        let catchUp = Task { await session.appForegroundDidChange() }
        while await !session.isLiveEventsReconcilePending {
            await Task.yield()
        }
        #expect(http.requests == ["polls"])

        http.release("polls")
        await catchUp.value
        await pass.value

        // The cancelled pass stopped at its poll; exactly one fresh pass
        // followed. Nothing stacked, nothing left queued.
        #expect(http.requests == ["polls"] + Self.fullPass)
        #expect(await !session.isLiveEventsReconcilePending)
    }

    @Test("a queued poll-deadline fetch re-checks the foreground when it runs")
    func pollDeadlineFetchGuardedAtExecution() async {
        let http = RecordingHelixHTTP()
        let foreground = AppForegroundSignal()
        let session = makeSession(http: http, foreground: foreground)

        foreground.set(false)
        await session.fetchPollDeadline(pollId: "poll-1")
        #expect(http.requests.isEmpty)

        foreground.set(true)
        await session.fetchPollDeadline(pollId: "poll-1")
        #expect(http.requests == ["polls"])
    }
}
