# Emote & Badge Disk-Persistence Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist global + per-channel emote/badge metadata to disk so a cold launch (and reopening a previously-visited channel) renders instantly and skips redundant network fetches for 24h.

**Architecture:** A single generic `JSONDiskCache` actor in the `Core` package owns all file I/O (envelope-versioned Codable JSON in `Caches/`, per-file-mtime TTL, age sweep). Two consumers — `GlobalCatalog` and `EmoteIndex` — gain a stale-while-revalidate path: read disk → render → revalidate from network if stale → overwrite. No compression, no SwiftData, no new dependencies.

**Tech Stack:** Swift 6.2, SPM multi-package workspace, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), Foundation `JSONEncoder`/`FileManager`, `os` (`AppLogger`, `OSAllocatedUnfairLock`).

**Design spec:** `docs/superpowers/specs/2026-06-01-emote-cache-disk-persistence-design.md`

---

## File Structure

| File | Responsibility | Package |
|---|---|---|
| `Packages/Core/Sources/Core/JSONDiskCache.swift` (create) | Generic actor: `load`/`save`/`sweep`, `CacheEnvelope`, `CacheHit`, `CacheSubdirectory` constants | Core |
| `Packages/Core/Tests/CoreTests/JSONDiskCacheTests.swift` (create) | Unit tests for the cache (round-trip, TTL, version, corrupt, sweep) | Core |
| `Packages/EmoteSources/Sources/EmoteSources/Emote.swift` (modify) | Add `Codable` to `Emote`, `Size`, `Source` | EmoteSources |
| `Packages/EmoteSources/Sources/EmoteSources/ChannelEmoteCachePayload.swift` (create) | Per-channel cache payload type | EmoteSources |
| `Packages/EmoteSources/Sources/EmoteSources/EmoteIndex.swift` (modify) | Inject cache; disk read/write in `load(...)` | EmoteSources |
| `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteCodableTests.swift` (create) | `Emote`/payload round-trip | EmoteSources |
| `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteIndexCacheTests.swift` (create) | Behavioral: fresh-hit skips network, stale refetches+writes | EmoteSources |
| `Packages/Channels/Sources/Channels/GlobalsCachePayload.swift` (create) | `BadgeDTO` + `GlobalsCachePayload` (+ badge dict ↔ DTO conversion) | Channels |
| `Packages/Channels/Tests/ChannelsTests/GlobalsCachePayloadTests.swift` (create) | DTO round-trip + dict inverse | Channels |
| `Packages/Features/Sources/Features/Emotes/GlobalCatalog.swift` (modify) | Inject cache; disk read/write in `load(...)` | Features |
| `Packages/Features/Sources/Features/App/RootView.swift` (modify) | One-time launch sweep of the channel cache dir | Features |

**Note on the badge-payload home:** `BadgeDTO`/`GlobalsCachePayload` live in **Channels** (not Features) because `ChatBadgeKey`/`ChatBadgeEntry` are defined there and `TwitchKit` is a Channels dependency — this gives the type a macOS-testable home (`swift test --package-path Packages/Channels`), which Features (SwiftUI/iOS-heavy) is not guaranteed to provide. `GlobalCatalog` in Features already `import Channels`.

---

## Task 1: Make `Emote` Codable

**Files:**
- Modify: `Packages/EmoteSources/Sources/EmoteSources/Emote.swift`
- Test: `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteCodableTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteCodableTests.swift`:

```swift
import Foundation
import Testing
@testable import EmoteSources

@Suite("Emote Codable")
struct EmoteCodableTests {
    @Test("Emote round-trips through JSON with all sizes and flags")
    func emoteRoundTrips() throws {
        let original = Emote(
            id: "7tv:abc123",
            name: "PogChamp",
            urls: [
                .x1: URL(string: "https://cdn.7tv.app/abc/1x.webp")!,
                .x2: URL(string: "https://cdn.7tv.app/abc/2x.webp")!,
                .x4: URL(string: "https://cdn.7tv.app/abc/4x.webp")!,
            ],
            isAnimated: true,
            isZeroWidth: false,
            source: .sevenTV,
            ownerChannelId: "12345"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Emote.self, from: data)

        #expect(decoded == original)
        #expect(decoded.urls[.x4]?.absoluteString == "https://cdn.7tv.app/abc/4x.webp")
        #expect(decoded.source == .sevenTV)
        #expect(decoded.ownerChannelId == "12345")
    }

    @Test("Global emote (nil ownerChannelId) round-trips")
    func globalEmoteRoundTrips() throws {
        let original = Emote(
            id: "bttv:zzz",
            name: "KEKW",
            urls: [.x1: URL(string: "https://cdn.betterttv.net/zzz/1x")!],
            isAnimated: false,
            isZeroWidth: false,
            source: .bttv,
            ownerChannelId: nil
        )
        let decoded = try JSONDecoder().decode(Emote.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.ownerChannelId == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/EmoteSources --filter EmoteCodableTests`
