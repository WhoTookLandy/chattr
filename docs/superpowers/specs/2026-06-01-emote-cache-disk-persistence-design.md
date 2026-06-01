# Emote & Badge Disk-Persistence Cache — Design

**Date:** 2026-06-01
**Status:** Approved (pending implementation plan)

## Problem

chattr already avoids redundant network work *within* a session:

- `GlobalCatalog.hasLoaded` loads global badges + global emotes once per session.
- `EmoteIndex.loadedBroadcasterId` loads a channel's merged 7TV/BTTV/FFZ emote
  set once per `broadcasterId`; re-mounts reuse the snapshot.
- Emote **images** are already disk-cached across launches by Nuke (`LazyImage`).

The remaining gap is **cold launch**: when the app restarts, all emote/badge
*metadata* (names → IDs → CDN URLs) is refetched. Opening a previously-visited
channel re-runs its 6 provider HTTP calls, and global data refetches every
launch. This costs a visible "blank then pop-in" on cold start and needless
bandwidth on warm same-day launches.

This design adds a disk-persistence tier for that metadata, modelled on
Chatterino2's approach (load from disk → render instantly → revalidate from
network), but tuned for iOS conventions.

### Reference: how Chatterino2 does it (for context)

- Compresses **emote-metadata JSON only** (not images) with zlib (`qCompress`),
  because it is cross-platform; images are left uncompressed (already PNG/GIF).
- Files keyed `{channelId}.{provider}` in its `Cache/` dir.
- **No TTL** — it refetches every launch unconditionally; the disk cache exists
  only to paint instantly while the refetch is in flight.
- Badges and decoded images are memory-only (no disk persistence).

chattr is already *ahead* on images (Nuke disk-caches them; Chatterino does not),
so this design targets metadata only.

## Goals

- Persist global badge/emote metadata and per-channel third-party emote metadata
  across launches.
- Instant render from disk on launch / channel-open (no cold-launch blank).
- Skip redundant network fetches on warm, same-day launches (24h freshness).
- Zero risk to user data: cache is disposable and re-derivable.

## Non-Goals

- Compression (payloads are small; `Caches/` is space-managed). Revisit only if
  profiling shows footprint matters.
- Persisting per-channel Twitch badges (`ChatBadgeStore`) — deferred; the
  per-channel file machinery built here makes it an easy follow-on.
- Persisting decoded emote images — already handled by Nuke.
- Pull-to-refresh / manual force-revalidate — future enhancement; the design
  leaves room for it.

## Decisions (locked)

| Decision | Choice |
|---|---|
| Scope | Globals (`GlobalCatalog`) + per-channel emotes (`EmoteIndex`) |
| Freshness | TTL-gated stale-while-revalidate, **24h TTL** |
| Storage | Codable JSON in `Caches/`, envelope-versioned |
| File layout | One globals file + one `{broadcasterId}.json` per channel |
| Eviction | 7-day age sweep on launch (OS purge as backstop) |
| Compression | Off for v1 |
| Mechanism | New generic `JSONDiskCache` actor in `Core` |

## Architecture

A single generic actor in the **`Core`** package, `JSONDiskCache`, owns all file
I/O. It is domain-agnostic (generic over `Codable`), keeping `Core` free of
emote/badge types and centralising the subtle logic (TTL, versioning,
atomicity, sweep) in one tested unit.

Being an `actor` moves file I/O **off the main actor** automatically:
`GlobalCatalog` (`@MainActor`) and `EmoteIndex` (`actor`) both `await` into it.

Two instances are used:

- Globals: `JSONDiskCache(subdirectory: "emote-cache")`
- Channels: `JSONDiskCache(subdirectory: "emote-cache/channels")`

### Public interface

