# chattr — Block + Report (chat moderation)

**Status:** approved design — ready for implementation plan
**Date:** 2026-06-01

---

## What this is

Viewer-side **block** and **report** for chat — a real user feature (silence a
user you don't want to see) and the code half of App Store **Guideline 1.2**
(UGC apps must let users block abusive users and report objectionable content).

Twitch exposes no separate viewer "report a message" API; the only relevant
endpoint is `blockUser(targetUserID:sourceContext:reason:)`, where `reason` is
`.harassment` / `.spam` / `.other`. So **report = block-with-reason**: one Twitch
action satisfies both requirements, surfaced as two distinct affordances.

**Out of scope** (separate ship-readiness item, not chat code): Guideline 1.2's
fourth prong — a published EULA + in-app contact with zero-tolerance language.
That's App Store Connect metadata plus a settings link, tracked elsewhere.

## TwitchKit surface (0.3.0, already available)

- `HelixClient.blockUser(targetUserID: String, sourceContext: UserBlockSourceContext? , reason: UserBlockReason?)`
- `HelixClient.unblockUser(targetUserID: String)`
- `HelixClient.fetchUserBlockListPage(broadcasterID: String, first: Int?, after: String?) -> HelixPage<BlockedUser>`
  - `broadcasterID` is the authenticated user's own id (the account's userId).
- `struct BlockedUser { userId, userLogin, displayName }` — **`Decodable`-only**
  (not `Encodable`), so it can't be persisted directly. The `BlockStore` keeps a
  small local `Codable` model (`BlockedUser` in `Features` — fully-qualify
  `TwitchKit.BlockedUser` at the fetch boundary to disambiguate) and maps from
  Twitch's type on fetch.
- `enum UserBlockReason { harassment, spam, other }`, `enum UserBlockSourceContext { chat, whisper }`.
- `ChatMessage` carries `chatterUserId`, `chatterUserLogin`, `chatterUserName` — the block target + filter key.

---

## Architecture — one new unit: `BlockStore`

A per-account `@Observable @MainActor final class BlockStore` (new file in
`Features`, alongside `GlobalCatalog` which it mirrors). Single source of truth
for blocked users; everything else reads/writes through it.

**State:** `private(set) var blocked: [BlockedUser]` (the local `Codable` model,
not `TwitchKit.BlockedUser`) + a derived `blockedIds: Set<String>` for O(1) filter
lookups.

**Public API:**
```swift
func isBlocked(_ userId: String) -> Bool
func block(userId: String, login: String, displayName: String, reason: UserBlockReason) async
func unblock(userId: String) async
func load(accountUserId: String, accountStore: AccountStore) async   // seed on launch
```

**Seed (`load`):** load the persisted cache first (instant), then paginate
`fetchUserBlockListPage(broadcasterID: accountUserId, after: cursor)` until the
cursor is nil, and **replace** the set with Twitch's authoritative list (Twitch
wins). Persist the result.

**Mutations (optimistic):**
- `block`: insert a `BlockedUser(userId:userLogin:displayName:)` into the set
  immediately (instant hide) + persist; then `blockUser(targetUserID:userId,
  sourceContext:.chat, reason:)`. On failure, remove it again (rollback) + log.
- `unblock`: remove immediately + persist; then `unblockUser(targetUserID:)`. On
  failure, re-insert (rollback) + log.