Expected: FAIL — compile error, `Emote` does not conform to `Encodable`/`Decodable`.

- [ ] **Step 3: Add Codable conformance**

In `Packages/EmoteSources/Sources/EmoteSources/Emote.swift`, change the type and both nested enum declarations to add `Codable`:

Line 9 — change:
```swift
public struct Emote: Sendable, Equatable, Hashable, Identifiable {
```
to:
```swift
public struct Emote: Codable, Sendable, Equatable, Hashable, Identifiable {
```

Line 41 — change:
```swift
    public enum Size: String, Sendable, Equatable, Hashable, CaseIterable {
```
to:
```swift
    public enum Size: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
```

Line 45 — change:
```swift
    public enum Source: String, Sendable, Equatable, Hashable, CaseIterable {
```
to:
```swift
    public enum Source: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
```

No other changes — Codable synthesis covers all stored properties.

> Note: `[Emote.Size: URL]` encodes as a JSON *array* of alternating key/value (Swift only emits a JSON object for `String`/`Int` keys). This round-trips losslessly — the test above confirms it. Do not be alarmed by the array shape in the on-disk JSON.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/EmoteSources --filter EmoteCodableTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/EmoteSources/Sources/EmoteSources/Emote.swift \
        Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteCodableTests.swift
git commit -m "EmoteSources: make Emote Codable for disk caching

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `JSONDiskCache` actor in Core

**Files:**
- Create: `Packages/Core/Sources/Core/JSONDiskCache.swift`
- Test: `Packages/Core/Tests/CoreTests/JSONDiskCacheTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Core/Tests/CoreTests/JSONDiskCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import Core

@Suite("JSONDiskCache")
struct JSONDiskCacheTests {

    struct Sample: Codable, Sendable, Equatable {
        let name: String
        let count: Int
    }

    /// Fresh unique temp directory per test — never touches the real Caches dir.
    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jsondiskcache-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("save then load returns payload and is fresh")
    func saveLoadFresh() async throws {
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: tempBase())
        await cache.save(key: "k", value: Sample(name: "a", count: 1), version: 1)

        let hit = await cache.load(key: "k", as: Sample.self, version: 1, ttl: 60)
        #expect(hit?.payload == Sample(name: "a", count: 1))
        #expect(hit?.isFresh == true)
    }

    @Test("missing file is a miss")
    func missIsNil() async {
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: tempBase())
        let hit = await cache.load(key: "absent", as: Sample.self, version: 1, ttl: 60)
        #expect(hit == nil)
    }

    @Test("version mismatch is a miss")
    func versionMismatch() async {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        await cache.save(key: "k", value: Sample(name: "a", count: 1), version: 1)

        let hit = await cache.load(key: "k", as: Sample.self, version: 2, ttl: 60)
        #expect(hit == nil)
    }

    @Test("corrupt bytes are a miss")
    func corruptIsNil() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        let dir = base.appendingPathComponent("t", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("k.json"))

        let hit = await cache.load(key: "k", as: Sample.self, version: 1, ttl: 60)
        #expect(hit == nil)
    }

    @Test("file older than ttl loads but is not fresh")
    func staleNotFresh() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        await cache.save(key: "k", value: Sample(name: "a", count: 1), version: 1)

        // Backdate the file's modification time to 2 hours ago.
        let url = base.appendingPathComponent("t", isDirectory: true)
            .appendingPathComponent("k.json")
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)

        let hit = await cache.load(key: "k", as: Sample.self, version: 1, ttl: 3600)
        #expect(hit?.payload == Sample(name: "a", count: 1))   // still returns data
        #expect(hit?.isFresh == false)                          // but flagged stale
    }

    @Test("sweep deletes files older than maxAge and keeps newer ones")
    func sweepDeletesOld() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "t", baseDirectory: base)
        await cache.save(key: "old", value: Sample(name: "o", count: 1), version: 1)
        await cache.save(key: "new", value: Sample(name: "n", count: 2), version: 1)

        let dir = base.appendingPathComponent("t", isDirectory: true)
        let oldDate = Date().addingTimeInterval(-10 * 24 * 3600)   // 10 days ago
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: dir.appendingPathComponent("old.json").path)

        await cache.sweep(maxAge: 7 * 24 * 3600)                  // 7 days

        #expect(await cache.load(key: "old", as: Sample.self, version: 1, ttl: 60) == nil)
        #expect(await cache.load(key: "new", as: Sample.self, version: 1, ttl: 60) != nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/Core --filter JSONDiskCache`
