# TwitchKit — Network-Resilient EventSub Reconnect + Connection-State Surface

**Status:** approved design — ready for implementation
**Date:** 2026-06-01
**Repo:** `~/Dev/twitch-kit` (shared library; consumed by chattr and Streamly)
**Audience:** a Claude instance working *inside the TwitchKit repo*. This brief is
self-contained — you do not need chattr or Streamly context to implement it.

---

## What this is

`EventSubClient` (in `Sources/TwitchKit/EventSub/EventSubClient.swift`) is an
`actor` that owns the Twitch EventSub WebSocket and a reconnect state machine.
Today reconnection is purely reactive to socket death plus a timed backoff — it
has **no awareness of the OS network path**, and it exposes **no connection
state** to consumers. This work adds both.

The change is additive and backward-compatible. Streamly and chattr both benefit
automatically; neither breaks.

## Background: how reconnect works today

Read these methods in `EventSubClient.swift` before starting:

- `connect(timeout:)` → `openConnection(to:resetReconnectAttempts:timeout:)` —
  opens `URLSession.shared.webSocketTask(with:)`, starts the receive loop, waits
  for `session_welcome`.
- `handleDisconnect()` — called when the socket dies abnormally (receive-loop
  failure, keepalive timeout). Tears down socket state, then if `shouldReconnect`
  is set, spawns `reconnectTask = Task { await attemptReconnect() }`.
- `attemptReconnect()` — the backoff loop. Reads the injected
  `isLive: @Sendable () async -> Bool`:
  - `isLive == true`  → `maxAttempts = .max`, base 0.5s, cap 5s
  - `isLive == false` → `maxAttempts = 5` (**then it gives up**), base 1.0s, cap 30s

  Sleeps `min(base * 2^(attempt-1), cap)`, then `openConnection(...)` +
  `resubscribeAll()`. On failure, recurses.
- `resubscribeAll()` — re-creates every subscription in `desiredSubscriptions`
  against the fresh session. This is what restores chat after any reconnect.
- `disconnect()` — intentional teardown: sets `shouldReconnect = false`, cancels
  everything, clears `sessionId`/`activeSubscriptionsById`.

**Two gaps this causes:**

1. **No path awareness.** During an outage (airplane mode, tunnel, dead zone),
   `attemptReconnect` keeps firing into a dead network, burning attempts and
   battery. When `isLive == false` it exhausts 5 attempts (~30s) and **stops
   forever** — so when the network returns, nothing reconnects. Even when
   `isLive == true`, recovery waits out the current backoff sleep (up to 5s)
   instead of reconnecting the instant the network is back.
2. **No connection state.** Consumers can't show a "Reconnecting…" indicator
   because nothing reports whether the socket is up, retrying, or waiting on the
   network.

## Goals

1. **Path-aware reconnect.** Pause the reconnect loop while the network path is
   unsatisfied; reconnect *immediately* (reset backoff) when it becomes
   satisfied again.
2. **Public connection-state stream** consumers can observe to drive UI.

## Non-goals

- No UI. TwitchKit imports no SwiftUI/UIKit; that stays true.
- Don't change `isLive` backoff semantics for *non-network* socket deaths (a
  Twitch-side drop while the network is fine still uses the existing ladder).
- No Helix/auth changes.
- Don't introduce a full WebSocket-transport mock (out of scope — see Testing).

---

## Design

### 1. `NetworkPathMonitoring` protocol (the testability seam)

`NWPathMonitor` can't be driven from a unit test, so abstract it behind a small
protocol. Add a new file `Sources/TwitchKit/EventSub/NetworkPathMonitoring.swift`:

```swift
import Foundation

/// Binary network-reachability signal. We only care whether a usable path
/// exists — not the interface type (Wi-Fi vs cellular is irrelevant to EventSub
/// reconnect; we never proactively drop a live socket on an interface change).
public enum NetworkPathStatus: Sendable {
    case satisfied
    case unsatisfied
}

/// Abstracts `NWPathMonitor` so the reconnect logic can be unit-tested with a
/// scripted sequence of path changes.
public protocol NetworkPathMonitoring: Sendable {
    /// Emits the current status promptly after `start()`, then on every change.
    /// Single-consumer (matches `EventSubClient.events`).
    var pathUpdates: AsyncStream<NetworkPathStatus> { get }
    func start()
    func cancel()
}
```

Real implementation wrapping `NWPathMonitor` (same file or a sibling):

