# chattr conventions

Operating conventions for the chattr codebase — what to do, why, and the
gotchas that drove each rule. Pair this with the existing inline doc-comments
on specific types.

## Logging (`os.Logger` via `AppLogger.make(_:)`)

### Severity hierarchy

| Level     | Use for                                                                 |
|-----------|-------------------------------------------------------------------------|
| `.debug`  | Verbose per-operation churn — refcount changes, per-message events.    |
|           | Hidden by DevLogView's default `.info` filter.                          |
| `.info`   | Milestones — operation completed, async work finished.                  |
| `.notice` | Boundary crossings — user action, account switch, session create/tear. |
| `.warning`| Recoverable anomalies — fell back to cache, double-release ignored.    |
| `.error`  | Operation failed — caller / UI needs to act.                            |
| `.fault`  | Programming bug — invariant violated. Currently unused (reserved).     |

### Privacy annotations

`os.Logger` redacts string interpolations by default on device. Annotate
explicitly:

```swift
// .public — visible on device, helps production debugging
logger.info("Refreshed tokens for @\(login, privacy: .public)")

// .private — redacted always (default behavior, but explicit > implicit)
logger.debug("Got refresh token \(token, privacy: .private)")

// numeric — never redacted, no annotation needed
logger.info("count = \(count)")
```

**chattr's annotation policy:**

- User logins, channel IDs, user IDs, status codes, error codes → `.public`
- Tokens, refresh tokens, Keychain values → `.private`
- Numeric counts/durations → no annotation

### Subsystem hierarchy

All loggers share `subsystem = "com.andrewbeshay.chattr"`. The category
identifies the source: `AppLogger.make("Features.ChatScreen")`,
`AppLogger.make("Channels.Registry")`, etc. By convention, category is
`<package>.<file-stem-or-component>`.

## `.task` vs `.onAppear { Task { ... } }`

### When `.task` is fine

The `.task` modifier cancels its body when the view disappears. That's
fine when:

1. The async work is **idempotent** — re-firing on remount just reruns it
   safely (no double-write, no leak). Example: `followsStore.refreshLive`,
   `globalCatalog.load` (has a `hasLoaded` guard).
2. The work has **explicit rollback** on failure. Example:
   `ChannelSessionRegistry.acquire` decrements its refcount in `catch`
   before rethrowing.
3. The cancellation is **expected** — e.g., a refresh that runs once per
   tab activation; the only "side effect" of cancellation is "no refresh
   this time."

### When to use `.onAppear { Task { ... } }`

When the work has side effects that must complete even if the view
transient disappears mid-flight:

1. The operation is **not idempotent** and replaying it would be wasteful
   or wrong.
2. The work needs to **publish a snapshot** to a longer-lived object that
   outlives the view (the actor/store that owns the snapshot survives the
   view's `@State` release).
3. There's a **race window during view transitions** where SwiftUI may
   re-evaluate the view's identity briefly. Observed in chattr's paged
   `ScrollView`: `EmoteIndex.load`'s six concurrent HTTPS calls all got
   cancelled when ChatScreen's `.task` identity dropped during
   `openChannel`'s two-step state mutation.

### Pattern

```swift
// ❌ Risk: view-tree identity flickers during openChannel cancel this
//        mid-flight, leaving an EmoteIndex with 0 entries.
.task {
    await emoteIndex.load(broadcasterId: id, broadcasterLogin: login)
}

// ✅ Detached from view lifetime — load completes even if view tears down
//   briefly. The actor keeps its snapshot for whoever holds a reference.
.onAppear {
    Task {
        await emoteIndex.load(broadcasterId: id, broadcasterLogin: login)
    }
}
```

### Refcount rollback (acquire/release pattern)

When an async operation increments a counter/refcount **before** an
`await`, the increment must roll back if the await throws:

```swift
public func acquire(...) async throws -> ChannelSession {
    refCounts[key, default: 0] += 1
    do {
        return try await session(...)
    } catch {
        // CancellationError, network error, anything — roll back so the
        // count doesn't leak forever.
        refCounts[key, default: 1] -= 1
        if refCounts[key] == 0 { refCounts[key] = nil }
        throw error
    }
}
```

## Error handling (`AppError`)

### Structured cases (preferred)

Use `AppError.sessionExpired(login:)`, `AppError.bridgeRefreshFailed(status:)`
etc. so catch sites can pattern-match:

```swift
catch let error as AppError {
    switch error.kind {
    case .sessionExpired:
        // Auth-state transition handled upstream.
    case .bridgeRefreshFailed, .network, .timeout:
        // Transient — show retry affordance.
    case .decoding, .unknown:
        // Generic fallback.
        showToast(error.localizedDescription)
    }
}
```

### Free-form fallback

`AppError(message: ...)` still works — sets `kind = .unknown(message:)`.
Use when there's no natural category. Don't proliferate one-off cases
that only have one call site.

### URLs

Every runtime URL lives in `Core.Endpoints`. Don't hardcode in providers/
views. Test fixtures are an exception (they intentionally pin to specific
endpoints).

## Async patterns

### State-as-Bridge (WWDC 2025/266)

Async work lives in actors / `@Observable` models. Sync state mutation
drives UI. Don't mix them — don't `await` from view bodies, don't
mutate `@State` from non-MainActor contexts without a hop.

### EmoteIndex.snapshot() is nonisolated

`OSAllocatedUnfairLock`-protected. Safe to read from `@MainActor`
without `await`. Use this for hot-path lookups; reserve `await
index.resolve(...)` for non-hot paths.

### Actor isolation for `@Observable` models

Always `@MainActor` for view models. SwiftUI body recomputes happen on
main; mutating from elsewhere either requires explicit hops or trips
strict-concurrency.