Expected: FAIL — compile error, `JSONDiskCache` is not defined.

- [ ] **Step 3: Implement `JSONDiskCache`**

Create `Packages/Core/Sources/Core/JSONDiskCache.swift`:

```swift
import Foundation
import os

private let logger = AppLogger.make("Core.JSONDiskCache")

/// Well-known cache subdirectories (under `Caches/`). Centralised so writers
/// and the launch-time sweep agree on the same path strings.
public enum CacheSubdirectory {
    /// Global Twitch badge + emote metadata (single file).
    public static let emoteGlobals = "emote-cache"
    /// Per-channel third-party emote metadata (one file per broadcasterId).
    public static let emoteChannels = "emote-cache/channels"
}

/// Versioned wrapper written to disk. A version bump invalidates older files.
struct CacheEnvelope<Payload: Codable>: Codable {
    let version: Int
    let payload: Payload
}

/// Result of a cache read: the decoded payload plus whether it is within TTL.
/// `isFresh == false` means "render this now, but revalidate from network".
public struct CacheHit<T> {
    public let payload: T
    public let isFresh: Bool
}

extension CacheHit: Sendable where T: Sendable {}

/// Generic on-disk JSON cache, one instance per subdirectory under `Caches/`.
///
/// `actor` so all file I/O runs off the main actor — `@MainActor` and other
/// `actor` callers simply `await` into it. Reads never throw: any failure
/// (absent, corrupt, version mismatch) is reported as a miss (`nil`) so the
/// caller falls back to the network. Writes are best-effort and atomic.
public actor JSONDiskCache {
    private let directory: URL
    private let fileManager: FileManager

    /// - Parameters:
    ///   - subdirectory: path appended to the base (e.g. `CacheSubdirectory.emoteGlobals`).
    ///   - baseDirectory: defaults to the user's Caches directory; inject a temp dir in tests.
    public init(subdirectory: String, baseDirectory: URL? = nil) {
        let base = baseDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        self.fileManager = .default
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    /// Returns a hit (payload + freshness) or `nil` on any miss.
    public func load<T: Codable & Sendable>(
        key: String, as type: T.Type, version: Int, ttl: TimeInterval
    ) -> CacheHit<T>? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(CacheEnvelope<T>.self, from: data),
              envelope.version == version else {
            return nil
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let age = values?.contentModificationDate
            .map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        return CacheHit(payload: envelope.payload, isFresh: age < ttl)
    }

    /// Best-effort atomic write. Failures are logged and swallowed.
    public func save<T: Codable & Sendable>(key: String, value: T, version: Int) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(CacheEnvelope(version: version, payload: value))
            try data.write(to: fileURL(for: key), options: .atomic)
        } catch {
            logger.debug("JSONDiskCache save failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes files in this subdirectory whose modification date is older than `maxAge`.
    public func sweep(maxAge: TimeInterval) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for url in urls {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if now.timeIntervalSince(mtime) > maxAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/Core --filter JSONDiskCache`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Core/Sources/Core/JSONDiskCache.swift \
        Packages/Core/Tests/CoreTests/JSONDiskCacheTests.swift
git commit -m "Core: add JSONDiskCache actor (versioned, TTL, sweep)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Per-channel cache payload + round-trip test

**Files:**
- Create: `Packages/EmoteSources/Sources/EmoteSources/ChannelEmoteCachePayload.swift`
- Test: `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteCodableTests.swift` (append)