```swift
import Network

public final class NWPathNetworkMonitor: NetworkPathMonitoring, @unchecked Sendable {
    public let pathUpdates: AsyncStream<NetworkPathStatus>
    private let continuation: AsyncStream<NetworkPathStatus>.Continuation
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.twitchkit.networkpath")

    public init() {
        (pathUpdates, continuation) = AsyncStream.makeStream(of: NetworkPathStatus.self)
        monitor.pathUpdateHandler = { [continuation] path in
            continuation.yield(path.status == .satisfied ? .satisfied : .unsatisfied)
        }
    }
    public func start() { monitor.start(queue: queue) }
    public func cancel() { monitor.cancel(); continuation.finish() }
}
```

### 2. `ConnectionState` (the public surface)

```swift
public enum ConnectionState: Sendable, Equatable {
    case connecting        // initial connect() in progress, no session yet
    case connected         // session_welcome received; live
    case reconnecting      // socket dropped, network is available, retrying
    case waitingForNetwork // socket dropped, network path is unsatisfied — parked
    case disconnected      // intentional disconnect() — not coming back on its own
}
```

Expose on `EventSubClient` exactly like `events`:

```swift
public nonisolated let connectionState: AsyncStream<ConnectionState>
private let connectionStateContinuation: AsyncStream<ConnectionState>.Continuation
```

Initialize in `init` alongside `events`. Emit through a single private helper
that **dedups** so rapid flaps don't spam identical states:

```swift
private var lastEmittedState: ConnectionState?
private func emit(_ state: ConnectionState) {
    guard state != lastEmittedState else { return }
    lastEmittedState = state
    connectionStateContinuation.yield(state)
}
```

Emit at these transitions:
- `connect()` begins (no session yet) → `.connecting`
- `session_welcome` received (in the welcome path) → `.connected`
- `handleDisconnect()` while network **available** → `.reconnecting`
- network **unavailable** (path `.unsatisfied`, or disconnect happens while it is) → `.waitingForNetwork`
- `disconnect()` → `.disconnected`

> **Single-consumer contract.** Like `events`, `connectionState` is consumed by
> exactly one iterator. Consumers must begin iterating *before/around*
> `connect()` so they observe the initial `.connecting`/`.connected` transitions;
> there is no value replay for late subscribers. Document this on the property.

### 3. `EventSubClient` integration

Add stored state:
```swift
private let pathMonitor: NetworkPathMonitoring
private var pathMonitorTask: Task<Void, Never>?
private var isNetworkAvailable = true   // optimistic until told otherwise
```

Init gains a defaulted parameter (keeps existing call sites compiling):
```swift
public init(
    api: HelixClient,
    isLive: @escaping @Sendable () async -> Bool,
    pathMonitor: NetworkPathMonitoring = NWPathNetworkMonitor(),
    eventBufferingPolicy: ... = .bufferingNewest(1_000)
)
```

Start observing the path inside `connect()` (so monitoring is tied to an
intended-connected lifecycle), and tear it down in `disconnect()`/`deinit`:

```swift
// in connect(), before opening:
startPathMonitorIfNeeded()

private func startPathMonitorIfNeeded() {
    guard pathMonitorTask == nil else { return }
    pathMonitor.start()
    pathMonitorTask = Task { [weak self] in
        guard let self else { return }
        for await status in self.pathMonitor.pathUpdates {
            await self.handlePathStatus(status)
        }
    }
}

private func handlePathStatus(_ status: NetworkPathStatus) {
    switch status {
    case .unsatisfied:
        isNetworkAvailable = false
        // Stop hammering a dead network: cancel the in-flight backoff sleep.
        reconnectTask?.cancel()
        reconnectTask = nil
        if sessionId == nil { emit(.waitingForNetwork) }
    case .satisfied:
        let wasOffline = !isNetworkAvailable
        isNetworkAvailable = true
        // Reconnect immediately if we *want* to be connected but aren't.
        if wasOffline, shouldReconnect, sessionId == nil {
            reconnectAttempts = 0           // reset backoff — restore is "attempt 1"
            reconnectTask?.cancel()
            emit(.reconnecting)
            reconnectTask = Task { await attemptReconnect() }
        }
    }
}
```

Guard the backoff loop so it never runs while offline:
```swift
private func attemptReconnect() async {
    guard shouldReconnect else { return }
    guard isNetworkAvailable else { emit(.waitingForNetwork); return }  // park
    ...existing body...
}
```

