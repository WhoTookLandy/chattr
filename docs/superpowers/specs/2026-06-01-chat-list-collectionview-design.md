# Chat list: UICollectionView-backed transcript

**Date:** 2026-06-01
**Status:** Design approved — pending spec review, then implementation plan
**Scope:** `Packages/Features` — the live chat transcript in `ChatScreen`

---

## Problem

The live chat transcript is a SwiftUI `ScrollView` + `LazyVStack` of `ChatRow`s
([ChatScreen.swift:437](../../../Packages/Features/Sources/Features/ChatScreen.swift)).
Under the load a Twitch chat actually sees, this model strains:

- **Measured:** 93,732 `ChatRow` body evaluations in 68 seconds (~1,378/sec) —
  far beyond what `visible-rows × 60Hz` could justify. The `ChatRow: Equatable`
  conformance ([ChatRow.swift:86](../../../Packages/Features/Sources/Features/ChatRow.swift))
  was added specifically to suppress this, and helped — but the structural cause
  (a `LazyVStack` re-diffing a 500-element `ForEach` on every append) remains.
- **Scroll anchoring is hand-rolled.** `.onScrollGeometryChange` +
  `.scrollPosition(id:)` + `.onChange(of: lines.count)`
  ([ChatScreen.swift:535-579](../../../Packages/Features/Sources/Features/ChatScreen.swift))
  reimplement bottom-pinning that a collection view provides natively. The
  append animation is *disabled* because "under burst traffic (50-200 msg/sec
  during raids) queued animations stutter."
- **Sliding ring buffer.** `chatModel.lines` is capped at 500 via `removeFirst`
  ([TabChatModel.swift:1071](../../../Packages/Features/Sources/Features/TabChatModel.swift));
  rows are appended at the end and dropped from the front, while in-place edits
  (optimistic→delivered upgrade, `markFailed`, `deletedPlaceholder` flips,
  `chatCleared`) mutate by stable `id`. `ForEach` diffs the whole collection on
  each change; a diffable data source applies a minimal delta.

Every mature chat client (Messages, Telegram, Discord) renders its transcript
with a recycling collection view for exactly these reasons.

### Honest baseline note