- [ ] **Step 1: Write the failing test (append to existing file)**

Append this suite to `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteCodableTests.swift`:

```swift
@Suite("ChannelEmoteCachePayload")
struct ChannelEmoteCachePayloadTests {
    @Test("payload round-trips with a populated byName map")
    func roundTrips() throws {
        let emote = Emote(
            id: "ffz:1", name: "ZULUL",
            urls: [.x1: URL(string: "https://ffz/1")!],
            isAnimated: false, isZeroWidth: false, source: .ffz, ownerChannelId: "99"
        )
        let payload = ChannelEmoteCachePayload(broadcasterId: "99", byName: ["ZULUL": emote])

        let decoded = try JSONDecoder().decode(
            ChannelEmoteCachePayload.self,
            from: try JSONEncoder().encode(payload))

        #expect(decoded.broadcasterId == "99")
        #expect(decoded.byName["ZULUL"] == emote)
        #expect(ChannelEmoteCachePayload.cacheVersion == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/EmoteSources --filter ChannelEmoteCachePayload`
Expected: FAIL — `ChannelEmoteCachePayload` is not defined.

- [ ] **Step 3: Create the payload type**

Create `Packages/EmoteSources/Sources/EmoteSources/ChannelEmoteCachePayload.swift`:

```swift
import Foundation

/// On-disk representation of a channel's merged third-party emote set.
///
/// We persist the *post-merge* snapshot (`EmoteIndex.byName`) directly, so a
/// disk restore needs no re-merge — `Emote` already carries `source` and
/// `ownerChannelId` if a future re-merge ever wants them.
struct ChannelEmoteCachePayload: Codable, Sendable {
    /// Envelope version — bump when `Emote`'s shape changes incompatibly.
    static let cacheVersion = 1

    /// The broadcaster this snapshot belongs to; validated against the cache
    /// filename on load to guard against a mismatched/renamed file.
    let broadcasterId: String

    /// Resolved emotes keyed by display name (the merged `EmoteIndex` map).
    let byName: [String: Emote]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/EmoteSources --filter ChannelEmoteCachePayload`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Packages/EmoteSources/Sources/EmoteSources/ChannelEmoteCachePayload.swift \
        Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteCodableTests.swift
git commit -m "EmoteSources: add ChannelEmoteCachePayload

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Wire disk cache into `EmoteIndex`

**Files:**
- Modify: `Packages/EmoteSources/Sources/EmoteSources/EmoteIndex.swift`
- Test: `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteIndexCacheTests.swift` (create)

- [ ] **Step 1: Write the failing behavioral tests**

Create `Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteIndexCacheTests.swift`:

