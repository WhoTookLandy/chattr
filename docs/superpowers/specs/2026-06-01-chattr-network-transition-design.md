# chattr — Network-Transition Handling (consume TwitchKit resilience)

**Status:** approved design — ready for implementation plan
**Date:** 2026-06-01
**Depends on:** TwitchKit **`v0.2.0`** (see
`2026-06-01-twitchkit-network-resilience-design.md`) — the path-aware reconnect
and `connectionState` stream. chattr work proceeds once that ships and the
dependency pin is bumped.

---

## What this is

Close the spec's "network transitions" + "transient connection banner" gaps
(`2026-05-24-chattr-design.md`, Error-handling section). After TwitchKit gains
path-aware reconnect and a `connectionState` stream, chattr must:

1. **Wire `isLive`** so reconnect is aggressive (infinite, fast backoff) whenever
   a channel is open — fixing the current always-`false` default that makes
   EventSub give up after ~30s offline.
2. **Consume `connectionState`** and surface it to the chat UI.
3. **Render a transient "Reconnecting… / Live again" pill** in the channel header.

## Background: the bug being fixed

`AccountStore` builds `TwitchClient(...)` **without** passing `isLive`, so it
defaults to `{ false }`. EventSub therefore always runs the "not-live" backoff
ladder: 5 attempts, then it gives up permanently. After an outage >~30s, chat
stays silently dead until the user re-enters the channel. (TwitchKit `v0.2.0`'s
path monitor independently resumes on network restore, but `isLive` must still be
wired so non-network Twitch-side drops also retry instead of giving up.)

## Goals

- A visible/open channel reconnects indefinitely with fast backoff.
- The user sees a calm, transient indicator while reconnecting and a brief
  "Live again" confirmation on recovery.

## Non-goals

- No change to TwitchKit (done separately in `v0.2.0`).
- No scene-phase pause/resume rework (that is a separate spec item).
- No offline message queueing — sends while offline still fail as they do today.

---

## Architecture

Data flow:

```
NWPath change (TwitchKit)
  → EventSubClient emits ConnectionState         (TwitchKit v0.2.0)
  → per-account consumer in ChannelSessionRegistry
  → ConnectionStatusStore  (@Observable, registry-owned, per account)
  → ChatScreen reads it → renders the pill
```

The WebSocket is **per account**, shared by all that account's open channels — so
connection state is tracked per `accountUserId`, and every visible channel on
that account shows the same banner.

### Component 1 — `isLive` wiring

`isLive` must answer "is any channel open right now?" The catch: `AccountStore`
(in `Packages/Accounts`) builds the client, but "open channels" is known to
`ChannelSessionRegistry` (in `Packages/Channels`, which depends on Accounts — not
the reverse). Resolve the dependency direction with a shared Sendable signal in
**`Core`** (both packages already depend on Core):

```swift
// Core
public final class SessionActivitySignal: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    public init() {}
    public func increment() { count.withLock { $0 += 1 } }
    public func decrement() { count.withLock { $0 = max(0, $0 - 1) } }
    public var hasActiveSessions: Bool { count.withLock { $0 > 0 } }
}
```

- One shared instance, injected into `AccountStore` (or a DI container) and the
  registry.
- `AccountStore` passes `isLive: { [signal] in signal.hasActiveSessions }` into
  the **persistent** `TwitchClient` (the chat client). The one-shot *probe*
  clients (Helix-only, no EventSub) don't need it.
- `ChannelSessionRegistry.acquire(...)` calls `signal.increment()`,
  `release(...)` calls `signal.decrement()` (alongside the existing refcount
  changes). Net effect: `isLive == true` iff ≥1 channel tab is open.

> Granularity note: "any open channel" (not "any *visible* channel") is the MVP
> choice — simpler, and an open-but-offscreen channel still wants to stay live so
> a swipe back shows current chat. Visibility-gated `isLive` is a later refinement.

### Component 2 — `ConnectionStatusStore` (registry-owned, per account)

