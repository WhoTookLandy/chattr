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
            /// Parked and not yet released.
            var held: Set<String> = []
            /// The parked request's gate, once it has started waiting.
            /// `release(_:)` may land before or after this is stored.
            var gates: [String: CheckedContinuation<Void, Never>] = [:]
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
            let gate = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.held.remove(endpoint)
                return s.gates.removeValue(forKey: endpoint)
            }
            gate?.resume()
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
                    await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                        let alreadyReleased = state.withLock { s -> Bool in
                            guard s.held.contains(endpoint) else { return true }
                            s.gates[endpoint] = gate
                            return false
                        }
                        if alreadyReleased { gate.resume() }
                    }
                }.value
                if Task.isCancelled { throw URLError(.cancelled) }
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"data":[]}"#.utf8), response)
        }
    }

    private static let fullPass = ["polls", "predictions", "hypetrain/status"]

    private struct RefreshUnavailable: Error {}

    /// Counts bridge refreshes; the handler itself is supplied per test.
    private final class RefreshCounter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    /// A sign-in that granted the three live-event scopes.
    private static let scopedToken = OAuthToken(
        accessToken: "fixture-token",
        scope: [
            TwitchScope.channelReadPolls.rawValue,
            TwitchScope.channelReadPredictions.rawValue,
            TwitchScope.channelReadHypeTrain.rawValue,
        ]
    )

    private func makeClient(http: RecordingHelixHTTP, token: OAuthToken? = Self.scopedToken) -> TwitchClient {
        TwitchClient(
            clientId: "test-client",
            tokenStore: InMemoryTokenStore(token: token),
            httpClient: http
        )
    }

    private func makeSession(
        http: RecordingHelixHTTP,
        foreground: AppForegroundSignal,
        token: OAuthToken? = Self.scopedToken
    ) -> ChannelSession {
        makeSession(client: makeClient(http: http, token: token), foreground: foreground)
    }

    private func makeSession(
        client: TwitchClient,
        foreground: AppForegroundSignal,
        refreshTokenHandler: @escaping @Sendable () async throws -> Void = {
            throw RefreshUnavailable()
        }
    ) -> ChannelSession {
        // Own channel: the only place live events are fetched.
        ChannelSession(
            client: client,
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "1",
            refreshTokenHandler: refreshTokenHandler,
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

    // MARK: - Auth: scope pre-check + bridge-refresh retry

    @Test("a sign-in without the live-event scopes sends nothing and never refreshes")
    func unscopedTokenSendsNothing() async {
        let http = RecordingHelixHTTP()
        let refreshes = RefreshCounter()
        let client = makeClient(http: http, token: OAuthToken(accessToken: "old-token", scope: ["chat:read"]))
        let session = makeSession(client: client, foreground: AppForegroundSignal()) {
            refreshes.increment()
        }

        await session.reconcileLiveEvents()
        await session.fetchPollDeadline(pollId: "poll-1")

        // No request ever reached `HelixClient`, so its destructive 401
        // refresh could not run; refreshing never adds a scope, so no
        // bridge refresh either.
        #expect(http.requests.isEmpty)
        #expect(refreshes.value == 0)
    }

    @Test("a token with no recorded scope list fails closed")
    func scopelessTokenFailsClosed() async {
        let http = RecordingHelixHTTP()
        let session = makeSession(http: http, foreground: AppForegroundSignal(), token: OAuthToken(accessToken: "fixture-token"))
        await session.reconcileLiveEvents()
        #expect(http.requests.isEmpty)
    }

    @Test("no token at the seed: the bridge refresh restores it and the pass still goes out")
    func missingTokenRefreshesThenFetches() async {
        let http = RecordingHelixHTTP()
        let refreshes = RefreshCounter()
        let client = makeClient(http: http, token: nil)
        let scoped = Self.scopedToken
        let session = makeSession(client: client, foreground: AppForegroundSignal()) {
            refreshes.increment()
            try await client.auth.tokenProvider.setToken(scoped)
        }

        await session.reconcileLiveEvents()

        // One refresh (on the poll read); the later kinds find the token.
        #expect(http.requests == Self.fullPass)
        #expect(refreshes.value == 1)
    }

    // MARK: - Foreground transitions

    @Test("both nudges of a background → foreground flip arrive after the flag is back: one catch-up pass")
    func delayedForegroundNudgesStillCatchUp() async {
        let http = RecordingHelixHTTP()
        let foreground = AppForegroundSignal()
        let session = makeSession(http: http, foreground: foreground)

        // The registry flips the flag twice before either nudge runs.
        foreground.set(false)
        foreground.set(true)
        #expect(foreground.isInForeground)

        // Both delayed nudges land now. The flag reads `true` both times,
        // as it did before; the transition generation is what moved.
        await session.appForegroundDidChange()
        await session.appForegroundDidChange()

        #expect(http.requests == Self.fullPass)
        #expect(await !session.isLiveEventsReconcilePending)
    }

    @Test("a nudge with no transition since the last one is a no-op")
    func repeatedNudgeIsNoOp() async {
        let http = RecordingHelixHTTP()
        let session = makeSession(http: http, foreground: AppForegroundSignal())
        await session.appForegroundDidChange()
        #expect(http.requests.isEmpty)
    }
}