iOS 26 already improved `List`/`LazyVStack` update speed (~16× on large lists)
and scroll frame-scheduling automatically, and the `Equatable` fix already cut
unnecessary evals. The win here is therefore **incremental over an already-improved
baseline** — which is why this work is gated on a measured comparison (see
[Testing & measurement](#testing--measurement)) against the *current*
post-`Equatable`, iOS-26 `LazyVStack`, not an old assumption.

---

## Goals / non-goals

**Goals**
- Replace the main `ChatScreen` transcript with a recycling
  `UICollectionView`, preserving full behavior parity.
- Keep `ChatRow` and all its SwiftUI behavior verbatim (context menu,
  highlighted backplate, bubble rows, reply quote, failure footer).
- Reduce per-message body-eval volume to "only cells whose `ChatLine`
  actually changed."

**Non-goals (this pass)**
- The `ThreadView` transcript ([ChatScreen.swift:1153](../../../Packages/Features/Sources/Features/ChatScreen.swift))
  keeps its `LazyVStack` — it's a bounded, filtered, mostly-static slice with no
  raid pressure. The new component is designed to *allow* reuse there later, but
  wiring it is out of scope now (YAGNI).
- No change to `TabChatModel`, the normalizer, the send/echo reconciliation, or
  the image pipeline. The model stays **ignorant of scroll state** (see
  anchoring decision below).
- The TextKit message-rendering rewrite (collapsing `FlowLayout`'s N-views-per-row
  into one attributed string) is a separate, later opportunity — not in scope.

---

## Approach decision

**Chosen: B — non-inverted `UICollectionView` + explicit anchoring.**

| Option | Summary | Verdict |
|---|---|---|
| A. Inverted-transform (`scaleX:1,y:-1`) | Free bottom-pinning, but the vertical flip degrades SwiftUI `.contextMenu` previews (every row has one) and needs special handling for the glass edge effect + VoiceOver reading order. | Rejected — flips fight the hosted SwiftUI. |
| **B. Non-inverted + explicit anchoring** | `UIHostingConfiguration` cells render `ChatRow` unflipped; context menus, glass, keyboard dismiss, VoiceOver all behave normally. Cost: explicit anchoring logic (mostly already present as `isAtBottom`). | **Chosen.** |
| C. Hand-drawn TextKit cells | Max performance, drops `ChatRow` entirely, merges in the TextKit rewrite. | Deferred — separate, larger pass. |

---

## Architecture & components

New file `Packages/Features/Sources/Features/ChatListView.swift`, four units:

### 1. `ChatListView: UIViewControllerRepresentable`
The thin bridge. (Controller, not bare view — a collection view wants a VC for
cell lifecycle, prefetching, and safe-area handling.) Inputs:

- `lines: [ChatLine]` — passed from `ChatScreen.body` (which already
  re-evaluates per message).
- `rowContent: (ChatLine) -> ChatRow` — builds a row including the badge lookup
  and the four per-line callbacks (`onRetry`/`onReply`/`onViewThread`/`onDelete`)
  **exactly as `ChatScreen` builds them today**. Keeping construction in
  `ChatScreen` keeps the component ignorant of the model layer (and reusable for
  `ThreadView` later with a different builder).
- `isAtBottom: Binding<Bool>` — UIKit → SwiftUI; drives the pill + unread gating.
- `scrollToBottomToken: Int` — SwiftUI → UIKit; the pill tap increments it,
  `updateUIViewController` compares against the last-seen value and scrolls.

`updateUIViewController` calls `vc.update(lines:scrollToBottomToken:)`. No
`withObservationTracking` needed — the representable update cycle is the trigger.
(Observing `lines` directly in the VC is a possible later optimization if the
per-message `ChatScreen.body` re-eval ever shows up in a profile; it won't —
`body` just hands over a COW array reference.)

### 2. `ChatListViewController: UIViewController`
Owns:
- The `UICollectionView` + a **custom compositional layout**: single section,
  `.estimated(44)` full-width items, zero insets, clear background. *Not*
  `UICollectionLayoutListConfiguration` — its separators/insets fight the bubble
  rows and highlighted backplates.
- An `NSDiffableDataSourceSnapshot` keyed by `line.id` (`String`, `Hashable`).
  `ChatLine` is `Equatable` but **not** `Hashable` (`LineRun` omits it), so the
  item identifier is the id; the cell provider looks up the `ChatLine` by id from
  the last-applied array.
- Cells via `cell.contentConfiguration = UIHostingConfiguration { rowContent(line) }`.
  `ChatRow` renders verbatim, including its own `.contextMenu` — **no** UIKit
  `contextMenuConfiguration` (no duplication).
- `keyboardDismissMode = .interactive` (≡ `.scrollDismissesKeyboard(.interactively)`).
- `collectionView.topEdgeEffect.style = .hard` (≡ `.scrollEdgeEffectStyle(.hard,
  for: .top)`; confirmed via Apple's UIKit Liquid Glass doc). Optionally a
  `UIScrollEdgeElementContainerInteraction` so the compose bar / pill overlays
  shape the edge effect.
- The scroll delegate (computes + publishes `isAtBottom`, drives auto-tail and
  anchor preservation).

### 3. `ChatListDiff` (pure, UIKit-free)
`compute(old: [ChatLine], new: [ChatLine]) -> Delta` producing inserted /
deleted / reconfigured ids. The unit-testable correctness core.

### 4. `ScrollAnchor` (pure helpers)
- `isNearBottom(contentSize:offset:container:inset:) -> Bool` — mirrors the
  existing 44pt threshold.
- The offset-preservation math used during front-trim (below).

---

## Data flow & diffing

1. `ChatScreen.body` reads `chatModel.lines` (as today) → hands it to
   `ChatListView`.
2. `updateUIViewController` → `vc.update(lines:…)`.
3. VC diffs new vs. last-applied via `ChatListDiff`, applies the snapshot with
   **`animatingDifferences: false`** (matches the existing "no animation under
   burst" decision).
4. Same-id-but-changed-value lines (upgrade / fail / delete flips) become
   `snapshot.reconfigureItems([ids])` — only those cells re-render; untouched
   cells are never visited. **This is what replaces the 1,378 evals/sec.**

---

## Scroll anchoring & behavior parity

Three cases, handled in the scroll delegate / on snapshot apply:

- **Tailing (at bottom):** after a snapshot that appended rows, scroll to the
  last item, no animation.
- **Scrolled up, append below viewport:** do nothing — offset is naturally
  stable.
- **Front-trim while scrolled up (the hard case):** `removeFirst(n)` deletes
  rows *above* the viewport, which would jump the content. Use **anchor-offset
  preservation** (chosen over a "pause-trim" flag to keep `TabChatModel` free of
  scroll coupling): before applying, record the topmost visible item's id and its
  `frame.minY − contentOffset.y`; after applying, find that item's new frame and
  restore `contentOffset` by the delta. ~15 lines, and it also absorbs the mass
  in-place edits (`chatCleared` flipping all 500 rows).

**Parity checklist**

| Today (SwiftUI) | New (UIKit) |
|---|---|
| Jump-to-bottom pill + unread tally (overlay) | **Unchanged** — stays a SwiftUI overlay on `ChatScreen`, reads bridged `isAtBottom` + existing `onChange(of: lines.count)`. |
| `isAtBottom` via `.onScrollGeometryChange` (fires on flip) | Scroll delegate computes it; writes the `@Binding` **only on flip** (VC stores last value) to avoid per-frame thrash. |
| `.scrollDismissesKeyboard(.interactively)` | `keyboardDismissMode = .interactive`. |
| `.scrollEdgeEffectStyle(.hard, for: .top)` | `collectionView.topEdgeEffect.style = .hard`. |
| Initial scroll-to-bottom on appear | First snapshot scrolls to last item. |
| Natural VoiceOver order | Preserved (non-inverted). |

---

## De-risking checkpoint (do first)

Before building the data source / anchoring, build a **one-cell spike** proving
the two bridging unknowns the docs didn't fully settle:

1. `UIHostingConfiguration { ChatRow(...) }` self-sizes correctly with
   `.estimated` heights — `ChatRow`'s `FlowLayout` must report a stable height to
   the cell (watch for clipping; the fix per axiom-uikit is `.estimated`, not
   fixed, item dimensions).
2. `ChatRow`'s SwiftUI `.contextMenu` opens and its preview animates correctly
   from inside the cell.

If either fails, revisit before investing in the full machinery.

---

## Testing & measurement

**Unit (Swift Testing, no UIKit)**
- `ChatListDiff`: append, front-trim, in-place upgrade, `chatCleared` (all
  reconfigure), `retry` remove.
- `ScrollAnchor.isNearBottom`: the threshold math against the scenarios the
  current `onScrollGeometryChange` covers.

**Manual / Instruments**
- Anchor-offset preservation: needs real layout — verify by raid-replay, not a
  brittle unit test.

**Measurement gate (the production decision evidence)**
Instruments 26, SwiftUI + Time Profiler template, Release build, real device:
- **Long View Body Updates** lane — confirm `ChatRow` eval volume drops vs. the
  current post-`Equatable`, iOS-26 `LazyVStack` baseline.
- **Long Representable Updates** lane — confirm the new `updateUIViewController`
  (diff + snapshot apply) does **not** become the new bottleneck.
- **Hangs & Hitches** — confirm scroll hitches during a simulated 50-200 msg/sec
  burst are reduced.

---

## Risks & open questions

- **Context menu inside hosting cell** — the de-risking checkpoint settles this
  before broad investment.
- **`reconfigureItems` vs `reloadItems`** — prefer `reconfigure` (reuses the
  existing cell, cheaper); fall back to `reload` only if a hosted-config update
  misbehaves.
- **Prefetching** — `UICollectionViewDataSourcePrefetching` could warm the Nuke
  cache for upcoming rows via the existing `ChatImagePrefetcher`. Nice-to-have,
  not core; listed as a follow-up.
- **Self-sizing churn** — estimated heights cause a brief settle as cells size;
  acceptable, but watch during the spike.

---

## Files touched

- **New:** `Packages/Features/Sources/Features/ChatListView.swift`
  (`ChatListView` + `ChatListViewController` + `ChatListDiff` + `ScrollAnchor`).
- **Edit:** `Packages/Features/Sources/Features/ChatScreen.swift` — swap the
  `ScrollView`/`LazyVStack` in `chatScrollView` for `ChatListView`; keep the pill
  overlay, the `isAtBottom`/`unread` state, and the `scrollToBottomToken` plumbing.
- **New tests:** `Packages/Features/Tests/FeaturesTests/ChatListDiffTests.swift`,
  `ScrollAnchorTests.swift`.
