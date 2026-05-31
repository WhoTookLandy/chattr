# chattr Network-Transition Handling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make chattr's chat reconnect robustly across network transitions and show a calm "Reconnecting… / Live again" indicator, by consuming TwitchKit v0.2.0's path-aware reconnect + `connectionState` stream.

**Architecture:** A `SessionActivitySignal` (Core) lets `AccountStore` answer "is any channel open?" so it can pass a real `isLive` into the EventSub client (fixing the always-`false` give-up bug). `ChannelSessionRegistry` increments/decrements that signal in `acquire`/`release`, and runs one per-account task that pipes `client.eventSub.connectionState` into a registry-owned `@Observable ConnectionStatusStore`. `ChatScreen` reads that store and renders a transient glass pill via a pure `ConnectionBanner` reducer.

**Tech Stack:** Swift 6.2 (language mode 6, strict concurrency), `@MainActor`, `@Observable`, `OSAllocatedUnfairLock`, SwiftUI Liquid Glass (`.glassEffect`), Swift Testing. Depends on **TwitchKit ≥ v0.2.0** (`ConnectionState` enum + `EventSubClient.connectionState: AsyncStream<ConnectionState>`).

**Spec:** `docs/superpowers/specs/2026-06-01-chattr-network-transition-design.md`
**Upstream spec (separate repo):** `docs/superpowers/specs/2026-06-01-twitchkit-network-resilience-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `Packages/Core/Sources/Core/SessionActivitySignal.swift` | Thread-safe "≥1 channel open?" flag | Create |
| `Packages/Core/Tests/CoreTests/SessionActivitySignalTests.swift` | Unit tests for the signal | Create |
| `Packages/Accounts/Sources/Accounts/AccountStore.swift` | Owns the signal; passes real `isLive` into persistent clients | Modify |
| `Packages/Channels/Sources/Channels/ConnectionStatusStore.swift` | Per-account `@Observable` mirror of `ConnectionState` | Create |
| `Packages/Channels/Tests/ChannelsTests/ConnectionStatusStoreTests.swift` | Unit test the store | Create |
| `Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift` | Signal inc/dec; per-account connection dispatcher + accessor | Modify |
| `Packages/Features/Sources/Features/ConnectionBanner.swift` | Pure reducer: `(prev, current) → banner` | Create |
| `Packages/Features/Tests/FeaturesTests/ConnectionBannerTests.swift` | Unit test the reducer | Create |
| `Packages/Features/Sources/Features/ChatScreen.swift` | `connectionStatus` accessor + header pill | Modify |

**Unit-tested (pure/logic):** `SessionActivitySignal`, `ConnectionStatusStore`, `ConnectionBanner`.
**Manually verified (needs a live socket):** registry wiring + the airplane-mode end-to-end (Task 8). The registry isn't unit-tested today; we follow that existing boundary rather than building a client mock.

---

## Task 0: Prerequisite — TwitchKit v0.2.0 resolved

**Files:**
- Modify: `Packages/*/Package.swift` only if pinning changes (today they use `branch: "main"`)

This plan is **blocked** until TwitchKit's `2026-06-01-twitchkit-network-resilience-design.md` is merged to `main` and tagged `v0.2.0`. chattr's packages track `branch: "main"`, so resolving the new commit is an update, not a pin change.

- [ ] **Step 1: Update the resolved TwitchKit**

Run:
```bash
cd /Users/landy/Dev/chattr
xcodebuild -resolvePackageDependencies -scheme chattr 2>&1 | tail -5
```
(Or in Xcode: File → Packages → Update to Latest Package Versions.)

- [ ] **Step 2: Verify the new surface exists**

Run:
```bash
cd /Users/landy/Dev/chattr
grep -rn "case waitingForNetwork" ~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/TwitchKit/Sources 2>/dev/null | head -1
```
Expected: a match in `EventSubClient.swift` (or wherever `ConnectionState` is defined). If empty, TwitchKit v0.2.0 hasn't landed yet — **stop**; do not start Task 4+.

> Tasks 1–3 (Core signal + `isLive`) do **not** depend on the new TwitchKit surface and may proceed regardless. Tasks 4, 5, 7 reference `ConnectionState` and require Task 0 to be green.

---

## Task 1: `SessionActivitySignal` in Core

**Files:**
- Create: `Packages/Core/Sources/Core/SessionActivitySignal.swift`
- Test: `Packages/Core/Tests/CoreTests/SessionActivitySignalTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Core/Tests/CoreTests/SessionActivitySignalTests.swift`:
```swift
import Testing
@testable import Core

@Suite("SessionActivitySignal")
struct SessionActivitySignalTests {
    @Test("Starts with no active sessions")
    func startsInactive() {
        let signal = SessionActivitySignal()
        #expect(signal.hasActiveSessions == false)
    }

    @Test("Active after an increment, inactive after the matching decrement")
    func incrementDecrement() {
        let signal = SessionActivitySignal()
        signal.increment()
        #expect(signal.hasActiveSessions == true)
        signal.decrement()
        #expect(signal.hasActiveSessions == false)
    }

    @Test("Stays active while any increment outstanding")
    func balancedCounting() {
        let signal = SessionActivitySignal()
        signal.increment()
        signal.increment()
        signal.decrement()
        #expect(signal.hasActiveSessions == true)   // one still open
        signal.decrement()
        #expect(signal.hasActiveSessions == false)
    }

    @Test("Decrement never underflows below zero")
    func noUnderflow() {
        let signal = SessionActivitySignal()
        signal.decrement()                          // spurious release
        #expect(signal.hasActiveSessions == false)
        signal.increment()
        #expect(signal.hasActiveSessions == true)   // count is 1, not 2
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Core && swift test --filter SessionActivitySignal 2>&1 | tail -15
```
Expected: FAIL — `cannot find 'SessionActivitySignal' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Core/Sources/Core/SessionActivitySignal.swift`:
```swift
import os

/// Process-wide "is any chat channel currently open?" flag.
///
/// Resolves a dependency-direction problem: `AccountStore` (in `Accounts`)
/// builds the EventSub-backed `TwitchClient` and needs an `isLive` closure, but
/// "open channels" is known to `ChannelSessionRegistry` (in `Channels`, which
/// depends on `Accounts` — not the reverse). Both packages depend on `Core`, so
/// the shared signal lives here.
///
/// `isLive == true` (any active session) makes EventSub retry reconnection
/// indefinitely with fast backoff; `false` makes it give up after a few
/// attempts. Without this, chattr always passed the default `{ false }`, so a
/// channel went permanently dead after a ~30s network outage.
///
/// Sendable + lock-guarded: read from a `@Sendable` `isLive` closure on an
/// arbitrary executor, written from the `@MainActor` registry.
public final class SessionActivitySignal: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    /// One open channel began. Pair with exactly one `decrement()`.
    public func increment() {
        count.withLock { $0 += 1 }
    }

    /// One open channel ended. Clamped at zero so a spurious release can't
    /// drive the count negative and mask later real activity.
    public func decrement() {
        count.withLock { $0 = max(0, $0 - 1) }
    }

    /// True while at least one channel is open.
    public var hasActiveSessions: Bool {
        count.withLock { $0 > 0 }
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Core && swift test --filter SessionActivitySignal 2>&1 | tail -15
```
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Core/Sources/Core/SessionActivitySignal.swift Packages/Core/Tests/CoreTests/SessionActivitySignalTests.swift
git commit -m "Core: SessionActivitySignal (shared 'any channel open?' flag)"
```

---

## Task 2: AccountStore owns the signal + wires `isLive`

**Files:**
- Modify: `Packages/Accounts/Sources/Accounts/AccountStore.swift` (init ~line 32; `client(forUserId:)` ~line 100-110; `add(...)` persistent client ~line 128-131)

No test: `AccountStore` is `@MainActor` + SwiftData-bound and isn't unit-tested today. The `isLive` behavior is exercised by Task 8's manual check; the signal logic is already covered by Task 1.

- [ ] **Step 1: Expose the signal as a stored property**

In `AccountStore` (after `private var clients: [String: TwitchClient] = [:]` ~line 27), add:
```swift
    /// Shared "any channel open?" flag. The registry increments/decrements it;
    /// the persistent EventSub clients read it via their `isLive` closure so
    /// reconnect stays aggressive while a channel is open. (See SessionActivitySignal.)
    public let sessionActivity = SessionActivitySignal()
```

- [ ] **Step 2: Pass `isLive` into the cached persistent client**

In `client(forUserId:)`, replace the `TwitchClient(...)` construction:
```swift
        let client = TwitchClient(
            clientId: clientId,
            tokenNamespace: Self.namespace(for: userId)
        )
```
with (capture the Sendable signal — NOT `self`):
```swift
        let signal = sessionActivity
        let client = TwitchClient(
            clientId: clientId,
            tokenNamespace: Self.namespace(for: userId),
            isLive: { signal.hasActiveSessions }
        )
```

- [ ] **Step 3: Pass `isLive` into the `add(...)` persistent client**

In `add(token:scopes:)`, the persistent client (~line 128) currently:
```swift
        let persistent = TwitchClient(
            clientId: clientId,
            tokenNamespace: namespace
        )
```
becomes:
```swift
        let signal = sessionActivity
        let persistent = TwitchClient(
            clientId: clientId,
            tokenNamespace: namespace,
            isLive: { signal.hasActiveSessions }
        )
```
> Leave the one-shot `probe` client (in-memory store, Helix-only, ~line 117) untouched — it has no EventSub socket, so `isLive` is irrelevant there.

- [ ] **Step 4: Build**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Accounts && swift build 2>&1 | tail -5
```
Expected: `Build complete!` (No isolation error: the closure captures only `signal`, which is `Sendable`.)

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Accounts/Sources/Accounts/AccountStore.swift
git commit -m "Accounts: wire isLive from SessionActivitySignal into persistent clients"
```

---

## Task 3: Registry drives the signal in acquire/release

**Files:**
- Modify: `Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift` (`acquire(...)` ~line 214-241; `release(...)` ~line 250-309)

No unit test (registry not unit-tested today); covered by Task 8.

- [ ] **Step 1: Increment on acquire**

In `acquire(...)`, immediately after `refCounts[key, default: 0] += 1`, add:
```swift
        accountStore.sessionActivity.increment()
```
And in the `catch` block that rolls back the refcount (where `refCounts[key, default: 1] -= 1`), add a matching rollback so a failed acquire doesn't leave the signal inflated:
```swift
            accountStore.sessionActivity.decrement()
```

- [ ] **Step 2: Decrement on release**

In `release(...)`, the count is decremented after the `guard let count = refCounts[key], count > 0`. Right after `refCounts[key] = count - 1`, add:
```swift
        accountStore.sessionActivity.decrement()
```
> Symmetry check: every `acquire` increments once (rolled back on failure); every successful `release` decrements once. The early-return `guard` path (no outstanding refcount) does NOT decrement — correct, because that release has no matching acquire.

- [ ] **Step 3: Build**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift
git commit -m "Channels: track open-channel count in SessionActivitySignal"
```

---

## Task 4: `ConnectionStatusStore` (Channels) — requires Task 0

**Files:**
- Create: `Packages/Channels/Sources/Channels/ConnectionStatusStore.swift`
- Test: `Packages/Channels/Tests/ChannelsTests/ConnectionStatusStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Channels/Tests/ChannelsTests/ConnectionStatusStoreTests.swift`:
```swift
import Testing
import TwitchKit
@testable import Channels

@MainActor
@Suite("ConnectionStatusStore")
struct ConnectionStatusStoreTests {
    @Test("Defaults to .connecting")
    func defaultState() {
        let store = ConnectionStatusStore()
        #expect(store.state == .connecting)
    }

    @Test("update(_:) reflects the latest connection state")
    func updates() {
        let store = ConnectionStatusStore()
        store.update(.connected)
        #expect(store.state == .connected)
        store.update(.waitingForNetwork)
        #expect(store.state == .waitingForNetwork)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift test --filter ConnectionStatusStore 2>&1 | tail -15
```
Expected: FAIL — `cannot find 'ConnectionStatusStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Channels/Sources/Channels/ConnectionStatusStore.swift`:
```swift
import TwitchKit

/// Registry-owned, per-account mirror of the EventSub WebSocket's
/// `ConnectionState`. `@Observable` so a `ChatScreen` reading it re-renders its
/// connection pill when the socket drops or recovers.
///
/// Keyed per *account* (not per channel) because one WebSocket per account is
/// shared by all that account's open channels — they all reflect the same
/// connection state. Lifetime matches the account's event dispatcher: created
/// with the first session for the account, dropped when the last one closes.
@MainActor
@Observable
public final class ConnectionStatusStore {
    /// Latest state from `EventSubClient.connectionState`. Starts optimistic at
    /// `.connecting` (matches what the client emits on its initial connect),
    /// so the pill stays hidden on a normal cold start.
    public private(set) var state: ConnectionState = .connecting

    public init() {}

    func update(_ newState: ConnectionState) {
        state = newState
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift test --filter ConnectionStatusStore 2>&1 | tail -15
```
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Channels/Sources/Channels/ConnectionStatusStore.swift Packages/Channels/Tests/ChannelsTests/ConnectionStatusStoreTests.swift
git commit -m "Channels: ConnectionStatusStore (per-account @Observable state mirror)"
```

---

## Task 5: Registry per-account connection dispatcher + accessor — requires Task 0, 4

**Files:**
- Modify: `Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift` (stored props ~line 77-115; `ensureEventDispatch` ~line 390-403; `stopDispatcherIfIdle` ~line 373-386)

No unit test (registry not unit-tested today); covered by Task 8.

- [ ] **Step 1: Add stored state**

Near the other per-account/per-key maps (after `private var eventDispatchTasks: [String: Task<Void, Never>] = [:]`), add:
```swift
    /// Per-account connection-state mirrors, keyed by `accountUserId`. One per
    /// account because the EventSub socket is per account.
    private var connectionStatusStores: [String: ConnectionStatusStore] = [:]

    /// Per-account tasks consuming `client.eventSub.connectionState`. Started
    /// alongside the event dispatcher; cancelled in `stopDispatcherIfIdle`.
    private var connectionDispatchTasks: [String: Task<Void, Never>] = [:]
```

- [ ] **Step 2: Add the public accessor**

Near `emoteIndex(forAccountUserId:channelId:)` / `badgeStore(...)`, add:
```swift
    /// Returns (creating if needed) the per-account connection-state store. A
    /// `ChatScreen` observes this to drive its "Reconnecting… / Live again"
    /// pill. Same lifetime as the account's event dispatcher.
    public func connectionStatus(forAccountUserId accountUserId: String) -> ConnectionStatusStore {
        if let existing = connectionStatusStores[accountUserId] {
            return existing
        }
        let new = ConnectionStatusStore()
        connectionStatusStores[accountUserId] = new
        return new
    }
```

- [ ] **Step 3: Start the connection dispatcher alongside the event dispatcher**

In `ensureEventDispatch(client:accountUserId:)`, after the existing
`eventDispatchTasks[accountUserId] = Task { ... }` block (and its log line), add a
second task that pipes connection state into the store. Place it before the
closing of the method:
```swift
        // Per-account connection-state pump. Consumes the single-consumer
        // `connectionState` stream and mirrors it into the @Observable store the
        // ChatScreen reads. Started here (with the event dispatcher) so it begins
        // before connect() and observes the initial .connecting/.connected
        // transitions — the stream has no value replay for late subscribers.
        if connectionDispatchTasks[accountUserId] == nil {
            let store = connectionStatus(forAccountUserId: accountUserId)
            connectionDispatchTasks[accountUserId] = Task { @MainActor in
                for await state in client.eventSub.connectionState {
                    guard !Task.isCancelled else { return }
                    store.update(state)
                }
            }
        }
```
> Placement: `ensureEventDispatch` early-returns at the top when
> `eventDispatchTasks[accountUserId] != nil`, so this block runs on the **first**
> call for the account — the same call that starts the event dispatcher. Both are
> created together and torn down together (Step 4), so they share the account's
> lifetime. The inner `connectionDispatchTasks[...] == nil` guard is belt-and-
> suspenders, making the block safe even if the placement ever changes.

- [ ] **Step 4: Tear it down when the account goes idle**

In `stopDispatcherIfIdle(accountUserId:)`, after the existing
`eventDispatchTasks[accountUserId] = nil` cleanup, add:
```swift
        connectionDispatchTasks[accountUserId]?.cancel()
        connectionDispatchTasks[accountUserId] = nil
        connectionStatusStores[accountUserId] = nil
```
> This sits inside the block that already established "no remaining sessions for
> this account," so it only runs when the last channel for the account closed.

- [ ] **Step 5: Build**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift
git commit -m "Channels: per-account connection-state dispatcher + accessor"
```

---

## Task 6: `ConnectionBanner` pure reducer (Features) — requires Task 0

**Files:**
- Create: `Packages/Features/Sources/Features/ConnectionBanner.swift`
- Test: `Packages/Features/Tests/FeaturesTests/ConnectionBannerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Tests/FeaturesTests/ConnectionBannerTests.swift`:
```swift
import Testing
import TwitchKit
@testable import Features

@Suite("ConnectionBanner")
struct ConnectionBannerTests {
    @Test("Down states show Reconnecting")
    func downStates() {
        #expect(ConnectionBanner.next(previous: .connected, current: .reconnecting) == .reconnecting)
        #expect(ConnectionBanner.next(previous: .connected, current: .waitingForNetwork) == .reconnecting)
    }

    @Test("Recovering from a down state shows Live again")
    func recovery() {
        #expect(ConnectionBanner.next(previous: .reconnecting, current: .connected) == .liveAgain)
        #expect(ConnectionBanner.next(previous: .waitingForNetwork, current: .connected) == .liveAgain)
    }

    @Test("Steady connected is hidden")
    func steadyConnected() {
        #expect(ConnectionBanner.next(previous: .connected, current: .connected) == .hidden)
        #expect(ConnectionBanner.next(previous: nil, current: .connected) == .hidden)
    }

    @Test("Connecting and disconnected are hidden")
    func connectingAndDisconnected() {
        #expect(ConnectionBanner.next(previous: nil, current: .connecting) == .hidden)
        #expect(ConnectionBanner.next(previous: .connected, current: .disconnected) == .hidden)
    }

    @Test("First-ever connect (nil → connected) does not flash Live again")
    func firstConnectNoFlash() {
        // Cold start lands on .connected with no prior down state — must stay hidden.
        #expect(ConnectionBanner.next(previous: nil, current: .connected) == .hidden)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test --filter ConnectionBanner 2>&1 | tail -15
```
Expected: FAIL — `cannot find 'ConnectionBanner' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Features/Sources/Features/ConnectionBanner.swift`:
```swift
import TwitchKit

/// What the channel-header connection pill should show, derived purely from a
/// `ConnectionState` transition. The view owns the auto-dismiss timer for
/// `.liveAgain`; this type owns the *decision*, so it's unit-testable.
enum ConnectionBanner: Equatable {
    case hidden
    case reconnecting
    case liveAgain

    /// Map a state transition to a banner.
    ///
    /// - `.reconnecting` / `.waitingForNetwork` → show "Reconnecting…".
    /// - transition INTO `.connected` FROM a down state → flash "Live again".
    /// - steady `.connected`, initial `.connecting`, intentional `.disconnected`
    ///   → hidden. A first-ever connect (`previous == nil`) must NOT flash, so
    ///   `.liveAgain` requires a genuine prior down state.
    static func next(previous: ConnectionState?, current: ConnectionState) -> ConnectionBanner {
        switch current {
        case .reconnecting, .waitingForNetwork:
            return .reconnecting
        case .connected:
            switch previous {
            case .reconnecting, .waitingForNetwork:
                return .liveAgain
            default:
                return .hidden
            }
        case .connecting, .disconnected:
            return .hidden
        }
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test --filter ConnectionBanner 2>&1 | tail -15
```
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/ConnectionBanner.swift Packages/Features/Tests/FeaturesTests/ConnectionBannerTests.swift
git commit -m "Features: ConnectionBanner pure reducer (state transition → pill)"
```

---

## Task 7: ChatScreen connection pill — requires Task 0, 5, 6

**Files:**
- Modify: `Packages/Features/Sources/Features/ChatScreen.swift` (accessor block ~line 50-70; channel-header area; `@State` block ~line 87-98)

No unit test (the reducer is covered by Task 6; this is view wiring); covered by Task 8.

- [ ] **Step 1: Add the `connectionStatus` convenience accessor**

After the `emoteIndex` convenience var (~line 67), add:
```swift
    /// Convenience: pull the registry-owned per-account connection-state store.
    /// Same nil semantics as `badgeStore` / `emoteIndex` above.
    private var connectionStatus: ConnectionStatusStore? {
        channelSessionRegistry?.connectionStatus(forAccountUserId: account.userId)
    }
```

- [ ] **Step 2: Add banner state**

In the `@State` block (near `@State private var unreadWhileScrolledUp = 0` ~line 87), add:
```swift
    /// Current connection pill, derived from connection-state transitions.
    @State private var connectionBanner: ConnectionBanner = .hidden
    /// Cancels the in-flight "Live again" auto-dismiss when state changes again.
    @State private var liveAgainDismiss: Task<Void, Never>?
```

- [ ] **Step 3: Add the pill view**

Add a computed view near `jumpToBottomPill` (~line 587), mirroring its glass styling:
```swift
    /// Transient connection indicator. "Reconnecting…" while the socket is down,
    /// a brief "Live again" on recovery, hidden otherwise. Same quiet glass
    /// capsule as the jump-to-latest pill.
    @ViewBuilder
    private var connectionPill: some View {
        if connectionBanner != .hidden {
            HStack(spacing: 4) {
                Image(systemName: connectionBanner == .liveAgain ? "checkmark" : "wifi.exclamationmark")
                    .font(.caption2.weight(.semibold))
                Text(connectionBanner == .liveAgain ? "Live again" : "Reconnecting…")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(connectionBanner == .liveAgain ? "Connection restored" : "Reconnecting")
        }
    }
```

- [ ] **Step 4: Overlay the pill at the top of the chat area**

Find the chat scroll container that already has `.overlay(alignment: .bottom) { ... jumpToBottomPill }` (~line 572). Add a sibling top overlay on the same view:
```swift
        .overlay(alignment: .top) {
            connectionPill
                .padding(.top, 8)
                .animation(.snappy, value: connectionBanner)
        }
```

- [ ] **Step 5: Drive the banner from connection-state changes**

On the same chat view (near the existing `.onChange`/`.onScrollGeometryChange` modifiers ~line 558-566), add an observer of the store's state. Because `ConnectionStatusStore` is `@Observable`, read `connectionStatus?.state` and react with `.onChange`:
```swift
        .onChange(of: connectionStatus?.state) { previous, current in
            guard let current else { return }
            // `previous` and `current` are both `ConnectionState?` (the observed
            // expression is a single optional). Pass `previous` straight through;
            // the reducer treats `nil` as "no prior state → no Live-again flash."
            connectionBanner = ConnectionBanner.next(previous: previous, current: current)
            liveAgainDismiss?.cancel()
            if connectionBanner == .liveAgain {
                // Auto-dismiss "Live again" after a beat. Re-entry of this
                // onChange (state changes again) cancels this via the line above.
                liveAgainDismiss = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if connectionBanner == .liveAgain { connectionBanner = .hidden }
                }
            }
        }
```
> `onChange(of:)`'s `previous` here is the *prior `Optional<ConnectionState>`*; pass `previous ?? nil` to the reducer (both unwrap to `ConnectionState?`). The reducer already treats `previous == nil` as "no flash."

- [ ] **Step 6: Build the Features package**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 7: Build the full app**

Run:
```bash
cd /Users/landy/Dev/chattr
xcodebuild -scheme chattr -destination 'platform=iOS Simulator,id=54AA7091-7412-44AA-8936-015E77324873' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```
Expected: `** BUILD SUCCEEDED **`
> If the simulator id is stale, list with `xcrun simctl list devices available | grep iPhone` and substitute.

- [ ] **Step 8: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/ChatScreen.swift
git commit -m "Features: transient Reconnecting/Live-again connection pill in ChatScreen"
```

---

## Task 8: End-to-end manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite for the touched packages**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Core && swift test 2>&1 | tail -5
cd /Users/landy/Dev/chattr/Packages/Channels && swift test 2>&1 | tail -5
cd /Users/landy/Dev/chattr/Packages/Features && swift test 2>&1 | tail -5
```
Expected: all green (includes the new `SessionActivitySignal`, `ConnectionStatusStore`, `ConnectionBanner` tests).

- [ ] **Step 2: Airplane-mode recovery (the core behavior)**

1. Launch on a device/simulator; sign in; open a channel with live chat.
2. Confirm messages are flowing and no pill is shown.
3. Toggle **Airplane Mode ON** (or disable the simulator's network). Within a few seconds the pill should read **"Reconnecting…"**.
4. Leave it off for **> 30 seconds** (longer than the old 5-attempt give-up window).
5. Toggle **Airplane Mode OFF**. Expected: within ~1s the socket reconnects, the pill flips to **"Live again"** for ~2s then disappears, and **new chat messages resume**.

Before this work, step 5 would leave chat permanently dead. Passing step 5 is the acceptance criterion.

- [ ] **Step 3: Multi-channel sanity**

Open two channels on the same account. Trigger a drop/restore. Both channels' pills should show the same state (one shared socket). Closing one channel must not affect the other's connection.

- [ ] **Step 4: No-regression on cold start**

Cold-launch into a channel on a good network. The pill must **never flash** "Reconnecting…" or "Live again" — a normal connect goes `.connecting → .connected` and the reducer keeps it hidden.

---

## Self-Review (completed by plan author)

- **Spec coverage:** `isLive` wiring → Tasks 1–3; `ConnectionStatusStore` + per-account dispatcher → Tasks 4–5; transient pill → Tasks 6–7; manual airplane-mode verification → Task 8. All spec sections mapped.
- **Type consistency:** `SessionActivitySignal.{increment,decrement,hasActiveSessions}`, `ConnectionStatusStore.{state,update}`, `ConnectionBanner.{hidden,reconnecting,liveAgain}` + `ConnectionBanner.next(previous:current:)`, `registry.connectionStatus(forAccountUserId:)` — names are used identically across all referencing tasks.
- **Dependency gating:** Tasks 1–3 are TwitchKit-independent; Tasks 4, 5, 6, 7 require Task 0 (the `ConnectionState` surface). Marked on each.
- **No placeholders:** every code step shows complete code; every run step shows the command + expected output.
