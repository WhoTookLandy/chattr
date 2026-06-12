# "New" messages divider + reconnect backfill — design

Date: 2026-06-12

## Goal

1. **Join divider**: when a channel opens, show a thin red "New" line separating
   rustlog backfill (history from before the user joined) from live messages —
   the Twitch-native treatment.
2. **Reconnect backfill**: when the EventSub socket drops and recovers (app
   backgrounded, network blip), fetch a small rustlog backfill, compare it
   against what we already have, insert **only the missing messages**, and show
   the same divider at the disconnect point.

## Architecture

### Divider as a ring event (Channels)

New `ChannelSession.ChannelEvent` case:

```swift
case newMessagesDivider(id: String, timestamp: Date)
```

The divider lives in the session's ring buffer, so:
- late-attaching tabs (and re-attach after tab swipes) replay it at the right
  position for free;
- multiple tabs on the same channel agree on where the line sits;
- the buffer cap ages it out naturally.

The `id` is minted once (`"divider-<UUID>"`) and stored in the event so
re-primes produce a stable `ChatLine.id` for the diffable data source.

**Ring-purity trade-off (accepted)**: the ring's contract was "what happened
in this channel"; the divider is session-lifecycle metadata, not a Twitch
event. We accept the impurity because `.restrictionsUpdated` and
`.moderationStatusChanged` already put non-wire state signals in the event
union, and the alternative — per-view divider state — loses exactly the
multi-tab consistency and replay-on-re-attach that motivated the design.

### Join divider

`ChannelSession.mergeBackfill(history:pendingLive:capacity:)` gains a
`divider: ChannelEvent?` parameter. When history is non-empty,
`applyBackfill` passes a fresh divider; the merge inserts it between the
deduped history block and the buffered-live block. Empty backfill → no
divider (nothing to separate).

### Reconnect backfill

- **Trigger**: `ChannelSessionRegistry`'s per-account connection pump already
  consumes `client.eventSub.connectionState`. It now tracks the previous
  state; on a transition into `.connected` from `.reconnecting` or
  `.waitingForNetwork` it calls `resyncAfterReconnect()` on every started
  session for that account. (`.connecting → .connected` is cold start — the
  join backfill covers it; no resync.) The per-session resync `Task`s are
  fire-and-forget and deliberately untracked: a session released mid-resync
  completes its fetch against a stopped session, appends to a ring nobody
  reads, and deallocates — harmless, and not worth the cancellation
  bookkeeping. The task's retain delays actor dealloc by at most the fetch
  timeout.
- **`ChannelSession.resyncAfterReconnect()`** (new, actor-isolated):
  1. Bail if initial backfill is still pending or a resync is already in
     flight (`resyncInFlight` flag, set synchronously).
  2. Fetch via the constructor-injected `fetchBackfill` closure (defaults to
     `BackfillProvider.fetchRecentMessages`, limit 100; same
     closure-injection DI as `refreshTokenHandler`, so tests stub it and run
     the whole actor path offline).
  3. Compute gap events via the pure static
     `reconnectGapEvents(fetched:ring:dividerId:timestamp:)`:
     messages whose `messageId` is not in the ring, prefixed with a divider.
     Empty when nothing was missed → **no divider, no fan-out**.
  4. Append the batch to the ring synchronously (cap-aware), then fan each
     event out to subscribers in order (same TaskGroup shape as
     `handle(event:)`).

Self-healing dedup: if our own send's echo was lost during the gap, the
synthesized-upgrade row already holds the canonical id, so the resynced copy
dedupes in `TabChatModel.apply` Path 1 (`buffer.contains(id:)`).

Known small races (accepted): live events arriving during the rustlog fetch
land *before* the divider batch (chronological fuzz of ~1 fetch round-trip);
messages broadcast between rustlog's snapshot and `resubscribeAll()`
completing can be missed by both sources.

**Divider accumulation (accepted)**: repeated disconnect/reconnect cycles
each mint a new divider, so a flaky-network session can leave several "New"
rules in scrollback. Twitch's own clients replace the previous line; we
deliberately don't, because `ChannelEvent` has no removal semantics —
dropping the old divider from the ring wouldn't propagate to live-attached
tab buffers, so ring and visible state would diverge until the next
re-prime. Each divider marks a real gap, and the buffer cap ages old ones
out naturally. Revisit only if it proves noisy in practice (would need a
removal-capable change channel first).

### Rendering (ChatModel + Features)

- `ChatLine.Kind` gains `.newMessagesDivider`. The exhaustive renderer switch
  forces the visual to be wired (by design).
- `TabChatModel.ingest` maps the event to a divider `ChatLine` (empty author,
  empty runs).
- `ChatRow` renders it as a 1pt red rule with a small red "New" caption — no
  context menu (the existing `.message`-only guard covers it). The row is a
  single combined accessibility element labeled "New messages" with the
  `.isHeader` trait, so VoiceOver users can rotor-jump to the divider.
- The "New" / "New messages" strings are unlocalized, matching the project
  convention (no String Catalog exists; every user-facing literal in the
  Features package has the same property). When localization lands, package
  strings need `bundle: #bundle` — `LocalizedStringKey` literals in a Swift
  package resolve against `Bundle.main` and fail silently otherwise.
- `chatCleared` flips every line to `.deletedPlaceholder` EXCEPT dividers.

## Testing

- `ChannelsTests/ChannelSessionResyncTests`: pure-function coverage for
  `mergeBackfill` divider placement and `reconnectGapEvents` (missing-only
  insertion, empty-gap → no divider, ordering, id stability), plus offline
  actor-path coverage via the injected `fetchBackfill` stub (ring commit +
  fan-out ordering, clean-resync no-op, backfill-pending guard;
  `applyBackfill` is internal-for-tests to end the buffering window, same
  relaxation as `translate`).
- `FeaturesTests/TabChatModelDividerTests`: divider event → divider line;
  chat-clear preserves the divider; re-prime replays it.

Run: `swift test --package-path Packages/Channels` and
`swift test --package-path Packages/Features`.