```swift
public struct CacheHit<T> {
    public let payload: T
    public let isFresh: Bool   // (now - file mtime) < ttl
}

public actor JSONDiskCache {
    /// `baseDirectory` defaults to the user's Caches directory; injectable for tests.
    public init(subdirectory: String, baseDirectory: URL? = nil)

    /// Returns a hit (payload + freshness) or nil on miss. A miss is any of:
    /// file absent, decode failure, or `version` mismatch. Never throws —
    /// the caller treats nil as "fetch from network."
    public func load<T: Decodable>(
        key: String, as type: T.Type, version: Int, ttl: TimeInterval
    ) -> CacheHit<T>?

    /// Best-effort atomic write (`Data.write(options: .atomic)`).
    /// Failures are logged and non-fatal.
    public func save<T: Encodable>(key: String, value: T, version: Int)

    /// Deletes files in this subdirectory whose mtime is older than `maxAge`.
    public func sweep(maxAge: TimeInterval)
}
```

### Why `Caches/` (not Application Support / SwiftData)

This is re-fetchable cache data, not user-authored content. `Caches/` is the
correct iOS location: the OS can purge it under disk pressure and it is excluded
from iCloud/iTunes backup automatically. SwiftData/Application Support would
inflate the user's backup and impose migrations on throwaway data. Per-file
modification dates also give the 24h TTL for free — no timestamp field needed.

## Data Model

Every file is a version envelope. A version bump or any decode failure is
treated as a cache miss → refetch. This protects against `Emote`/`TwitchEmote`
shape changes between app releases.

```swift
struct CacheEnvelope<Payload: Codable>: Codable {
    let version: Int
    let payload: Payload
}
```

### Globals payload

```swift
struct GlobalsCachePayload: Codable {
    let badges: [BadgeDTO]                 // see below
    let emotes: [String: TwitchEmote]      // TwitchEmote is already Codable
}
```

`[ChatBadgeKey: ChatBadgeEntry]` cannot JSON-encode a struct dictionary key, so
badges are stored as an array and rebuilt into the dictionary on load:

```swift
struct BadgeDTO: Codable {
    let setId: String
    let id: String
    let url: URL
    let title: String?
}
```

`GlobalsCachePayload.cacheVersion = 1`.

### Per-channel payload

```swift
struct ChannelEmoteCachePayload: Codable {
    let broadcasterId: String              // sanity check against filename
    let byName: [String: Emote]            // the post-merge snapshot
}
```

Requires adding `Codable` to `Emote` and its nested `Size` / `Source` enums
(both `String`-raw, so conformance is automatic). We cache the **post-merge**
map (channel > global; 7TV > BTTV > FFZ already applied) and restore it directly
— no re-merge on load. `Emote` retains `source` and `ownerChannelId`, so
precedence data survives the round-trip if a future re-merge ever needs it.

`ChannelEmoteCachePayload.cacheVersion = 1`.

## Control Flow (stale-while-revalidate)

The pattern slots into the existing `load()` methods. The network path already
exists; we add a disk read before it and a disk write after it. In-memory guards
still short-circuit within a session; the 24h TTL governs only across launches.

### `GlobalCatalog.load(account:accountStore:)`

```
guard !hasLoaded else { return }                  // existing in-session guard

if let hit = await cache.load(globalsKey, as: GlobalsCachePayload.self,
                              version: GlobalsCachePayload.cacheVersion,
                              ttl: 24h) {
    globalBadges = rebuildDict(hit.payload.badges)
    globalEmotes = hit.payload.emotes
    if hit.isFresh { hasLoaded = true; return }    // fresh → skip network
}

// existing sequential badge + emote fetch …
globalBadges = badges
globalEmotes = emotes
await cache.save(globalsKey,
                 value: GlobalsCachePayload(badges: toDTOs(badges), emotes: emotes),
                 version: GlobalsCachePayload.cacheVersion)
hasLoaded = true
```

