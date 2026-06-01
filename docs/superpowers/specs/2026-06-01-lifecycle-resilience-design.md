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

### Decision: delete every non-`enabled` subscription (not reconcile-against-tabs)

The original spec proposed listing all subscriptions and reconciling them against
the joined-channel set. The simpler, equally-correct approach: delete every
subscription whose status is **not `enabled`**.

Why "all non-`enabled`" rather than a targeted list of dead statuses: Twitch's
`deleteAllEventSubSubscriptions(filter:)` accepts only **one** status filter per
call, and there are ~10 websocket-death statuses (`websocket_disconnected`,
`websocket_failed_ping_pong`, `websocket_connection_unused`,
`websocket_network_error`, `websocket_failed_to_reconnect`, …). Enumerating them
would mean ~10 calls and would silently miss any status Twitch adds later.
Instead, **list once and delete anything that isn't `enabled`**. For a
websocket-only client `enabled` is the only "keep" status — every other status
means the subscription is dead or dying — so this can never remove a live
subscription, and it's future-proof. It's also safe to run at any time relative
to session startup, because a fresh subscribe produces an `enabled` sub the sweep
ignores.

### Behavior

On launch, **once per active account**, best-effort:

```swift
// HelixClient (TwitchKit 0.3.0). eventSubSubscriptions() → HelixPagedSequence
// <EventSubSubscriptionRecord>; each record has `id: String` and
// `status: EventSubSubscriptionStatus`.
for try await record in client.api.eventSubSubscriptions() {
    if case .enabled = record.status { continue }          // keep live subs
    try? await client.api.deleteEventSubSubscription(id: record.id)   // reap the rest
}
```

- Pattern-matches `.enabled` (rather than `!=`) so it doesn't depend on
  `EventSubSubscriptionStatus` Equatable conformance (it carries an
  `unknown(String)` case).
- The whole loop is wrapped in `do/catch`; any error (list or delete) is logged
  and swallowed — cleanup must never block or fail chat startup.
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

## Feature 2 — Resume re-backfill (>60s background) — **DEFERRED**

> **Status (2026-06-01): deferred, not being implemented now.** Planning revealed
> the merge is not the trivial `mergeBackfill` reuse this spec assumed.
> `ChatMessage`/`ChannelEvent` carry **no timestamp**, so ordering can only be
> done by position — which is correct for the one-time startup merge (history is
> wholly older than buffered-live) but **wrong** for re-backfill, where ~100
> rustlog messages merge into an already-populated ~500-message ring with partial
> overlap. A correct implementation needs an **overlap-join** (find the newest
> shared `messageId` as the seam, splice in only the missing gap messages, no-op
> when there's no overlap) — a bounded but non-trivial new algorithm.
>
> Given the network-transition reconnect (TwitchKit 0.3.0, already shipped)
> already restores *live* chat on resume, the only thing re-backfill adds is the
> historical gap (messages that arrived while backgrounded) — low-value for a
> chat app. Deferred until it's worth the algorithmic surface. The design below
> is retained for when we revisit it.

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

1. **Feature 1 (cleanup)** — self-contained, no UI: registry method + AppShell
   launch call. **This is the only feature being implemented now.**
2. ~~Feature 2 (re-backfill)~~ — **deferred** (see the Feature 2 status note).
