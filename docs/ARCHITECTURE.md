# chattr architecture, for a systems engineer

This document explains how chattr is put together, with the performance and
concurrency decisions called out explicitly. It assumes you're comfortable with
systems concepts (locks, ring buffers, COW, cache lines, amortized cost) but new
to Swift, SwiftUI, and iOS. Where a Swift idiom has a clean C++ analogue, this
doc gives it.

There's a companion glossary at the end — **["Swift/iOS concepts in C++ terms"](#appendix-a--swiftios-concepts-in-c-terms)** —
skim it first if the language is unfamiliar.

---

## 1. The 30-second mental model

chattr is a **Twitch chat client**. It opens a WebSocket to Twitch's "EventSub"
service, receives chat messages as JSON frames, transforms them into a
display-ready form, and renders them in a fast scrolling list — while also
handling sending, multi-account auth, third-party emotes, and moderation.

The whole app is a data pipeline with a UI stuck on the end:

```
WebSocket frame  →  decode  →  per-(account,channel) routing  →  normalize
   (TwitchKit)                  (ChannelSession actor)          (pure fn)
        →  ring buffer  →  typed change batch  →  UICollectionView diff  →  pixels
        (ChatBuffer)      (ChatChange)            (ChatListView)
```

Everything else (accounts, emotes, badges, backfill) is machinery that feeds or
enriches that pipeline.

---

## 2. Module layout: a strict downward DAG

The code is split into **Swift packages** (think: statically-linked libraries,
each its own compilation unit / translation-unit group). Dependencies form a
strict DAG — edges only point *down* this list, never up:

```
Core   DesignSystem            ← leaves: zero internal deps
  ↑         ↑
EmoteSources   Accounts            ← depend on Core / DesignSystem
  ↑
ChatModel                          ← depends on EmoteSources
  ↑
Channels                           ← depends on Accounts, EmoteSources, ChatModel
  ↑
Features                           ← ALL SwiftUI lives here; depends on everything below
  ↑
chattr app target                  ← composition root + dependency injection only
```

| Package | Responsibility | C++ analogy |
|---|---|---|
| **Core** | Errors, logging, endpoints, disk cache, debouncers | a `util/` / `base/` lib |
| **DesignSystem** | Colors, typography, appearance tokens | a theming lib |
| **EmoteSources** | 7TV/BTTV/FFZ providers + `EmoteIndex` | a vendored protocol-client lib |
| **ChatModel** | `ChatLine` display model + `Normalizer` | pure transform / DTO lib |
| **Accounts** | Auth, token refresh, `Account` persistence | an auth subsystem |
| **Channels** | `ChannelSession` lifecycle, registry, backfill | the networking/session core |
| **Features** | Every screen + view model | the application layer |

Why this matters for you: **the layering is the architecture's load-bearing
wall.** It's what keeps a one-line UI tweak from being able to reach into the
networking core, and it's why the network/transform code has no SwiftUI
dependency and is unit-testable in isolation (the `Normalizer` is a pure
function; you can fuzz it with fixtures). The rule is enforced socially (each
`Package.swift` declares its deps) rather than by the compiler beyond the
acyclic-import constraint — SwiftPM forbids dependency cycles, so the DAG can't
silently become a graph.

The app target itself (`chattr/chattrApp.swift`) is ~100 lines: it builds the
SwiftData container, constructs the `AccountStore` and `ChannelSessionRegistry`
singletons, configures the image pipeline, and hands them to the root view. It's
the `main()` + DI wiring, nothing else.

---

## 3. The concurrency model (read this before anything else)

Swift's concurrency story is the single biggest conceptual gap coming from C++,
and chattr leans on it heavily. Three primitives do all the work:

### 3.1 `actor` — a class with a built-in mutex

An `actor` is a reference type whose mutable state is protected by an implicit
serial executor. Only one task runs inside an actor's isolation at a time; every
cross-actor call is `async` and may suspend (a *hop*) until the actor is free.
Think: **a class where every method is implicitly wrapped in
`std::lock_guard` on the same per-instance mutex, except instead of blocking the
thread it suspends the coroutine.**