And in `handleDisconnect()`, choose the emitted state by current path:
```swift
guard shouldReconnect else { return }
if isNetworkAvailable {
    emit(.reconnecting)
    reconnectTask?.cancel()
    reconnectTask = Task { await attemptReconnect() }
} else {
    emit(.waitingForNetwork)   // parked; handlePathStatus(.satisfied) will resume
}
```

Cleanup: `disconnect()` and `deinit` must `pathMonitorTask?.cancel()` +
`pathMonitor.cancel()`, and `disconnect()` should `emit(.disconnected)`.

> **Note on `isLive`.** Keep it. With path-awareness, `isLive` still governs the
> backoff ladder for non-network drops (Twitch-side close, keepalive timeout
> while the network is fine). The path monitor handles the *offline* case
> orthogonally — when the network returns, reconnect resumes regardless of how
> many attempts the `isLive == false` ladder had burned, because
> `handlePathStatus(.satisfied)` resets `reconnectAttempts` and re-enters the loop.

### 4. `TwitchClient` forwarding

`TwitchClient.init` constructs the `EventSubClient`. Add a defaulted
`pathMonitor: NetworkPathMonitoring = NWPathNetworkMonitor()` parameter and
forward it. Re-expose `eventSub.connectionState` if `TwitchClient` proxies the
EventSub surface (follow whatever pattern it already uses for `events`).

---

## Testing

`EventSubClient` opens `URLSession.shared.webSocketTask` directly — there is **no
socket seam**, so do *not* attempt a full socket-level reconnect integration test
here. Test the network-transition *logic* deterministically instead.

1. **`MockNetworkPathMonitor`** — a `NetworkPathMonitoring` whose `pathUpdates`
   is backed by a continuation a test can drive (`yield(.unsatisfied)` /
   `yield(.satisfied)`).

2. **Extract the reconnect *decision* into a pure, testable helper.** Replace the
   inline ladder math + gate with a free function or small `struct`:

   ```swift
   struct ReconnectDecision: Equatable {
       enum Action: Equatable { case park, attempt(delay: Duration) }
       let action: Action
   }
   func reconnectDecision(networkAvailable: Bool, shouldReconnect: Bool,
                          isLive: Bool, attempt: Int) -> ReconnectDecision
   ```

   Unit-test it directly: offline → `.park`; `isLive == false` past attempt 5 →
   `.park` (give up); live → `.attempt` with the expected capped delay; etc.
   `attemptReconnect` calls this helper instead of inlining the logic.

3. **State-emission tests** (driving the `MockNetworkPathMonitor` + the public
   `connectionState` stream): assert the sequence
   `.connecting → .connected → (path .unsatisfied) .waitingForNetwork →
   (path .satisfied) .reconnecting → …`. If reaching `.connected` requires a real
   socket, stop the assertion at `.reconnecting` (the first post-restore emission)
   — that is the behavior this feature owns.

4. Follow the existing test style in `Tests/TwitchKitTests/` (Swift Testing,
   fixture-driven). See `EventSubMessageTests.swift` for the EventSub test setup.

---

## Backward compatibility & release

- All new init parameters are defaulted; `connectionState` is additive. Existing
  `EventSubClient`/`TwitchClient` call sites compile unchanged.
- Streamly gets path-aware reconnect for free (it already runs `EventSubClient`).
- **Tag a new minor version** (current is `v0.1.x` → cut **`v0.2.0`**) and add a
  CHANGELOG entry: "EventSub: network-path-aware reconnect + public
  `connectionState` stream." chattr will pin to `v0.2.0`.

## Deliverable checklist for the TwitchKit instance

- [ ] `NetworkPathMonitoring` protocol + `NetworkPathStatus` enum + `NWPathNetworkMonitor`
- [ ] `ConnectionState` enum + `connectionState` stream on `EventSubClient` (+ dedup `emit`)
- [ ] Path observation in `EventSubClient` (`handlePathStatus`, offline gate in `attemptReconnect`, state choice in `handleDisconnect`, cleanup in `disconnect`/`deinit`)
- [ ] `reconnectDecision(...)` pure helper, with the ladder + gate logic
- [ ] `TwitchClient` forwards `pathMonitor` + re-exposes `connectionState`
- [ ] Unit tests: `reconnectDecision` table, mock-path state-emission sequence
- [ ] CHANGELOG + `v0.2.0` tag