```swift
import Foundation
import os
import Testing
import Core
@testable import EmoteSources

/// Fake provider that counts how many times its global fetch ran, so tests
/// can assert whether the network path was taken.
final class CountingProvider: EmoteProvider, @unchecked Sendable {
    let globalCalls = OSAllocatedUnfairLock(initialState: 0)
    private let emotes: [Emote]

    init(returning emotes: [Emote]) { self.emotes = emotes }

    func globalEmotes() async throws -> [Emote] {
        globalCalls.withLock { $0 += 1 }
        return emotes
    }
    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        []
    }
    var globalCallCount: Int { globalCalls.withLock { $0 } }
}

@Suite("EmoteIndex disk cache")
struct EmoteIndexCacheTests {

    private func tempBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("emoteindex-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleEmote(_ name: String) -> Emote {
        Emote(id: "7tv:\(name)", name: name,
              urls: [.x1: URL(string: "https://cdn/\(name)")!],
              isAnimated: false, isZeroWidth: false, source: .sevenTV, ownerChannelId: nil)
    }

    @Test("fresh disk hit renders without calling providers")
    func freshHitSkipsNetwork() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        // Seed a fresh cache entry for channel "555".
        await cache.save(
            key: "555",
            value: ChannelEmoteCachePayload(broadcasterId: "555", byName: ["Kappa": sampleEmote("Kappa")]),
            version: ChannelEmoteCachePayload.cacheVersion)

        let provider = CountingProvider(returning: [sampleEmote("OTHER")])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "555", broadcasterLogin: "x")

        #expect(provider.globalCallCount == 0)                 // network skipped
        #expect(index.snapshot()["Kappa"] != nil)              // disk data rendered
    }

    @Test("stale disk hit triggers network and overwrites cache")
    func staleHitRefetches() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        await cache.save(
            key: "777",
            value: ChannelEmoteCachePayload(broadcasterId: "777", byName: ["OldEmote": sampleEmote("OldEmote")]),
            version: ChannelEmoteCachePayload.cacheVersion)

        // Backdate the file to 2 days ago so it is past the 24h TTL.
        let url = base.appendingPathComponent("ch", isDirectory: true)
            .appendingPathComponent("777.json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 24 * 3600)],
            ofItemAtPath: url.path)

        let provider = CountingProvider(returning: [sampleEmote("FreshEmote")])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "777", broadcasterLogin: "x")

        #expect(provider.globalCallCount == 1)                 // network ran
        #expect(index.snapshot()["FreshEmote"] != nil)         // fresh data published
        // Cache overwritten with fresh data (and now fresh again).
        let hit = await cache.load(key: "777", as: ChannelEmoteCachePayload.self,
                                   version: ChannelEmoteCachePayload.cacheVersion, ttl: 24 * 3600)
        #expect(hit?.isFresh == true)
        #expect(hit?.payload.byName["FreshEmote"] != nil)
    }

    @Test("no cache + providers return nothing leaves snapshot empty and does not write")
    func emptyResultNoWrite() async throws {
        let base = tempBase()
        let cache = JSONDiskCache(subdirectory: "ch", baseDirectory: base)
        let provider = CountingProvider(returning: [])
        let index = EmoteIndex(providers: [provider], cache: cache)

        await index.load(broadcasterId: "888", broadcasterLogin: "x")

        #expect(index.snapshot().isEmpty)
        #expect(await cache.load(key: "888", as: ChannelEmoteCachePayload.self,
                                 version: ChannelEmoteCachePayload.cacheVersion, ttl: 24 * 3600) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/EmoteSources --filter "EmoteIndex disk cache"`
Expected: FAIL — `EmoteIndex` has no `init(providers:cache:)`.

- [ ] **Step 3: Add the cache property, TTL constant, and inits**

In `Packages/EmoteSources/Sources/EmoteSources/EmoteIndex.swift`:

(a) Add a stored property + TTL constant just after the `providers` property (currently line 52, `private let providers: [any EmoteProvider]`). Insert below it:

```swift
    /// Disk cache for this channel's merged snapshot. Keyed by broadcasterId.
    private let cache: JSONDiskCache

    /// Cross-launch freshness window. In-session refetch is already prevented
    /// by `loadedBroadcasterId`; this TTL governs only disk-restored data.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60
```

(b) Replace the two initializers (currently lines 76–83):

```swift
    public init() {
        self.providers = [SevenTVProvider(), BTTVProvider(), FFZProvider()]
    }

    /// Inject-providers initializer for tests.
    public init(providers: [any EmoteProvider]) {
        self.providers = providers
    }
```

with:

```swift
    public init(cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)) {
        self.providers = [SevenTVProvider(), BTTVProvider(), FFZProvider()]
        self.cache = cache
    }

    /// Inject-providers (and cache) initializer for tests.
    public init(
        providers: [any EmoteProvider],
        cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)
    ) {
        self.providers = providers
        self.cache = cache
    }
```

- [ ] **Step 4: Add the disk-read fast path at the top of `load(...)`**

In `load(broadcasterId:broadcasterLogin:)`, immediately after the existing idempotency guard block (the `if loadedBroadcasterId == broadcasterId { return }` that ends at line 102) and before `var merged: [String: Emote] = [:]`, insert:

```swift
        // Disk: restore + render instantly if present. If still fresh, skip the
        // network entirely. If stale, fall through and revalidate below.
        if let hit = await cache.load(
            key: broadcasterId, as: ChannelEmoteCachePayload.self,
            version: ChannelEmoteCachePayload.cacheVersion, ttl: Self.cacheTTL
        ), hit.payload.broadcasterId == broadcasterId {
            let restored = hit.payload.byName
            self.byName = restored
            snapshotLock.withLock { $0 = restored }
            if hit.isFresh {
                loadedBroadcasterId = broadcasterId
                logger.info("EmoteIndex restored fresh from disk for \(broadcasterLogin): \(restored.count) emote(s)")
                return
            }
        }
```