- `ChannelSession` is an actor. Its ring buffer and subscriber table are
  actor-isolated, so message ingestion and `subscribe()` can't race even though
  frames arrive on a network executor and subscribers live on the UI thread.
- `EmoteIndex` is an actor — its emote map is mutated during async refresh.

### 3.2 `@MainActor` — "must run on the UI thread"

`@MainActor` is a *global* actor: one shared executor that is the main run loop.
Anything annotated `@MainActor` is guaranteed to run there. SwiftUI requires all
view state mutation on the main actor (same as UIKit's "UI on the main thread"
rule, but now compiler-enforced).

- View models (`ChatTranscriptModel`), the registry (`ChannelSessionRegistry`),
  and the stores (`ChatBadgeStore`, `ConnectionStatusStore`) are all
  `@MainActor`. This is a deliberate simplification: UI-adjacent state lives on
  one actor so you never need explicit locking around it, at the cost of one
  actor hop per inbound message — cheap, because chat tops out at tens of
  messages/sec in the common case.

### 3.3 `Sendable` — compile-time "safe to cross threads"

`Sendable` is a marker protocol (like Rust's `Send`) the compiler checks: a type
is `Sendable` if it has no unsynchronized shared mutable state. You can only pass
`Sendable` values across an actor/task boundary. **Swift 6 "strict concurrency"
makes this a hard compile error, not a lint** — the entire app is built with it
on. This is why you'll see patterns like "extract `account.userId` into a local
`let` before the `@Sendable` closure" — a SwiftData `Account` is a reference type
that isn't `Sendable`, so you pull the plain `String` out instead of capturing
the object.

### 3.4 Value types + copy-on-write

Most data (`ChatLine`, `ChatChange`, `ChatBuffer`, `Emote`) are `struct`s —
**value types with copy semantics**, like a C++ `struct` passed by value. Swift's
standard collections (`Array`, `Dictionary`, `Set`) are copy-on-write: assigning
or passing them is a refcount bump; the deep copy only happens on mutation of a
shared buffer. So `let snapshot = buffer.lines` is O(1) until someone writes.
This is exactly `std::shared_ptr<const vector>` semantics with implicit
detach-on-write.

### 3.5 The one escape hatch: `OSAllocatedUnfairLock`

Where an actor hop is too expensive on a hot path, the code drops to a real lock.
`EmoteIndex.snapshot()` is `nonisolated` (callable without `await`) and returns
the emote map guarded by an `OSAllocatedUnfairLock` — this is literally
`os_unfair_lock`, a tiny spin-then-sleep mutex. The normalizer needs the emote
table on every message from the `@MainActor`; making that an `await EmoteIndex`
call would hop actors per message. Instead the index publishes its map behind the
lock, and the main actor reads it with one atomic op. (Swift 6 won't let you mark
a mutable dictionary `nonisolated(unsafe)` and call it a day — the lock makes it
*provably* safe, not just promised.)

---

## 4. The chat hot path, end to end

This is the part you actually care about for performance. Follow one message
from the wire to the screen.

### 4.1 Ingestion — `ChannelSession` (actor)

TwitchKit owns one EventSub WebSocket per signed-in account. The
`ChannelSessionRegistry` (`@MainActor`) owns a *single* consumer of that event
stream and routes each decoded event to the right `ChannelSession` by matching
the broadcaster id. One iterator, fan-out by key — this avoids the classic bug
where N independent stream consumers each get an unpredictable subset of events.

Inside the session, `handle(event:)`:
1. Translates the TwitchKit event into a `ChannelEvent` (the session's own enum —
   `.message`, `.notification`, `.raid`, `.messageDeleted`, `.chatCleared`,
   `.messagesClearedFromUser`, `.restrictionsUpdated`, `.newMessagesDivider`,
   `.moderationStatusChanged`).
2. Appends it to a **ring buffer** (`ring: [ChannelEvent]`, capped at the user's
   "Chat History" setting, default 500). The ring is the session's source of
   truth for "everything since I joined."
3. Fans the event out to all subscribers **in parallel** via a `withTaskGroup`.
   This matters under raid/mass-gift storms (50–200 events/sec): serial fan-out
   would make per-event latency the *sum* of all subscriber handler times; the
   task group makes it the *max*. Ordering is still preserved because
   `handle()` doesn't return until the whole group completes, and the actor
   processes one event at a time.

`subscribe(_:)` returns `(token, snapshot)` atomically — you get the current ring
contents *and* register your handler in one actor-isolated step, so there's no
gap where an event could slip between "read initial state" and "start listening."
This is the same problem as subscribing to a broadcast channel without losing
in-flight messages, solved by doing both under the actor lock.

### 4.2 Normalization — `Normalizer` (pure function)

`ChatTranscriptModel` (the per-tab `@MainActor` view model) is the subscriber. On
each `.message` event it calls `Normalizer.normalize(message:emoteSnapshot:...)`,
a **static, stateless, pure function**. Given the raw message + an emote-table
snapshot + the viewer's login + highlight keywords, it produces a fully
display-ready `ChatLine`:

- Walks Twitch's pre-tokenized fragments, buffering adjacent text and tokenizing
  it into **word-level runs** (`LineRun.text`, `.emote`, `.twitchEmote`,
  `.mention`, `.cheermote`, `.url`). Word granularity is required so the layout
  engine can wrap *between* words like a browser does — a multi-word run would
  wrap as one atomic block.
- Each word is looked up in the emote snapshot (`O(1)` dict hit) → upgraded to an
  emote run or left as text.
- Flags self-mentions and keyword matches for highlighting.
- Strips Twitch's legacy `@parentLogin ` reply prefix.

Being pure makes it trivially testable and trivially cacheable (next section). It
takes a *plain dictionary* snapshot, not the `EmoteIndex` actor, precisely so it
never has to `await` — see §3.5.

### 4.3 Normalization cache — `NormalizedLineCache` (the swipe optimization)

Here's a subtle one. The session ring stores *raw* events; the `ChatLine` is
*derived*. When you swipe between channel tabs, the chat view tears down and
remounts, which re-primes its buffer from the session ring — re-deriving
hundreds of identical `ChatLine`s on the main thread per swipe.

`NormalizedLineCache` (owned by the registry, lifetime = the session) memoizes
`messageId → ChatLine`. Each message pays normalization **once**, on live
arrival; re-prime becomes dictionary hits. Two details worth noting:

- **Context fingerprinting.** Normalization is only deterministic for fixed
  inputs (emote table, viewer login, keywords). The cache stamps every entry with
  a `Context` (the emote-table *count* as a cheap version number, plus login +
  keywords). A read under a different context misses; a write under a different
  context wipes the cache. This elegantly handles the common "emote table loaded
  a moment after the channel opened" case — the version bump re-normalizes the
  early messages that rendered emote-less.
- **Head-index FIFO.** Eviction is the same ring trick as `ChatBuffer` (below) —
  oldest-out by advancing a head index, batch-compacting amortized.

### 4.4 Buffering — `ChatBuffer` (the data-structure showpiece)

`ChatBuffer` is a value-type sliding window that's worth reading in full
(`Packages/Features/Sources/Features/Chat/ChatBuffer.swift`). It solves three
costs that a naive `[ChatLine]` + re-filter + `removeFirst` would incur on *every
message once at cap*:

1. **Front-trim without memmove.** Dropping the oldest line from a Swift `Array`
   via `removeFirst()` is O(n) — it shifts every remaining element down (a
   `memmove`). At a 500-cap buffer under a firehose, that's 500-element shifts
   per message. Instead the buffer keeps a backing array plus a `head` index; the
   live window is `storage[head...]`. Dropping the oldest is `head += 1` (O(1)),
   and the dead prefix is reclaimed in one batched `removeFirst(head)` only once
   it grows past the cap. **This is the classic circular-buffer-via-head-pointer
   trick**, applied to a growable array.
2. **No full re-filter.** The view renders a *block-filtered* projection (blocked
   users hidden). Rather than re-running the filter over the whole window each
   message, the buffer maintains the filtered projection incrementally as lines
   are appended/dropped — and the projection *also* uses the head-index ring, so
   its front-trim is O(1) too.
3. **It emits a typed changelog.** Every mutation records what it did into
   `pendingChanges: [ChatChange]` — `.appended`, `.removed`, `.reconfigured`, or
   `.reset`. `takeChanges()` drains them. This is the key to the next section.

The contract is checked by tests (`ChatChangeContractTests`): applying an emitted
batch to the previous visible state reproduces the new state exactly. So the
buffer is the single source of truth for *what changed*, and downstream consumers
never have to re-diff.

### 4.5 The model→view boundary — incremental changes, not array republishing

This is the cleverest performance decision in the app, and the least obvious one
coming from a retained-mode-UI background.

SwiftUI is **declarative / reactive**: a view's `body` is a pure function of its
observed state, re-invoked whenever that state changes, and the framework diffs
the result against the previous tree (immediate-mode-ish on top of a retained
backing store). The naive design is: model holds `@Observable var lines:
[ChatLine]`; every message mutates the array; SwiftUI re-runs the list body and
diffs 500 rows. That diff is O(n) per message *and* it makes the view body depend
on the entire array, so every message invalidates everything.

chattr breaks that dependency:

- The model exposes a **monotonic `changeVersion: Int`** as the only
  `@Observable` trigger. The actual change batch (`latestChangeBatch:
  [ChatChange]`) is `@ObservationIgnored` — reading it does *not* register a view
  dependency.
- `ChatListView` (the list) observes only `changeVersion`. When it advances by
  exactly 1, the view pulls the batch and applies it directly (`.appended` →
  append one row, `.removed` → delete one, etc.). O(1) per message, no re-diff.
- If `changeVersion` jumps by more than 1 (SwiftUI coalesced several publishes
  into one update pass) or it's the first mount, the view falls back to a full
  snapshot reset. Correct, just not incremental — a safety net, not the hot path.

So passing an `Int` across the reactive boundary instead of a `[ChatLine]` is
what keeps the per-message cost O(1) on both sides. Mentally: it's the difference
between "publish the whole framebuffer and let the compositor diff it" and
"publish a dirty-rect list."

### 4.6 Rendering — `ChatListView` over `UICollectionView`

SwiftUI's own `List`/`LazyVStack` couldn't hold 60fps under a 100+ msg/sec
firehose (cell reuse + self-sizing + scroll anchoring weren't good enough), so
the transcript drops down to **UIKit's `UICollectionView`** — the mature,
cell-recycling list — wrapped in a `UIViewControllerRepresentable` (the
SwiftUI↔UIKit bridge). Each row's *content* is still a SwiftUI `ChatRow` hosted
via `UIHostingConfiguration`, so you keep the SwiftUL rendering for a row but get
UIKit's recycling and scroll machinery for the list.

Key mechanics:

- A **diffable data source** keyed by message-id `String` (not by `ChatLine`
  value). The `ChatChange` batch is folded onto a `NSDiffableDataSourceSnapshot`;
  `.reconfigured` re-renders a row in place without touching its neighbors.
- **Tailing via per-layout-pass re-pin.** "Stick to the newest message" is hard
  with self-sizing cells: a one-shot `scrollToItem(.bottom)` computes its target
  from *estimated* heights and lands wrong when real heights differ. Instead, a
  `LayoutCallbackCollectionView` subclass calls back on *every* `layoutSubviews`,
  and `pinToBottomIfNeeded()` re-asserts the bottom offset each pass — absorbing
  every estimate→actual height correction before it's drawn. A sub-point delta
  guard breaks the layout→pin→layout recursion once geometry converges.
- **Top-anchor preservation.** When you're scrolled up reading history and old
  rows trim off the top, it captures the top visible row + its offset before the
  change and restores it after — so the front-trim doesn't yank your reading
  position.

### 4.7 Images & emotes — Nuke + a Core Animation frame-cycler

Emotes and badges are small images fetched from CDNs. Two layers:

- **Nuke** (third-party image lib) provides the shared `ImagePipeline`: a 50 MB
  decoded-image memory cache (NSCache, sheds under memory pressure) + a 200 MB
  on-disk compressed cache, with **decompression off the main thread**. Tuned in
  `ImagePipelineSetup` for chat's access pattern (many tiny images, high recycle
  rate, strong locality).
- **`ChatImagePrefetcher`** warms the cache *ahead of need*: global emotes +
  badges into memory at launch; the user's subscribed emotes + per-channel badges
  into disk on channel entry. All at `.veryLow` priority so prefetch never beats
  an on-screen request. This turns the first display of a common emote from a
  200–500ms network+decode stall into a warm-cache hit.
- **Animated emotes** (7TV WebP, BTTV GIF, APNG) are the spicy bit. They're
  decoded once off-main with ImageIO into `DecodedAnimation` (immutable
  `[CGImage]` frames), cached process-wide in a 64 MB `NSCache` keyed by URL. The
  frames are then handed to a **`CAKeyframeAnimation` on a `CALayer`** — Core
  Animation cycles them on the *render server* (a separate process), so the main
  thread does **zero work per frame**. This replaced an earlier `TimelineView`
  approach that rebuilt a SwiftUI `Image` ~25×/sec *per visible emote* — i.e.
  N×25 main-thread view rebuilds/sec in an emote-heavy channel, even while chat
  sat idle. There's also a "poster frame" trick: delta-encoded WebPs open on a
  near-blank frame, so the static fallback scans the first ~10 frames for one
  with ≥5% alpha coverage (via a constant-cost 16×16 downsample) rather than
  showing transparent nothing.

---

## 5. Sending: optimistic UI + two-keyed echo reconciliation

Sends are **optimistic**: the moment you hit send, an optimistic `ChatLine` with
a `pending-…` id appears (dimmed, `.sending` state), before any server
round-trip. Then reality reconciles:

- Twitch confirms via **two independent channels** that race by ~50ms in either
  order: the Helix POST response (carries the canonical `messageId`) and the
  EventSub WebSocket echo (carries badges/color/parsed fragments — the rich
  form).
- The model correlates them with **two maps**: primary by Helix `messageId`
  (unambiguous), fallback by message text (covers "echo arrived before the POST
  returned"). The text map is a **FIFO queue per text**, not a single value, so
  double-sending identical text within the race window can't corrupt which row
  upgrades — echo #N reconciles row #N regardless of arrival order. (The code
  comments walk through the exact duplicate-id crash this prevents.)
- A **5-second fallback timer** per pending send: if the echo never arrives
  (WebSocket hiccup) but Helix accepted, it synthesizes a "delivered" upgrade so
  the row doesn't sit dim forever.
- Failure (`isSent=false` drop, or thrown error) flips the row to `.failed`
  in-place with a retry affordance — non-modal, you keep what you typed.

It's more machinery than you'd expect, but it's the price of "message appears
instantly" + "exactly-once row" against a backend that gives you two unordered
confirmations and no client-correlation id.

---

## 6. Lifecycle & resilience (the stuff that makes it survive real use)

- **Session ref-counting.** `ChannelSessionRegistry.acquire/release` ref-counts
  sessions so multiple tabs viewing the same channel share one EventSub
  subscription (re-subscribing the same topic would fail). The acquire path
  increments *before* the `await` and rolls back in `catch` so a thrown/cancelled
  acquire doesn't leak a count — a pattern documented in `conventions.md`.
- **Backfill.** On join, history is fetched from a community archive
  (`recent-messages.robotty.de`, IRC-tag format) *in parallel* with the live
  subscription; live events are buffered until the fetch lands, then merged
  (dedup by messageId, history wins, a "new messages" divider inserted between).
  Degrades to empty on any failure.
- **Reconnect gap-fill.** On WebSocket recovery (distinct from cold connect), each
  session fetches a smaller batch and dedups against its ring to fill the gap.
- **Zombie cleanup.** On cold start, dead EventSub subscriptions a prior
  crash/force-quit left behind are reaped so they stop counting against Twitch's
  per-app quota.
- **Token refresh.** `AccountStore` wraps Helix calls in `withTokenRefresh` —
  on a 401 it refreshes and retries once. There's a defensive second copy of the
  refresh token (`OAuthRefreshTokenCache`) because TwitchKit wipes its own
  keychain entry on refresh failure; the cache is the recovery path.
- **Attach epochs.** `ChatTranscriptModel.attach` claims a monotonically-bumped
  epoch synchronously before any `await`, and re-checks it after each suspension.
  If a newer attach superseded it (SwiftUI fired two overlapping `.task`s during a
  tab transition), the stale one bails and undoes its partial subscription. This
  is the "last writer wins, no stranding" pattern for racing async setup — the
  kind of bug that's invisible until a paged tab view re-evaluates identity
  mid-flight.

---

## 7. Where the performance budget actually goes

If you're profiling, these are the hot spots and how they're defended:

| Cost | Frequency | Defense |
|---|---|---|
| Normalize a message | once per live message | pure fn; memoized in `NormalizedLineCache` so re-prime is free |
| Emote lookup | per word | O(1) dict via lock-protected `snapshot()`, no actor hop |
| Front-trim at cap | per message at cap | head-index ring, O(1) + amortized compaction |
| Re-filter blocked users | per message | maintained incrementally, never rescanned |
| Model→view publish | per message | `Int` version + typed change batch, O(1), no array re-diff |
| List update | per message | diffable data source applies one row op |
| Image decode | per unique image | Nuke off-main decode + memory/disk cache + prefetch |
| Animated emote frames | per frame per emote | Core Animation on the render server; **0** main-thread cost |
| Subscriber fan-out | per event | parallel task group, latency = max not sum |

The throughline: **every per-message cost is driven to O(1), and every
per-frame cost is moved off the main thread.** That's what holds 60fps under the
firehose the README advertises.

---

## Appendix A — Swift/iOS concepts in C++ terms

| Swift / SwiftUI | What it is | Closest C++ mental model |
|---|---|---|
| `struct` | value type, copy semantics | `struct` passed by value |
| `class` / `actor` | reference type (heap, ARC refcounted) | `shared_ptr<T>` to a heap object |
| `Array`/`Dictionary` | copy-on-write collections | `shared_ptr<const vector>` w/ detach-on-write |
| ARC | automatic reference counting | `shared_ptr` everywhere, compiler-inserted |
| `actor` | state behind an implicit serial executor | class with a per-instance mutex, but suspends instead of blocking |
| `await` | suspension point / possible actor hop | `co_await` on a coroutine |
| `@MainActor` | runs on the UI run loop | "must hold the UI thread" |
| `Sendable` | compile-time thread-safe marker | Rust's `Send`; statically checked |
| `Task { }` | spawn a concurrent job | `std::async` / detached coroutine |
| `withTaskGroup` | structured fan-out + join | a scoped thread pool you `join()` |
| `OSAllocatedUnfairLock` | tiny userspace mutex | `os_unfair_lock` / spinlock |
| `@Observable` | macro instrumenting get/set for dependency tracking | observer pattern, auto-wired |
| SwiftUI `View.body` | pure fn returning a UI description, re-run on change | immediate-mode render fn over retained backing |
| `@State` | view-owned mutable state cell | a member whose write triggers re-render |
| `.environment(...)` | implicit context passed down the tree | thread-local / DI container scoped to a subtree |
| `enum` with payloads | tagged union / sum type | `std::variant` + pattern matching |
| `protocol` | interface / type class | abstract base class / concept |
| SwiftData `@Model` | ORM-persisted object | an entity row mapped to SQLite |
| `UIViewControllerRepresentable` | SwiftUI↔UIKit bridge | embedding a legacy widget in a new framework |

## Appendix B — Files worth reading first

In rough order, to understand the system by reading code:

1. `chattr/chattrApp.swift` — composition root (~100 lines).
2. `Packages/Features/.../App/RootView.swift` — DI, environment, launch tasks.
3. `Packages/Channels/.../ChannelSession.swift` — the actor at the core.
4. `Packages/ChatModel/.../Normalizer.swift` — the pure transform.
5. `Packages/Features/.../Chat/ChatBuffer.swift` — the ring-buffer data structure.
6. `Packages/Features/.../Chat/ChatChange.swift` — the change vocabulary.
7. `Packages/Features/.../Chat/ChatTranscriptModel.swift` — the view model orchestrating all of the above (the biggest file; the `apply()` and `send()` methods are the heart).
8. `Packages/Features/.../Chat/ChatListView.swift` — the UICollectionView bridge.
9. `Packages/Features/.../Emotes/AnimatedImageView.swift` — the Core Animation frame-cycler.
