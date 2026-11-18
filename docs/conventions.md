# chattr conventions

Operating conventions for the chattr codebase — what to do, why, and the
gotchas that drove each rule. Pair this with the existing inline doc-comments
on specific types.

## Code organization

### Packages are layers; dependencies only point down

The app is a thin `@main` shell (`chattr/chattrApp.swift`, composition root
only) over a strict-DAG of local SPM packages:

```
Core  DesignSystem          ← leaves: zero internal deps
  ↑
EmoteSources  Accounts       ← depend on Core (DesignSystem: Features only)
  ↑
ChatModel(+EmoteSources)
  ↑
Channels(+Accounts,EmoteSources,ChatModel)
  ↑
Features(+everything, +Nuke) ← all SwiftUI lives here
  ↑
chattr app target            ← bootstrap + DI wiring only
```

A new dependency edge must never point *up* this list (nothing imports
`Features` except the app target; `Core`/`DesignSystem` import nothing
internal). The direction is also documented in each `Package.swift` header —
keep those in sync. This is what prevents import cycles that force everything
back into one module.

**Where new code goes:** UI (views, view models, screens) → `Features`.
Network/IO/persistence and the types they produce → the matching domain
package (`Channels`, `Accounts`, `EmoteSources`). Pure presentation transforms
→ `ChatModel`. Cross-cutting primitives (logging, errors, endpoints, disk
cache) → `Core`. Color and appearance tokens → `DesignSystem`.

### Group by feature, not by type

Inside `Features`, files are grouped into **feature folders** (vertical
slices): `Chat/`, `Channels/`, `Emotes/`, `Highlights/`, `Guest/`, `Settings/`,
`Tabs/`, `App/` and so on, plus a `Shared/` folder for genuinely
cross-feature UI primitives. A feature's screen, its `@Observable` model, its stores, and its
private helper views all live **together** in that folder. Do NOT add
`Views/` / `Models/` / `Stores/` subfolders — splitting one feature across
type-named folders fragments it and buries the thing you actually navigate by
(the feature). Co-location wins.

Domain packages (`Core`, `Channels`, …) keep a **flat** `Sources/<Pkg>/` until
they outgrow it (see thresholds below) — they're small and single-purpose.

### File-role naming taxonomy

The suffix tells you the role at a glance — keep it consistent:

| Suffix          | Role                                                        |
|-----------------|-------------------------------------------------------------|
| `*Screen`       | Top-level navigable destination (pushed/presented)         |
| `*View`         | Reusable or composed sub-view                               |
| `*Row`          | A single list/collection row                                |
| `*Sheet`        | Modal sheet content                                         |
| `*Model`        | `@MainActor @Observable` view model (per-screen state)     |
| `*Store`        | `@Observable` shared state outliving a single view         |
| `*+Environment` | `EnvironmentKey` + `EnvironmentValues` extension for a type |

### One type per file; split by sibling files in the same module

A file should hold **one** primary type. When a SwiftUI file grows because
nested `private struct` sub-views pile up (they're invisible outside the file,
so they accrete), extract each into its own file in the **same folder** and
promote it from `private` to `internal` (just drop the `private`). Within a
single module (`Features` is one module) cross-file access to an `internal`
type is free, and the library's public surface is unchanged — only `public`
types are API. Precedent: `ChatScreen.swift` (1742 LOC, 10 view types) was
split into `ChatScreen` + `ChatTranscript` + `ComposeBar` + `ThreadView` +
`ChatStatusPills`, all siblings in `Chat/`.

### Thresholds (when structure should change)

- **Split a file** when it exceeds ~500 LOC *and* holds more than one type, or
  any single type's sub-views can stand alone.
- **Add a subfolder** when a flat directory passes ~10 files *or* a clear
  sub-grouping emerges. A one-file folder (e.g. `Connection/`) is fine if it
  marks a real seam; don't manufacture them.
- **Promote a feature folder to its own package** only when build times hurt —
  cut along the heaviest folders (`Chat/`, `Channels/`, `Emotes/`) first, and
  extract any shared bits *downward* into a lower layer rather than sideways.
  Premature package-splitting trades velocity for theoretical boundaries.

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
        // Transient — show retry affordance. (`.bridgeRefreshFailed` is
        // any bridge error that doesn't say the refresh token is invalid,
        // whatever its status; an invalid one is `.sessionExpired`.)
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

## Settings

The Settings root (`ProfileScreen`, reached from the avatar on Home) is a
list of categories — Appearance, Chat, Video & Device, Accounts & Data,
About — each pushing a category screen that owns its controls. Search on
the root is backed by the static `SettingsRegistry` in `Features/Settings/`.

**Adding a setting:** put the control on the screen that owns it, then add
one line to `SettingsRegistry.entries`:

```swift
SettingsEntry("keepScreenAwake", "Keep Screen Awake", keywords: ["sleep", "lock"], in: .videoAndDevice),
```

Add `to: .filters` (etc.) when it lives on a deeper screen. A brand-new
screen also needs a `SettingsDestination` case routed in
`SettingsDestinationView`. Per-channel actions (moderator chat modes) stay
in the channel's `ChatSettingsSheet`, not in Settings.

**Row conventions** (use `SettingLabel`):

- A toggle whose effect isn't obvious gets a one-line `subtitle`.
- A setting that depends on another is `.disabled(...)` and passes
  `disabledReason:` ("Needs Native Video Player on").
- Section footers explain consequences (when it applies, what it costs),
  not what the row title already says.
- Don't repeat the section header in row titles.

**Performance:** read each preference through its own narrow `@AppStorage`
key (or the injected `ChatAppearance` value for chat rows). Never make chat
views observe a settings aggregate — flipping one setting must only
re-render the views that read that key.
