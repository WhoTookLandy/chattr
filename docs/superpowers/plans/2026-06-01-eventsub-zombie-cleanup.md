# EventSub Zombie Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On launch, reap the dead EventSub subscriptions a previous crash/force-quit left behind so they stop counting against Twitch's per-app subscription quota.

**Architecture:** A best-effort registry method lists the active account's EventSub subscriptions and deletes every one whose status is not `.enabled`. It's fired once per active account from `RootView`'s existing launch `.task`, concurrently with (and independent of) session startup — a fresh subscribe produces an `.enabled` sub the sweep ignores, so ordering is irrelevant.

**Tech Stack:** Swift 6.2 (strict concurrency), `@MainActor`, TwitchKit 0.3.0 (`HelixClient.eventSubSubscriptions()` → `HelixPagedSequence<EventSubSubscriptionRecord>`, `deleteEventSubSubscription(id:)`, `EventSubSubscriptionStatus`).

**Spec:** `docs/superpowers/specs/2026-06-01-lifecycle-resilience-design.md` (Feature 1; Feature 2 deferred).

**Scope note:** This is a small two-edit feature (one registry method + one launch call). There is no pure-logic seam worth a unit test — the only "logic" is the `if case .enabled` keep-check, which is a trivial pattern match, and the rest is best-effort network I/O. Correctness is established by a build + the manual force-quit check in Task 3. This is called out so the absence of a unit test is a deliberate, documented choice, not an oversight.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift` | `cleanupDisconnectedSubscriptions(forAccountUserId:)` — list + reap non-enabled subs, best-effort | Modify |
| `Packages/Features/Sources/Features/App/RootView.swift` | Fire the cleanup once per active account at launch | Modify |

---

## Task 1: Registry cleanup method

**Files:**
- Modify: `Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift` (add a method near the other per-account helpers, e.g. after `cleanupDispatcherIfIdle`/`ensureEventDispatch` or alongside the public accessors)

- [ ] **Step 1: Add the method**

Add to `ChannelSessionRegistry` (it already holds `accountStore` and resolves clients via `accountStore.client(forUserId:)`):

```swift
    // MARK: - Cold-start zombie cleanup

    /// Reaps dead EventSub subscriptions left behind by a previous
    /// crash/force-quit. WebSocket subscriptions are session-bound: when the app
    /// is killed and the socket isn't resumed in time, Twitch marks them
    /// `websocket_disconnected` (and similar) and auto-removes them within ~1h —
    /// but they count against the per-app subscription quota until then. This
    /// frees that quota immediately on launch.
    ///
    /// Deletes every subscription whose status is **not** `.enabled`. For a
    /// websocket-only client `enabled` is the only live status, so this can never
    /// remove a subscription we're actually using — even if it races session
    /// startup (a fresh subscribe produces an `.enabled` sub this skips). Covers
    /// every dead status without enumerating them, and is future-proof.
    ///
    /// Best-effort: any error (list or delete) is logged and swallowed. Never
    /// blocks or fails chat startup.
    public func cleanupDisconnectedSubscriptions(forAccountUserId accountUserId: String) async {
        let client = accountStore.client(forUserId: accountUserId)
        do {
            var reaped = 0
            for try await record in client.api.eventSubSubscriptions() {
                if case .enabled = record.status { continue }   // keep live subs
                try? await client.api.deleteEventSubSubscription(id: record.id)
                reaped += 1
            }
            if reaped > 0 {
                logger.notice("Reaped \(reaped) dead EventSub subscription(s) for account \(accountUserId, privacy: .public)")
            }
        } catch {
            // Listing failed (auth/network). Cleanup is best-effort — Twitch's
            // own auto-removal is the backstop.
            logger.debug("EventSub zombie cleanup skipped for \(accountUserId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
```

- [ ] **Step 2: Build the package**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift build 2>&1 | tail -5
```
Expected: `Build complete!`
> If `record.status` doesn't expose `.enabled` via pattern match, confirm the type: `EventSubSubscriptionRecord.status` is `EventSubSubscriptionStatus` (an enum with an `enabled` case). The `if case .enabled = record.status` form needs no Equatable conformance.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift
git commit -m "Channels: cleanupDisconnectedSubscriptions reaps dead EventSub subs"
```

---

## Task 2: Fire cleanup at launch from RootView

**Files:**
- Modify: `Packages/Features/Sources/Features/App/RootView.swift` (add a sibling `.task(id: activeAccount?.userId)` near the existing launch tasks ~line 119–145)

- [ ] **Step 1: Add the launch task**

After the existing `.task(id: activeAccount?.userId)` blocks (global prefetch, user-emote prefetch, keychain mirror), add another sibling on the same view:

```swift
        // Cold-start EventSub zombie cleanup. Reap dead subscriptions a previous
        // crash/force-quit left behind so they stop counting against Twitch's
        // per-app quota. Best-effort; runs concurrently with the prefetch tasks
        // and with session startup (it only deletes non-enabled subs, so it can't
        // touch a live subscription). `.task(id:)` re-fires on account swap.
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else { return }
            await channelSessionRegistry.cleanupDisconnectedSubscriptions(forAccountUserId: active.userId)
        }
```
> `channelSessionRegistry` is already a stored `let` on `RootView` (used in `.environment(\.channelSessionRegistry, channelSessionRegistry)`), so it's in scope here.

- [ ] **Step 2: Build the Features package**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 3: Build the full app**

Run:
```bash
cd /Users/landy/Dev/chattr
xcodebuild -scheme chattr -destination 'platform=iOS Simulator,id=54AA7091-7412-44AA-8936-015E77324873' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```
Expected: `** BUILD SUCCEEDED **`
> If the simulator id is stale: `xcrun simctl list devices available | grep iPhone` and substitute.

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/App/RootView.swift
git commit -m "Features: fire EventSub zombie cleanup once per active account at launch"
```

---

## Task 3: Manual verification

**Files:** none.

- [ ] **Step 1: Force-quit zombie check**

1. Launch the app, sign in, open one or more channels (creates `enabled` subscriptions).
2. **Force-quit** the app (swipe up from the app switcher) — this kills the WebSocket without a clean unsubscribe, leaving the subscriptions in a dead state server-side.
3. Re-launch the app.
4. Confirm via logs that the cleanup ran: look for `Reaped N dead EventSub subscription(s)` (or, if Twitch already auto-removed them, no reap and no error). Optionally cross-check with Twitch's Get EventSub Subscriptions API that no `websocket_disconnected` subscriptions linger for the account.

- [ ] **Step 2: No-regression check**

Normal launch (no prior force-quit) must not disturb live chat: open a channel, confirm messages flow and the cleanup logs either "Reaped 0" silently (no notice) or nothing — and that the channel's own fresh subscriptions (status `.enabled`) are untouched.

---

## Self-Review (completed by plan author)

- **Spec coverage:** Feature 1 (cold-start cleanup, delete-all-non-`enabled`, best-effort, per active account, fired at launch) → Tasks 1–2; manual force-quit verification → Task 3. Feature 2 is deferred per the spec and is intentionally absent.
- **Type consistency:** `cleanupDisconnectedSubscriptions(forAccountUserId:)`, `client.api.eventSubSubscriptions()`, `record.status` / `record.id`, `client.api.deleteEventSubSubscription(id:)` — used identically across tasks and match TwitchKit 0.3.0's surface.
- **No placeholders:** both code steps show complete code; run steps show commands + expected output. The deliberate no-unit-test decision is documented in the Scope note, not left implicit.
- **Home deviation from spec:** the launch call lives in `RootView` (which owns the active-account launch `.task`s) rather than the spec's "AppShell" — RootView is the accurate owner; noted here so it isn't read as drift.
