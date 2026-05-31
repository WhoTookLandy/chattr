# chattr — Lifecycle Resilience (zombie-sub cleanup + resume re-backfill)

**Status:** approved design — ready for implementation plan
**Date:** 2026-06-01
**Spec basis:** the "Subscription quota & zombie cleanup" and "App lifecycle →
Resumed" rows of `2026-05-24-chattr-design.md` (error-handling section).

---

## What this is

Two independent lifecycle-resilience features that close gaps from the original
design spec:

1. **Cold-start EventSub zombie cleanup** — on launch, delete the dead EventSub
   subscriptions left behind by a previous crash/force-quit so they stop
   counting against the per-app subscription quota.
2. **Resume re-backfill** — when the app returns to foreground after a long
   background, re-fetch each open channel's missed window so chat has no hole
   between "socket died" and "socket reconnected."

They share the theme of app-lifecycle resilience but are otherwise independent
(one runs at launch, one at resume) and can be implemented/landed separately.

## Background

- **WebSocket EventSub subscriptions are session-bound.** When chattr is killed
  and the socket isn't resumed within Twitch's grace window, Twitch marks each
  subscription `websocket_disconnected` and auto-removes it within ~1 hour. They
  don't accumulate forever — but they **count against the per-app subscription
  quota until removed**, so a heavy multi-channel user who force-quits often can
  transiently exhaust quota. A cold-start sweep frees that quota immediately.
- **chattr has no scene-phase observation today** (`chattrApp` / `AppShell` have
  none). The re-backfill needs it; this introduces the first such observation,
  which later lifecycle work (pause off-screen, etc.) can build on.
- **Backfill exists but is one-time.** `ChannelSession.start()` does
  `async let backfillTask = BackfillProvider.fetchRecentMessages(channelLogin:)`
  then `applyBackfill(_:)`. The merge/dedup core is a tested pure function:
  `ChannelSession.mergeBackfill(history:pendingLive:capacity:)`.

## Non-goals

- No scene-phase *pause/resume of sessions* (snapshot throttling while
  off-screen) — that's a separate spec item; this only adds the observation +
  re-backfill trigger.
- No reconcile-against-persisted-tabs cleanup — the status-filtered delete is
  simpler and sufficient (see Decision below).
- No offline send queue.

---

## Feature 1 — Cold-start zombie cleanup

### Decision: status-filtered bulk delete (not reconcile-against-tabs)

The original spec proposed listing all subscriptions and reconciling them against
the joined-channel set. The simpler, equally-correct approach: delete only
subscriptions in a **dead** state. We never delete `enabled` subscriptions, so
this is safe to run at any time relative to session startup — a fresh subscribe
creates `enabled` subs, which the sweep ignores.

### Behavior

On launch, **once per active account**, call (best-effort):

```swift
// HelixClient (TwitchKit 0.3.0). One filter per call (Twitch allows one).
try await client.api.deleteAllEventSubSubscriptions(filter: .status(.websocketDisconnected))
try await client.api.deleteAllEventSubSubscriptions(filter: .status(.websocketFailedPingPong))
```

- `.websocketDisconnected` is the dominant zombie (app killed → socket closed).
  `.websocketFailedPingPong` covers the keepalive-death case.
- Both calls are wrapped so any failure is logged and swallowed — cleanup must
  never block or fail chat startup.
- Runs for the **active account** only (the one chattr launches into). Other
  accounts get cleaned when they become active. (Multi-account-on-launch sweep is
  a trivial future extension but YAGNI now.)

### Ownership & wiring

- New method on `ChannelSessionRegistry` (it owns EventSub/session concerns and
  holds `AccountStore` to resolve the client):
  ```swift
  public func cleanupDisconnectedSubscriptions(forAccountUserId accountUserId: String) async
  ```
  Resolves the account's `TwitchClient` via `accountStore.client(forUserId:)` and
  issues the two bulk deletes inside `do/catch` (log-and-continue).