Mirror the existing T11 per-channel store pattern (`emoteIndexes`,
`badgeStores`), but keyed per **account** since the socket is per account:

```swift
// Packages/Channels
@MainActor @Observable
public final class ConnectionStatusStore {
    public private(set) var state: ConnectionState = .connecting   // from TwitchKit
    func update(_ newState: ConnectionState) { state = newState }
}
```

In `ChannelSessionRegistry`:
- Add `private var connectionStatusStores: [String: ConnectionStatusStore]`
  keyed by `accountUserId`, plus a public
  `connectionStatus(forAccountUserId:) -> ConnectionStatusStore` accessor (same
  shape as `emoteIndex(forAccountUserId:channelId:)`).
- Add a per-account **connection-state dispatcher** alongside the existing
  `ensureEventDispatch`: when the first session for an account is created, start
  a `Task` that does `for await state in client.eventSub.connectionState { store.update(state) }`.
  **Start it in the same place and at the same time as the event dispatcher**, so
  it begins consuming before/around `connect()` and observes the initial
  `.connecting → .connected` transitions (the stream is single-consumer with no
  replay — see the TwitchKit spec).
- Tear it down in `stopDispatcherIfIdle` (cancel the task) and drop the store
  when the account has no sessions.

### Component 3 — the pill (ChatScreen)

In `ChatScreen`, read the account's `ConnectionStatusStore` (via the registry,
the same way it already reads `emoteIndex`/`badgeStore`) and drive a transient
capsule in the channel header. Reuse the existing jump-to-latest pill's visual
language: glass capsule (`.glassEffect(.regular, in: Capsule())`), `caption`,
secondary grey.

Presentation rules (a small view-local reducer over `state`):
- `.reconnecting`, `.waitingForNetwork` → show **"Reconnecting…"** (persist while
  in these states).
- transition *into* `.connected` *from* a non-connected state → show **"Live
  again"** for ~2s, then auto-dismiss.
- steady `.connected` (and `.connecting` on first launch) → hidden.
- `.disconnected` → hidden (intentional teardown; the channel is closing).

Distinguish "Reconnecting…" vs "Live again" with a tiny SF Symbol +
tint if desired (e.g. `wifi.exclamationmark` secondary vs `checkmark` green),
but keep it understated — this is reassurance, not an alarm. No modal, no spinner.

---

## Error handling

- Stream ends (account torn down / client deallocated) → dispatcher loop exits,
  store stops updating; the pill clears because the ChatScreen unmounts.
- Multiple channels open on one account → all read the same per-account store and
  show the same state (correct — one shared socket).
- Rapid flaps → TwitchKit already dedups `connectionState`; the "Live again"
  auto-dismiss timer is restarted on each genuine recovery, so a flap that
  re-drops cancels the "Live again" and returns to "Reconnecting…".

## Testing

- **`isLive` wiring:** `SessionActivitySignal` returns `false` with no sessions,
  `true` after `acquire`, back to `false` after matching `release`. (Pure unit
  test in Core.)
- **Connection dispatch:** feed a `ConnectionStatusStore` from a scripted async
  sequence; assert `state` tracks the emitted values.
- **Pill reducer:** extract the `state → (text, visible)` mapping (incl. the
  "Live again" transient) into a pure helper and unit-test it: into-`.connected`
  shows "Live again"; steady `.connected` hides; `.reconnecting` shows
  "Reconnecting…". Keeps the timing logic testable without the view.

## Implementation order

1. Bump TwitchKit pin to `v0.2.0`; confirm the app builds against the new surface.
2. `Core`: `SessionActivitySignal` (+ test).
3. `Accounts`: inject the signal; pass `isLive` into the persistent client.
4. `Channels`: `increment`/`decrement` in acquire/release; `ConnectionStatusStore`
   + per-account connection dispatcher + accessor.
5. `Features`: ChatScreen reads the store; pill reducer + glass capsule.
6. Manual verification: open a channel, toggle Airplane Mode on for >30s, toggle
   off → chat resumes within ~1s and the pill shows "Reconnecting…" → "Live again".