- [ ] **Step 5: Guard the publish on non-empty + write the cache**

Currently (lines 165–180) the method publishes `merged` unconditionally and sets `loadedBroadcasterId`. Replace the block that begins at `let finalSnapshot = merged` (line 172) through the final `logger.info(...)` (line 180) with:

```swift
        let finalSnapshot = merged
        // All providers failed or returned nothing. Don't clobber a
        // disk-restored snapshot (or a prior load) with emptiness, and don't
        // mark loaded — let the next mount retry.
        guard !finalSnapshot.isEmpty else {
            logger.info("EmoteIndex produced no emotes for \(broadcasterLogin); keeping existing snapshot")
            return
        }
        self.byName = finalSnapshot
        snapshotLock.withLock { $0 = finalSnapshot }

        await cache.save(
            key: broadcasterId,
            value: ChannelEmoteCachePayload(broadcasterId: broadcasterId, byName: finalSnapshot),
            version: ChannelEmoteCachePayload.cacheVersion)

        loadedBroadcasterId = broadcasterId
        logger.info("EmoteIndex loaded for \(broadcasterLogin): \(finalSnapshot.count) emote(s)")
```

> This changes one pre-existing behaviour: an all-empty load no longer publishes empty or sets `loadedBroadcasterId`, so it retries on next mount instead of caching emptiness. There are no existing tests on this path; the new `emptyResultNoWrite` test pins the new behaviour.

- [ ] **Step 6: Run the full EmoteSources test suite**

Run: `swift test --package-path Packages/EmoteSources`
Expected: PASS — all suites (Emote Codable, ChannelEmoteCachePayload, EmoteIndex disk cache, existing placeholder).

- [ ] **Step 7: Commit**

```bash
git add Packages/EmoteSources/Sources/EmoteSources/EmoteIndex.swift \
        Packages/EmoteSources/Tests/EmoteSourcesTests/EmoteIndexCacheTests.swift
git commit -m "EmoteSources: stale-while-revalidate disk cache in EmoteIndex

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Globals cache payload (Channels package)

**Files:**
- Create: `Packages/Channels/Sources/Channels/GlobalsCachePayload.swift`
- Test: `Packages/Channels/Tests/ChannelsTests/GlobalsCachePayloadTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Channels/Tests/ChannelsTests/GlobalsCachePayloadTests.swift`:

```swift
import Foundation
import Testing
import TwitchKit
@testable import Channels