- Called once at launch from `AppShell` for the active account — e.g. a
  `.task` keyed on the active account id, fired alongside the existing app-launch
  prefetch work. It runs concurrently with (and independently of) session
  startup; ordering doesn't matter because only dead-status subs are deleted.

---

## Feature 2 — Resume re-backfill (>60s background)

### Behavior

When the app returns to `.active` after being `.background` for **more than 60
seconds**, every open channel re-fetches its recent history and merges it into
the existing ring (dedup by message id, marked `.historical`), filling the gap
left while the socket was dead. Live messages and ordering are preserved.

### Pieces

- **`ChannelSession.refreshBackfill()`** (actor method): re-runs
  `BackfillProvider.fetchRecentMessages(channelLogin:)`, then merges the result
  into the *current* ring using the same dedup-by-id logic as the initial
  backfill (reusing / adapting `mergeBackfill`), and emits a snapshot. Unlike the
  one-time `applyBackfill`, it merges into an already-populated ring and does not
  touch the `backfillPending` machinery. Best-effort: a fetch failure logs and
  no-ops.
- **`ChannelSessionRegistry.reBackfillAllSessions()`** (`@MainActor`): iterates
  the active `sessions` and calls `refreshBackfill()` on each, concurrently
  (`withTaskGroup` / `Task` per session). "All open tabs" per the scope decision.
- **`ScenePhaseResilience` in `AppShell`**: observe `@Environment(\.scenePhase)`.
  On `.background`, stamp `Date.now`. On `.active`, if a stamp exists and
  `Date.now - stamp > 60s`, call `registry.reBackfillAllSessions()` and clear the
  stamp. A pure helper keeps the decision testable:
  ```swift
  enum ResumeBackfill {
      static func shouldReBackfill(backgroundedAt: Date?, now: Date, threshold: TimeInterval = 60) -> Bool
  }
  ```

### Data flow

```
scenePhase → .background           (AppShell)   → stamp Date
scenePhase → .active               (AppShell)   → ResumeBackfill.shouldReBackfill?
  └ yes → registry.reBackfillAllSessions()
            └ per session: ChannelSession.refreshBackfill()
                 └ BackfillProvider.fetchRecentMessages → mergeBackfill into ring → snapshot
```

### Interaction with the network-transition work

On resume, the EventSub socket is likely dead; the v0.3.0 path-aware reconnect
brings it back. Re-backfill races that reconnection — harmless, because both the
reconnected socket's replay and the rustlog history dedup by message id (existing
logic). Re-backfill fills the gap the live socket can't (events that occurred
while fully disconnected).

---

## Error handling

- **Both features are best-effort.** Cleanup failure → logged, chat unaffected.
  Re-backfill failure → logged, the channel simply lacks the gap fill (same as
  today). Neither blocks the UI or throws to the user.
- **Dedup safety:** re-backfill merges by message id, so overlap with live /
  replayed messages can't produce duplicates.
- **No enabled-sub deletion:** the cleanup only ever targets dead statuses, so it
  cannot remove a live subscription even if it races session startup.

## Testing

- **`ResumeBackfill.shouldReBackfill`** (pure): nil stamp → false; gap < 60s →
  false; gap ≥ 60s → true. Unit test (new, in Features or Channels).
- **`refreshBackfill` merge**: extend the existing `ChannelMergeTests` —
  re-fetched history merged into a populated ring dedups by id, caps to capacity,
  preserves newest, leaves live messages intact.
- **Manually verified** (not unit-tested today): the registry cleanup call and
  the `AppShell` scene-phase wiring. Manual check: background the app >60s with a
  channel open, foreground → the missed messages appear; relaunch after a
  force-quit → dead subs are gone (verify via Twitch's subscription list or logs).

## Implementation order

1. Feature 1 (cleanup) — self-contained, no UI: registry method + AppShell launch call.
2. Feature 2 (re-backfill) — `ResumeBackfill` helper + test → `ChannelSession.refreshBackfill` + merge test → `registry.reBackfillAllSessions()` → `AppShell` scene-phase observation.