`globalsKey` is a fixed string (e.g. `"global"`). `toDTOs(_:)` maps the
`[ChatBadgeKey: ChatBadgeEntry]` dictionary to `[BadgeDTO]`; `rebuildDict(_:)`
is its inverse. (Distinct from the existing `ChatBadgeStore.flatten(sets:)`,
which converts Helix API sets into the dictionary in the first place.)

### `EmoteIndex.load(broadcasterId:broadcasterLogin:)`

```
if loadedBroadcasterId == broadcasterId { return }   // existing in-session guard

if let hit = await cache.load(broadcasterId, as: ChannelEmoteCachePayload.self,
                              version: ChannelEmoteCachePayload.cacheVersion,
                              ttl: 24h),
   hit.payload.broadcasterId == broadcasterId {
    publish(hit.payload.byName)                      // byName + snapshotLock
    if hit.isFresh { loadedBroadcasterId = broadcasterId; return }
}

// existing 2× withTaskGroup provider merge → `merged` …

guard !Task.isCancelled else { … }                   // existing guard, UNCHANGED

publish(merged)
await cache.save(broadcasterId,
                 value: ChannelEmoteCachePayload(broadcasterId: broadcasterId, byName: merged),
                 version: ChannelEmoteCachePayload.cacheVersion)
loadedBroadcasterId = broadcasterId
```

The existing cancellation guard is untouched — `save` happens only on the
success path, so a cancelled load never writes a partial snapshot.

## Eviction

One `await channelCache.sweep(maxAge: 7 * 24h)` call from `RootView`'s existing
launch `.task`. Globals is a single fixed file and needs no eviction. The OS
purge of `Caches/` remains a backstop beneath the explicit sweep. Files are
small JSON; a hard count cap is unnecessary (rejected as over-engineering).

## Error Handling

- **Reads never throw.** File absent, decode failure, version mismatch, or
  unreadable all collapse to `nil` (a miss) → the network path runs. Logged at
  debug.
- **Writes are best-effort.** Failures are logged and non-fatal — consistent
  with the existing "missing emotes simply don't render" behaviour in these
  stores.
- **Atomic writes** via `Data.write(to:options:.atomic)`. A crash mid-write
  cannot leave a half-file; if it somehow did, decode-fail → miss → refetch.

## Testing

**`JSONDiskCache` unit tests** (inject a temp `baseDirectory`; never touch real
`Caches/`):

- write → load round-trip returns the payload
- TTL boundary: a file with recent mtime is `isFresh: true`; an old mtime is
  `isFresh: false` (set mtime via `FileManager` attributes)
- version mismatch → `nil`
- corrupt bytes → `nil`
- `sweep` deletes files older than `maxAge`, keeps newer ones

**Codable round-trip** for `Emote` (with all `Size` keys + both enum cases) and
`BadgeDTO`.

**Behavioural** (fake cache + fake providers):

- fresh disk hit ⇒ providers not called
- stale disk hit ⇒ providers called *and* cache overwritten
- cancelled load ⇒ no write occurred

## Footprint / Files Touched

- **New:** `Packages/Core/Sources/Core/JSONDiskCache.swift` (+ envelope,
  `CacheHit`) and `Packages/Core/Tests/CoreTests/JSONDiskCacheTests.swift`
- **Modified:** `Emote.swift` (+`Codable`), `GlobalCatalog.swift` (disk read +
  write, `BadgeDTO`, `GlobalsCachePayload`), `EmoteIndex.swift` (disk read +
  write, `ChannelEmoteCachePayload`), `RootView.swift` (one sweep call)
- **No** SwiftData, migrations, or new dependencies.

## Future Enhancements (out of scope)

- Per-channel Twitch badge persistence (`ChatBadgeStore`) reusing the channel
  file machinery.
- Pull-to-refresh / manual force-revalidate (bypass TTL on user action).
- Optional compression (`.zlib` for portability or `.lzfse` for iOS-native
  speed) if a profiler shows the on-disk footprint matters.