@Suite("GlobalsCachePayload")
struct GlobalsCachePayloadTests {
    @Test("badge dictionary survives the DTO round-trip")
    func badgeDictRoundTrips() throws {
        let badges: [ChatBadgeKey: ChatBadgeEntry] = [
            ChatBadgeKey(setId: "moderator", id: "1"):
                ChatBadgeEntry(url: URL(string: "https://badge/mod")!, title: "Moderator"),
            ChatBadgeKey(setId: "subscriber", id: "0"):
                ChatBadgeEntry(url: URL(string: "https://badge/sub")!, title: nil),
        ]
        let payload = GlobalsCachePayload(badges: badges, emotes: [:])

        let decoded = try JSONDecoder().decode(
            GlobalsCachePayload.self, from: try JSONEncoder().encode(payload))

        #expect(decoded.badgeDictionary == badges)
        #expect(GlobalsCachePayload.cacheVersion == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/Channels --filter GlobalsCachePayload`
Expected: FAIL — `GlobalsCachePayload` is not defined.

> If `ChatBadgeEntry` does not yet conform to `Equatable`, this test's `==` on the dictionary will fail to compile. It already conforms (`public struct ChatBadgeEntry: Sendable, Equatable` in `ChatBadgeStore.swift`), so no change is needed — but if a compile error mentions `Equatable`, add `Equatable` to `ChatBadgeKey` (which is already `Hashable`, hence `Equatable`).

- [ ] **Step 3: Create the payload type**

Create `Packages/Channels/Sources/Channels/GlobalsCachePayload.swift`:

```swift
import Foundation
import TwitchKit

/// Disk-storable form of a single global badge entry. `[ChatBadgeKey: ChatBadgeEntry]`
/// can't JSON-encode a struct key, so we flatten to an array and rebuild on load.
struct BadgeDTO: Codable, Sendable {
    let setId: String
    let id: String
    let url: URL
    let title: String?
}

/// On-disk representation of `GlobalCatalog`'s global badges + global emotes.
struct GlobalsCachePayload: Codable, Sendable {
    /// Envelope version — bump when the badge/emote shape changes incompatibly.
    static let cacheVersion = 1

    let badges: [BadgeDTO]
    let emotes: [String: TwitchEmote]

    /// Build from the in-memory shapes `GlobalCatalog` holds.
    init(badges: [ChatBadgeKey: ChatBadgeEntry], emotes: [String: TwitchEmote]) {
        self.badges = badges.map {
            BadgeDTO(setId: $0.key.setId, id: $0.key.id, url: $0.value.url, title: $0.value.title)
        }
        self.emotes = emotes
    }

    /// Rebuild the keyed dictionary `GlobalCatalog` renders from.
    var badgeDictionary: [ChatBadgeKey: ChatBadgeEntry] {
        var result: [ChatBadgeKey: ChatBadgeEntry] = [:]
        for dto in badges {
            result[ChatBadgeKey(setId: dto.setId, id: dto.id)] =
                ChatBadgeEntry(url: dto.url, title: dto.title)
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/Channels --filter GlobalsCachePayload`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Packages/Channels/Sources/Channels/GlobalsCachePayload.swift \
        Packages/Channels/Tests/ChannelsTests/GlobalsCachePayloadTests.swift
git commit -m "Channels: add GlobalsCachePayload (badge DTO + emote map)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Wire disk cache into `GlobalCatalog`

**Files:**
- Modify: `Packages/Features/Sources/Features/Emotes/GlobalCatalog.swift`

> No automated test here: `GlobalCatalog.load` depends on a live `TwitchClient` with no injection seam, and Features is not reliably macOS-testable. The cache mechanics are already covered by Task 2 (JSONDiskCache) and Task 5 (payload round-trip); this task mirrors the verified EmoteIndex wiring. Manual verification is in Task 8.

- [ ] **Step 1: Add cache property, TTL, key, and injectable init**

In `GlobalCatalog.swift`, after the `hasLoaded` property (line 39) and before `public init() {}` (line 41), add:

```swift
    /// Disk cache for the single global metadata blob.
    private let cache: JSONDiskCache

    private static let cacheKey = "global"
    private static let cacheTTL: TimeInterval = 24 * 60 * 60
```

Then replace `public init() {}` (line 41) with:

```swift
    public init(cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteGlobals)) {
        self.cache = cache
    }
```

- [ ] **Step 2: Add disk read + write to `load(...)`**

Replace the body of `load(account:accountStore:)` (currently lines 49–64, from `guard !hasLoaded else { return }` through the closing `logger.info(...)`) with:

```swift
        guard !hasLoaded else { return }

        // Disk: render instantly if present. If fresh, skip the network.
        if let hit = await cache.load(
            key: Self.cacheKey, as: GlobalsCachePayload.self,
            version: GlobalsCachePayload.cacheVersion, ttl: Self.cacheTTL
        ) {
            globalBadges = hit.payload.badgeDictionary
            globalEmotes = hit.payload.emotes
            if hit.isFresh {
                hasLoaded = true
                logger.info("GlobalCatalog restored fresh from disk: \(self.globalBadges.count) badges, \(self.globalEmotes.count) emotes")
                return
            }
        }

        let client = accountStore.client(for: account)

        // Sequential is fine — Account is non-Sendable so async let trips
        // Swift 6's sending check, and the total cost is sub-second on a
        // background load that doesn't block first paint.
        let badges = await fetchBadges(client: client, accountStore: accountStore, account: account)
        let emotes = await fetchEmotes(client: client, accountStore: accountStore, account: account)

        // Both fetches failed (network down / unauthorized). Keep whatever we
        // restored from disk rather than overwriting memory + cache with empties.
        guard !badges.isEmpty || !emotes.isEmpty else {
            hasLoaded = true
            logger.info("GlobalCatalog fetch returned nothing; keeping disk/empty state")
            return
        }

        globalBadges = badges
        globalEmotes = emotes
        hasLoaded = true

        await cache.save(
            key: Self.cacheKey,
            value: GlobalsCachePayload(badges: badges, emotes: emotes),
            version: GlobalsCachePayload.cacheVersion)

        logger.info("GlobalCatalog loaded: \(badges.count) badges, \(emotes.count) emotes")
```

- [ ] **Step 3: Build the package to verify it compiles**

Run: `xcodebuild -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

> If the scheme/simulator name differs, list schemes with `xcodebuild -list -project chattr.xcodeproj` and available simulators with `xcrun simctl list devices available`, then substitute.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/Emotes/GlobalCatalog.swift
git commit -m "Features: stale-while-revalidate disk cache in GlobalCatalog

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Launch-time age sweep

**Files:**
- Modify: `Packages/Features/Sources/Features/App/RootView.swift`

- [ ] **Step 1: Confirm `Core` is imported**

Run: `grep -n "^import" Packages/Features/Sources/Features/App/RootView.swift`
If `import Core` is absent, add it alongside the other imports at the top of the file. (Most Features files import Core; verify before editing.)

- [ ] **Step 2: Add a one-time sweep task**

In `RootView`, find the first `.task(id: activeAccount?.userId)` modifier (begins at line 125). Immediately *before* it, add a non-keyed `.task` that runs once per view lifetime:

```swift
        // Bound the per-channel emote cache: delete files not refreshed in 7
        // days. Runs once at launch (not keyed to account). The 24h TTL governs
        // freshness; this governs lifetime. OS purge of Caches/ is a backstop.
        .task {
            await JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)
                .sweep(maxAge: 7 * 24 * 60 * 60)
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/App/RootView.swift
git commit -m "Features: sweep stale per-channel emote cache at launch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Full verification

- [ ] **Step 1: Run all affected package test suites**

```bash
swift test --package-path Packages/Core
swift test --package-path Packages/EmoteSources
swift test --package-path Packages/Channels
```
Expected: all PASS.

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual smoke test (the GlobalCatalog path that has no unit test)**

Use the `/run` or `axiom:simulator-tester` flow, or run manually:
1. Launch the app signed in; open a channel with third-party emotes (e.g. a large 7TV channel). Confirm emotes render.
2. Force-quit and relaunch. Reopen the *same* channel.
3. Expected: emotes appear immediately on open (restored from disk), with no visible blank/pop-in. Within 24h, the provider HTTP calls are skipped (check logs: "EmoteIndex restored fresh from disk" / "GlobalCatalog restored fresh from disk").
4. Confirm cache files exist:
   ```bash
   xcrun simctl get_app_container booted <app-bundle-id> data
   # then inspect <container>/Library/Caches/emote-cache/ and .../emote-cache/channels/
   ```

- [ ] **Step 4: Final commit (if any manual-test fixups were needed)**

Only if changes were made:
```bash
git add -A && git commit -m "Emote cache: verification fixups

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Globals persistence → Tasks 5, 6 ✓
- Per-channel emote persistence → Tasks 3, 4 ✓
- `JSONDiskCache` actor in Core (load/save/sweep, envelope, CacheHit) → Task 2 ✓
- Caches/ location + envelope versioning → Task 2 ✓
- 24h TTL stale-while-revalidate → Tasks 4, 6 ✓
- 7-day age sweep on launch → Tasks 2 (sweep impl), 7 (call) ✓
- Codable on Emote → Task 1 ✓
- BadgeDTO → Task 5 ✓
- Error handling (reads never throw; best-effort writes; atomic) → Task 2 ✓
- Testing (cache unit tests, Codable round-trip, behavioral) → Tasks 1, 2, 3, 4, 5 ✓; GlobalCatalog behavioral intentionally manual (Task 6 note, Task 8) — documented limitation, not a gap.
- Compression off → not implemented (correct per spec non-goal) ✓
- Per-channel badge persistence → out of scope per spec (not in plan) ✓

**Type consistency:** `JSONDiskCache.load(key:as:version:ttl:)` / `save(key:value:version:)` / `sweep(maxAge:)`, `CacheHit { payload, isFresh }`, `CacheSubdirectory.emoteGlobals`/`.emoteChannels`, `GlobalsCachePayload(badges:emotes:)` + `.badgeDictionary` + `.cacheVersion`, `ChannelEmoteCachePayload(broadcasterId:byName:)` + `.cacheVersion` — all used consistently across tasks.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows complete code; every command shows expected output.