**Persistence:** the `[BlockedUser]` is `Codable`-encoded into UserDefaults keyed
by `"blockedUsers.<accountUserId>"` (per-account, per-device — same pattern as the
app's other UserDefaults state). The Twitch fetch in `load` is authoritative; the
cache only makes blocks apply before the fetch returns.

**Ownership:** `RootView` owns one `BlockStore` for the active account (one active
account at a time), seeds it in a launch `.task(id: activeAccount?.userId)`
(alongside the existing prefetch/cleanup tasks), and injects it via the
environment (`\.blockStore`) — same wiring as `globalCatalog`.

## Components & data flow

1. **`ChatRow` context menu** (`…/Chat/ChatRow.swift`): add `onBlock: (() -> Void)?`
   and `onReport: ((UserBlockReason) -> Void)?` next to `onReply`/`onViewThread`/
   `onDelete`. Menu items, shown only on real message rows that are **not the
   current user's own**:
   - **"Block @login"** → `onBlock()` → `BlockStore.block(reason: .other)`.
   - **"Report…"** → a `confirmationDialog` with **Harassment** / **Spam** →
     `onReport(reason)` → `BlockStore.block(reason:)` (report also blocks; only
     API). On success, show a **brief transient confirmation** ("Reported &
     blocked") — a ~2s auto-dismissing glass capsule reusing the connection /
     jump-to-latest pill pattern. **Block stays silent** (the message vanishing is
     its own feedback); the confirmation differentiates the heavier Report action
     and gives App Store review a visible report acknowledgement.
2. **`TabChatModel` filtering** (`…/Chat/TabChatModel.swift`): the displayed
   `lines` exclude any line whose `authorUserId` is in `blockStore.blockedIds`.
   The filter is **kind-agnostic** — it keys on `ChatLine.authorUserId`, which the
   Normalizer populates for every kind, so a blocked user's **messages AND their
   sub/raid bubbles** all disappear (the coherent "invisible to me" behavior) with
   one predicate, no special-casing. Reactive — blocking removes their **existing**
   lines from the view immediately. The pure core is
   `BlockFilter.apply(lines:, blockedIds:) -> [ChatLine]`, unit-tested; the model
   calls it when building `lines` and re-runs it when the set changes (TabChatModel
   observes the `BlockStore`).
3. **`BlockedUsersScreen`** (`Features`): a `List` of `blockStore.blocked`
   (display name + @login) each with an **Unblock** button → `BlockStore.unblock`.
   Empty state via `ContentUnavailableView`. This is the only place to unblock —
   blocked users' messages are hidden, so chat long-press isn't reachable.
4. **`ProfileScreen`** (`…/Account/ProfileScreen.swift`): a `Section` with a
   `NavigationLink { BlockedUsersScreen() }`, mirroring the existing
   `HighlightKeywordsScreen` link.

**Flow:** long-press a message → Block / Report → `BlockStore.block` (optimistic
set update → `lines` re-filter hides them → Helix `blockUser`) → persisted.
Unblock from Profile → `BlockStore.unblock` → Helix → that user's future messages
appear again.

## Error handling

- All mutations are **optimistic with rollback**: a failed `blockUser` /
  `unblockUser` reverts the local set and logs (best-effort, consistent with the
  rest of the app's network surface). The UI never blocks on the round-trip.
- `load`'s Twitch fetch failing → keep the persisted cache (don't wipe it); log.
- Self-protection: the Block/Report items never appear on the current user's own
  messages, so a user can't block themselves.

## Testing

- **`BlockFilter.apply(lines:, blockedIds:)`** (pure): a blocked author's lines of
  **any** kind are removed (message AND sub/raid bubble — keyed on `authorUserId`);
  lines from non-blocked authors pass through; an empty set is the identity. Unit
  test (Features).
- **`BlockStore` set logic** (the testable, non-I/O parts): optimistic insert
  then rollback restores the prior set; `load` reconcile **replaces** with the
  fetched list; `isBlocked` reflects the set. Inject a stub block/unblock/fetch
  so the Helix calls aren't real — or extract the pure set transitions into
  testable helpers and unit-test those.
- **Manual:** context menu Block/Report on a live message hides that user; the
  Profile blocked-users screen lists + unblocks; a blocked user persists across
  relaunch (hidden before the launch fetch completes).

## Implementation order

1. `BlockFilter.apply` pure helper + test.
2. `BlockStore` (+ persistence + set-logic tests), `\.blockStore` environment key.
3. `RootView` owns + seeds + injects `BlockStore`.
4. `TabChatModel` filters `lines` via `BlockFilter`, reactively.
5. `ChatRow` Block + Report… context-menu items (+ own-message guard) wired to `BlockStore`.
6. `BlockedUsersScreen` + `ProfileScreen` link.
7. Build + manual verification.
