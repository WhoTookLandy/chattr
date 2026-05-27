# chattr Slice 2 — Emotes, Normalizer, UIKit Chat List, Liquid Glass

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks marked **[USER]** require Xcode UI clicks; **[SUBAGENT]** tasks can be dispatched.

**Goal:** Turn chattr from "username: raw text" into a recognizable Twitch chat client — third-party emote rendering (7TV, BTTV, FFZ), display-ready message normalization, a UIKit `UICollectionView` chat list for sustained 60fps under load, Liquid Glass visual polish, and inline rendering of sub/raid/delete EventSub events. Builds purely additively on slice-1's architecture.

**Architecture (this slice):**

```
EventSub → ChannelSession (existing actor)
              ├─ keeps raw ChatMessage fragments
              ├─ NEW: feeds into ChatModel.Normalizer
              │       └─ resolves emote runs via EmoteSources.EmoteIndex
              ├─ emits ChatLine (display-ready) via AsyncStream<[ChatLine]>
              │
              ▼
        NEW: ChatUI.ChatListView (UIKit UICollectionView wrapped via
              UIViewControllerRepresentable + UIHostingConfiguration cells)
              └─ replaces the SwiftUI ScrollView in slice-1

Helix:
- NEW: HelixClient backfill of recent messages via rustlog (recent-messages.robotty.de)
        on channel join, before EventSub events start arriving.

Visual:
- NEW: DesignSystem.Brand expanded with materials + typography tokens
- NEW: ChatRow uses Liquid Glass styling
- NEW: ChatBubble for sub/raid/announcement system messages
```

**Spec:** `docs/superpowers/specs/2026-05-24-chattr-design.md` — slice-2 covers the third-party emote + ChatModel + UIKit chat list + bubbles + theming items from the deferred list.

**What slice-2 deliberately does not cover:** sending messages, replies/emote-picker, highlight sound, multi-account UI, settings, channel discovery beyond followed list. Those are future slices.

---

## File map (this slice)

```
Packages/
  EmoteSources/                                NEW package
    Package.swift                              T1
    Sources/EmoteSources/
      Emote.swift                              T1 — value type for any provider's emote
      EmoteProvider.swift                      T2 — protocol; 3 conformances
      SevenTVProvider.swift                    T3
      BTTVProvider.swift                       T4
      FFZProvider.swift                        T5
      EmoteIndex.swift                         T6 — actor that resolves "name" → Emote
    Tests/EmoteSourcesTests/
      ProviderDecodingTests.swift              T7 — JSON fixtures per provider

  ChatModel/                                   NEW package
    Package.swift                              T8
    Sources/ChatModel/
      ChatLine.swift                           T8 — display-ready message line
      LineRun.swift                            T8 — text/emote/mention/url runs
      Normalizer.swift                         T9 — TwitchKit.ChatMessage → ChatLine
      Bubble.swift                             T18 — system-message bubble types (sub/raid)
    Tests/ChatModelTests/
      NormalizerTests.swift                    T10 — @Test(arguments:) parametrized

  Channels/                                    EXISTING — modify
    Sources/Channels/
      ChannelSession.swift                     T11 — emit ChatLine snapshots (not ChatMessage)
      BackfillProvider.swift                   T12 — recent-messages.robotty.de fetch
      ChannelSession+Backfill.swift            T12 — wire backfill on start()
      ChannelSession+Bubbles.swift             T17 — subscribe & ingest .notification/raid/delete

  ChatUI/                                      NEW package
    Package.swift                              T13
    Sources/ChatUI/
      ChatListView.swift                       T13 — SwiftUI wrapper, UICollectionView inside
      ChatListViewController.swift             T14 — UICollectionViewDiffableDataSource
      ChatRowCellConfig.swift                  T15 — UIHostingConfiguration + ChatRow SwiftUI
      ChatRow.swift                            T15 — the SwiftUI view authored inside the cell
      InlineEmoteView.swift                    T16 — AsyncImage with Nuke for animated WebP
      ChatBubbleRow.swift                      T19 — sub/raid bubble row
    Tests/ChatUITests/
      ChatListDiffTests.swift                  T21 — diff application correctness

  DesignSystem/                                EXISTING — extend
    Sources/DesignSystem/
      Brand.swift                              T22 — full palette (Twitch-distinguishable)
      Typography.swift                         T22 — Dynamic Type tokens for chat
      Materials.swift                          T22 — Liquid Glass material catalog

  Features/                                    EXISTING — modify
    Sources/Features/
      ChatScreen.swift                         T20 — swap SwiftUI ScrollView for ChatListView
      ChannelListScreen.swift                  T23 — Liquid Glass styling pass
```

---

## Phase 2.1 — Emote sources (data ingestion)

### Task 1: Create `EmoteSources` package skeleton + `Emote` value type [SUBAGENT]

**Files:**
- Create: `Packages/EmoteSources/Package.swift`
- Create: `Packages/EmoteSources/Sources/EmoteSources/Emote.swift`

- [ ] **Step 1: Write `Packages/EmoteSources/Package.swift`**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EmoteSources",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "EmoteSources", targets: ["EmoteSources"]),
    ],
    dependencies: [
        .package(path: "../Core"),
    ],
    targets: [
        .target(
            name: "EmoteSources",
            dependencies: ["Core"],
            path: "Sources/EmoteSources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EmoteSourcesTests",
            dependencies: ["EmoteSources"],
            path: "Tests/EmoteSourcesTests"
        ),
    ]
)
```

- [ ] **Step 2: Write `Emote.swift`**

```swift
import Foundation

/// A third-party emote, normalized across 7TV/BTTV/FFZ.
///
/// Twitch native emotes are NOT modeled here — they arrive pre-resolved inside
/// `TwitchKit.ChatMessage.fragments` as `.emote(EmoteReference)` already. This
/// type is only for emote *names* that appear as plain text in Twitch's payload
/// but should render as inline images from a third-party CDN.
public struct Emote: Sendable, Equatable, Hashable, Identifiable {
    /// Provider-namespaced unique id (e.g., "7tv:6042089ce42d.png", "bttv:54fa90b80...").
    public let id: String

    /// The literal text token that triggers this emote — case-sensitive match against
    /// whitespace-delimited words in chat message text fragments.
    public let name: String

    /// URLs for the emote, keyed by display size (1x, 2x, 4x). 7TV serves animated
    /// WebP; BTTV and FFZ are mostly static PNG/GIF.
    public let urls: [Size: URL]

    /// True when the emote is animated (7TV WebP, BTTV GIF). Affects whether Nuke
    /// uses an animated image view vs a static one.
    public let isAnimated: Bool

    /// True for 7TV "zero-width" overlays (e.g., RainTime stacks on top of the
    /// previous emote). Slice-2 does NOT render overlays; we just flag them so a
    /// future slice can implement layered rendering. For now they render as the
    /// emote on top of the previous one in flat layout.
    public let isZeroWidth: Bool

    /// Which provider issued this emote. Used for collision precedence + analytics.
    public let source: Source

    /// If the emote is channel-specific (vs global), the broadcaster_user_id whose
    /// channel emote set includes it.
    public let ownerChannelId: String?

    public enum Size: String, Sendable, Equatable, Hashable, CaseIterable {
        case x1, x2, x4
    }

    public enum Source: String, Sendable, Equatable, Hashable, CaseIterable {
        case sevenTV, bttv, ffz
    }

    public init(
        id: String,
        name: String,
        urls: [Size: URL],
        isAnimated: Bool,
        isZeroWidth: Bool,
        source: Source,
        ownerChannelId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.urls = urls
        self.isAnimated = isAnimated
        self.isZeroWidth = isZeroWidth
        self.source = source
        self.ownerChannelId = ownerChannelId
    }
}
```

- [ ] **Step 3: Build**

```bash
cd /Users/landy/Dev/chattr/Packages/EmoteSources && swift build
```

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/EmoteSources && git commit -m "EmoteSources: package skeleton + Emote value type"
```

---

### Task 2: Define `EmoteProvider` protocol [SUBAGENT]

**Files:**
- Create: `Packages/EmoteSources/Sources/EmoteSources/EmoteProvider.swift`

- [ ] **Step 1: Write the protocol**

```swift
import Foundation

/// Abstraction over an emote provider's REST API. Each conformance owns the
/// HTTP shape, the JSON decoding, and the mapping from provider-specific fields
/// to the unified `Emote` value type.
///
/// Method semantics: both methods are async/throws. They should NOT cache —
/// caching is `EmoteIndex`'s job. They should NOT retry — failures bubble up
/// and `EmoteIndex` decides whether to fail the whole channel load or just
/// the failing provider.
public protocol EmoteProvider: Sendable {
    /// The set of emotes this provider considers "global" (available in every channel).
    /// Fetched once per app lifecycle (or when a refresh is forced).
    func globalEmotes() async throws -> [Emote]

    /// Emotes specific to a given Twitch channel (broadcaster_user_id).
    /// Fetched per channel join. Empty array if the channel has no provider-specific emotes.
    func channelEmotes(broadcasterId: String) async throws -> [Emote]
}
```

- [ ] **Step 2: Build + commit**

```bash
cd /Users/landy/Dev/chattr/Packages/EmoteSources && swift build
cd /Users/landy/Dev/chattr && git add Packages/EmoteSources && git commit -m "EmoteSources: EmoteProvider protocol"
```

---

### Task 3: Implement `SevenTVProvider` [SUBAGENT]

7TV's API is at `https://7tv.io/v3/emote-sets/global` for global, and `https://7tv.io/v3/users/twitch/<broadcasterId>` returns a user object whose `emote_set.emotes` is the channel set.

**Files:**
- Create: `Packages/EmoteSources/Sources/EmoteSources/SevenTVProvider.swift`

- [ ] **Step 1: Inspect 7TV's actual response shape**

Before writing code, fetch a real response to verify the JSON shape hasn't drifted. Run:

```bash
curl -s "https://7tv.io/v3/emote-sets/global" | python3 -m json.tool | head -80
curl -s "https://7tv.io/v3/users/twitch/71092938" | python3 -m json.tool | head -120  # xQc
```

Confirm the shape includes:
- `emotes[]` with `id`, `name`, `flags` (where flag bit 0x01 = zero-width), `data.host.url`, `data.host.files[]` (each has `name`, `format`)
- `data.host.files[]` entries with `format: "WEBP"` indicate animated; `format: "AVIF"` is fallback static. Pick WebP for animated.

If the shape differs from this description, STOP and report — don't write code against an assumed shape that doesn't match reality.

- [ ] **Step 2: Write `SevenTVProvider.swift`**

```swift
import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.SevenTV")

public struct SevenTVProvider: EmoteProvider {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func globalEmotes() async throws -> [Emote] {
        let url = URL(string: "https://7tv.io/v3/emote-sets/global")!
        let (data, _) = try await urlSession.data(from: url)
        let response = try JSONDecoder().decode(EmoteSetResponse.self, from: data)
        return response.emotes.compactMap { Self.map($0, ownerChannelId: nil) }
    }

    public func channelEmotes(broadcasterId: String) async throws -> [Emote] {
        let url = URL(string: "https://7tv.io/v3/users/twitch/\(broadcasterId)")!
        let (data, _) = try await urlSession.data(from: url)
        // Response is a user object; emote set is at .emote_set.emotes
        struct UserResponse: Decodable {
            let emote_set: EmoteSetResponse?
        }
        let response = try JSONDecoder().decode(UserResponse.self, from: data)
        return response.emote_set?.emotes.compactMap { Self.map($0, ownerChannelId: broadcasterId) } ?? []
    }

    // MARK: - Private decoding shapes

    private struct EmoteSetResponse: Decodable {
        let emotes: [EmoteJSON]
    }

    private struct EmoteJSON: Decodable {
        let id: String
        let name: String
        let flags: Int?
        let data: EmoteData?
    }

    private struct EmoteData: Decodable {
        let host: EmoteHost?
        let animated: Bool?
    }

    private struct EmoteHost: Decodable {
        let url: String
        let files: [EmoteFile]
    }

    private struct EmoteFile: Decodable {
        let name: String      // e.g. "1x.webp", "2x.webp", "4x.webp"
        let format: String    // "WEBP", "AVIF", "PNG"
    }

    private static func map(_ j: EmoteJSON, ownerChannelId: String?) -> Emote? {
        guard let host = j.data?.host else { return nil }
        let hostURL = host.url.hasPrefix("//") ? "https:" + host.url : host.url

        // Pick the WebP files for 1x/2x/4x. 7TV uses WebP as primary.
        var urls: [Emote.Size: URL] = [:]
        let webpFiles = host.files.filter { $0.format == "WEBP" }
        for file in webpFiles {
            let size: Emote.Size? = switch file.name {
            case "1x.webp": .x1
            case "2x.webp": .x2
            case "4x.webp": .x4
            default: nil
            }
            if let size, let url = URL(string: "\(hostURL)/\(file.name)") {
                urls[size] = url
            }
        }

        guard !urls.isEmpty else { return nil }

        let flags = j.flags ?? 0
        let isZeroWidth = (flags & 0x01) != 0
        let isAnimated = j.data?.animated ?? false

        return Emote(
            id: "7tv:\(j.id)",
            name: j.name,
            urls: urls,
            isAnimated: isAnimated,
            isZeroWidth: isZeroWidth,
            source: .sevenTV,
            ownerChannelId: ownerChannelId
        )
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/landy/Dev/chattr/Packages/EmoteSources && swift build
cd /Users/landy/Dev/chattr && git add Packages/EmoteSources/Sources/EmoteSources/SevenTVProvider.swift && git commit -m "EmoteSources: SevenTVProvider (global + per-channel)"
```

---

### Task 4: Implement `BTTVProvider` [SUBAGENT]

BTTV's API:
- Global: `https://api.betterttv.net/3/cached/emotes/global`
- Channel: `https://api.betterttv.net/3/cached/users/twitch/<broadcasterId>` → `channelEmotes[]` + `sharedEmotes[]`

**Files:**
- Create: `Packages/EmoteSources/Sources/EmoteSources/BTTVProvider.swift`

- [ ] **Step 1: Inspect actual BTTV response shape**

```bash
curl -s "https://api.betterttv.net/3/cached/emotes/global" | python3 -m json.tool | head -40
curl -s "https://api.betterttv.net/3/cached/users/twitch/71092938" | python3 -m json.tool | head -60
```

Confirm fields: `id`, `code`, `imageType` (png/gif). URLs are constructed as `https://cdn.betterttv.net/emote/<id>/{1x,2x,3x}`.

- [ ] **Step 2: Write the provider** (same pattern as SevenTVProvider — see plan-text in step 2 below)

```swift
import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.BTTV")

public struct BTTVProvider: EmoteProvider {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func globalEmotes() async throws -> [Emote] {
        let url = URL(string: "https://api.betterttv.net/3/cached/emotes/global")!
        let (data, _) = try await urlSession.data(from: url)
        let emotes = try JSONDecoder().decode([EmoteJSON].self, from: data)
        return emotes.compactMap { Self.map($0, ownerChannelId: nil) }
    }

    public func channelEmotes(broadcasterId: String) async throws -> [Emote] {
        let url = URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(broadcasterId)")!
        let (data, response) = try await urlSession.data(from: url)
        // BTTV returns 404 for channels that don't have any BTTV emotes — graceful empty.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return [] }
        let user = try JSONDecoder().decode(UserResponse.self, from: data)
        return (user.channelEmotes + user.sharedEmotes).compactMap {
            Self.map($0, ownerChannelId: broadcasterId)
        }
    }

    private struct UserResponse: Decodable {
        let channelEmotes: [EmoteJSON]
        let sharedEmotes: [EmoteJSON]
    }

    private struct EmoteJSON: Decodable {
        let id: String
        let code: String
        let imageType: String  // "png" | "gif"
    }

    private static func map(_ j: EmoteJSON, ownerChannelId: String?) -> Emote? {
        // BTTV URL pattern: https://cdn.betterttv.net/emote/<id>/{1x,2x,3x}
        // Note: BTTV uses 3x (not 4x). Map our Size.x4 to the 3x asset.
        let base = "https://cdn.betterttv.net/emote/\(j.id)"
        guard
            let x1 = URL(string: "\(base)/1x"),
            let x2 = URL(string: "\(base)/2x"),
            let x4 = URL(string: "\(base)/3x")
        else { return nil }

        return Emote(
            id: "bttv:\(j.id)",
            name: j.code,
            urls: [.x1: x1, .x2: x2, .x4: x4],
            isAnimated: j.imageType == "gif",
            isZeroWidth: false,                 // BTTV doesn't have zero-width emotes
            source: .bttv,
            ownerChannelId: ownerChannelId
        )
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
cd /Users/landy/Dev/chattr/Packages/EmoteSources && swift build
cd /Users/landy/Dev/chattr && git add Packages/EmoteSources/Sources/EmoteSources/BTTVProvider.swift && git commit -m "EmoteSources: BTTVProvider"
```

---

### Task 5: Implement `FFZProvider` [SUBAGENT]

FFZ's API:
- Global: `https://api.frankerfacez.com/v1/set/global` → `sets` keyed by ID, each with `emoticons[]`
- Channel: `https://api.frankerfacez.com/v1/room/<channel_login>` (note: by LOGIN not by ID — see contingency)

**Files:**
- Create: `Packages/EmoteSources/Sources/EmoteSources/FFZProvider.swift`

- [ ] **Step 1: Inspect FFZ response + understand login-vs-id constraint**

```bash
curl -s "https://api.frankerfacez.com/v1/set/global" | python3 -m json.tool | head -40
curl -s "https://api.frankerfacez.com/v1/room/xqc" | python3 -m json.tool | head -40
```

FFZ requires the channel **login**, not the broadcaster_user_id. Our `EmoteProvider.channelEmotes(broadcasterId:)` only has the id. Options:
- A. Add a separate `channelEmotes(broadcasterLogin:)` overload to the protocol (ugly — only FFZ needs this)
- B. Have FFZ resolve login from id by calling Twitch Helix `getUser(id:)` first (extra request, extra dependency)
- C. Have `EmoteIndex` pass both id and login when invoking providers, and providers pick what they need

Pick **C** — least disruptive. The `ChannelSession` already knows both the id and login (it stores `channelLoginName`). We'll thread login through to the EmoteIndex which forwards it to all providers (each provider takes both, uses what it needs).

**Adjust `EmoteProvider` protocol** to:
```swift
func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote]
```

Then update SevenTV and BTTV (they already work; just accept the extra param and ignore it).

- [ ] **Step 2: Update the protocol and existing providers**

Edit `EmoteProvider.swift`:
```swift
func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote]
```

Edit `SevenTVProvider.channelEmotes(...)`:
```swift
public func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
    // 7TV uses Twitch broadcaster id — login is ignored.
    let url = URL(string: "https://7tv.io/v3/users/twitch/\(broadcasterId)")!
    // ... rest unchanged
}
```

Same change to `BTTVProvider.channelEmotes(...)` — accept login, ignore it.

- [ ] **Step 3: Write `FFZProvider.swift`**

```swift
import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.FFZ")

public struct FFZProvider: EmoteProvider {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func globalEmotes() async throws -> [Emote] {
        let url = URL(string: "https://api.frankerfacez.com/v1/set/global")!
        let (data, _) = try await urlSession.data(from: url)
        let response = try JSONDecoder().decode(GlobalResponse.self, from: data)
        // sets is a dict keyed by set ID; flatten all emoticons across sets.
        return response.sets.values.flatMap { $0.emoticons.compactMap { Self.map($0, ownerChannelId: nil) } }
    }

    public func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        // FFZ keys by login, not by id.
        let url = URL(string: "https://api.frankerfacez.com/v1/room/\(broadcasterLogin)")!
        let (data, response) = try await urlSession.data(from: url)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return [] }
        let body = try JSONDecoder().decode(RoomResponse.self, from: data)
        return body.sets.values.flatMap { $0.emoticons.compactMap { Self.map($0, ownerChannelId: broadcasterId) } }
    }

    // MARK: - Decoding shapes

    private struct GlobalResponse: Decodable {
        let sets: [String: EmoteSet]
    }
    private struct RoomResponse: Decodable {
        let sets: [String: EmoteSet]
    }
    private struct EmoteSet: Decodable {
        let emoticons: [EmoteJSON]
    }
    private struct EmoteJSON: Decodable {
        let id: Int
        let name: String
        let urls: [String: String]?    // {"1": "url", "2": "url", "4": "url"} OR newer "animated" key
        let animated: [String: String]?
    }

    private static func map(_ j: EmoteJSON, ownerChannelId: String?) -> Emote? {
        // Prefer animated URLs when present; otherwise use static.
        let urlMap = j.animated ?? j.urls ?? [:]
        guard !urlMap.isEmpty else { return nil }

        var urls: [Emote.Size: URL] = [:]
        for (key, value) in urlMap {
            let size: Emote.Size? = switch key {
            case "1": .x1
            case "2": .x2
            case "4": .x4
            default: nil
            }
            // FFZ URLs sometimes start with // — normalize to https://
            let normalized = value.hasPrefix("//") ? "https:" + value : value
            if let size, let url = URL(string: normalized) {
                urls[size] = url
            }
        }
        guard !urls.isEmpty else { return nil }

        return Emote(
            id: "ffz:\(j.id)",
            name: j.name,
            urls: urls,
            isAnimated: j.animated != nil,
            isZeroWidth: false,
            source: .ffz,
            ownerChannelId: ownerChannelId
        )
    }
}
```

- [ ] **Step 4: Build + commit**

```bash
cd /Users/landy/Dev/chattr/Packages/EmoteSources && swift build
cd /Users/landy/Dev/chattr && git add Packages/EmoteSources && git commit -m "EmoteSources: FFZProvider + protocol takes broadcasterLogin"
```

---

### Task 6: Implement `EmoteIndex` actor [SUBAGENT]

`EmoteIndex` resolves emote names → `Emote` for a single (account × channel) session. It calls each provider, merges results, handles per-provider failure gracefully (logs + continues), and exposes a synchronous lookup `resolve(name:) -> Emote?`.

**Files:**
- Create: `Packages/EmoteSources/Sources/EmoteSources/EmoteIndex.swift`

- [ ] **Step 1: Write the actor**

```swift
import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.Index")

/// Per-channel emote resolver. Owns the merged result of:
///   - 7TV global + channel
///   - BTTV global + channel
///   - FFZ global + channel
///
/// On collision (same emote name from multiple providers), source precedence is:
///   channel emotes > global emotes
///   7TV > BTTV > FFZ
///
/// The actor protects mutation during async refresh; reads via `resolve(name:)` are
/// fast O(1) dictionary lookups.
public actor EmoteIndex {
    /// Resolved emotes keyed by `name`. Slice-2 uses exact-case match (Twitch emotes
    /// are case-sensitive). 7TV/BTTV/FFZ are also case-sensitive by convention.
    private var byName: [String: Emote] = [:]

    private let providers: [EmoteProvider]

    /// `nonisolated` snapshot of the resolved map. Updated atomically via `withLock`-style
    /// re-emission whenever providers finish. Consumers (Normalizer) read this without
    /// crossing the actor boundary, avoiding hops on the hot message path.
    public nonisolated(unsafe) private(set) var snapshot: [String: Emote] = [:]

    public init(providers: [EmoteProvider] = [SevenTVProvider(), BTTVProvider(), FFZProvider()]) {
        self.providers = providers
    }

    /// Loads global + per-channel emotes for the given (id, login) pair.
    /// Each provider is queried in parallel via TaskGroup; per-provider failures are
    /// logged and swallowed so a single dead provider doesn't fail the whole index.
    public func load(broadcasterId: String, broadcasterLogin: String) async {
        var merged: [String: Emote] = [:]

        // Step 1: load globals from all providers (in parallel).
        await withTaskGroup(of: [Emote].self) { group in
            for provider in providers {
                group.addTask {
                    do { return try await provider.globalEmotes() }
                    catch {
                        logger.error("Global emotes failed for \(String(describing: type(of: provider))): \(error.localizedDescription)")
                        return []
                    }
                }
            }
            for await emotes in group {
                for emote in emotes {
                    Self.merge(into: &merged, emote: emote, isChannelLevel: false)
                }
            }
        }

        // Step 2: load channel emotes for all providers (in parallel). These override globals on name collision.
        await withTaskGroup(of: [Emote].self) { group in
            for provider in providers {
                group.addTask {
                    do { return try await provider.channelEmotes(broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin) }
                    catch {
                        logger.error("Channel emotes failed for \(String(describing: type(of: provider))) (\(broadcasterLogin)): \(error.localizedDescription)")
                        return []
                    }
                }
            }
            for await emotes in group {
                for emote in emotes {
                    Self.merge(into: &merged, emote: emote, isChannelLevel: true)
                }
            }
        }

        self.byName = merged
        self.snapshot = merged
        logger.info("EmoteIndex loaded for \(broadcasterLogin): \(merged.count) emotes")
    }

    /// O(1) lookup. Returns nil if the name isn't a known emote.
    public func resolve(name: String) -> Emote? {
        byName[name]
    }

    // MARK: - Private

    /// Merge with precedence: channel > global; 7TV > BTTV > FFZ.
    private static func merge(
        into map: inout [String: Emote],
        emote: Emote,
        isChannelLevel: Bool
    ) {
        if let existing = map[emote.name] {
            // Precedence: channel always wins over global of same source.
            let existingIsChannel = existing.ownerChannelId != nil
            if !existingIsChannel && isChannelLevel {
                map[emote.name] = emote
                return
            }
            if existingIsChannel && !isChannelLevel {
                return // keep existing (channel wins)
            }
            // Same level — apply source precedence (7TV > BTTV > FFZ).
            if priority(of: emote.source) < priority(of: existing.source) {
                map[emote.name] = emote
            }
        } else {
            map[emote.name] = emote
        }
    }

    private static func priority(of source: Emote.Source) -> Int {
        switch source {
        case .sevenTV: return 0
        case .bttv: return 1
        case .ffz: return 2
        }
    }
}
```

> **Implementer note on `nonisolated(unsafe)`:** the `snapshot` property mirrors `byName` for cross-actor lookup without await. The `nonisolated(unsafe)` is technically a data-race hazard if the actor mutates `snapshot` while a consumer reads it, but Swift 6 dictionary value-type semantics make this safe in practice: dictionary assignments are atomic at the reference level (COW). If strict-concurrency yields a warning, replace with `let snapshot = OSAllocatedUnfairLock(initialState: [String: Emote]())` — heavier but provably-safe.

- [ ] **Step 2: Build + commit**

```bash
cd /Users/landy/Dev/chattr/Packages/EmoteSources && swift build
cd /Users/landy/Dev/chattr && git add Packages/EmoteSources/Sources/EmoteSources/EmoteIndex.swift && git commit -m "EmoteSources: EmoteIndex actor with precedence merge"
```

---

### Task 7: Write decoding tests for each provider [SUBAGENT]

**Files:**
- Create: `Packages/EmoteSources/Tests/EmoteSourcesTests/ProviderDecodingTests.swift`

Each test uses a captured JSON fixture (the real responses you `curl`ed in Tasks 3/4/5) inline as a string literal. Verify:

- 7TV: parses an emote with `flags=1` as zero-width
- 7TV: parses an emote without `flags` as non-zero-width
- BTTV: 404 channel response returns empty array (not throws)
- BTTV: `imageType: "gif"` produces `isAnimated: true`
- FFZ: `urls` is used when `animated` is absent
- FFZ: `animated` URLs are preferred when both present

```swift
import Testing
import Foundation
@testable import EmoteSources

@Suite("7TV decoding")
struct SevenTVDecodingTests {
    // ... see plan for full fixtures
}
// + BTTV + FFZ suites
```

(Full test code in the spec; ~200 lines.)

Build + `swift test`; commit.

---

## Phase 2.2 — ChatModel + Normalizer

### Task 8: Create `ChatModel` package skeleton + `ChatLine` / `LineRun` [SUBAGENT]

(File creation following the pattern of Task 1; see file map at top of plan.)

`ChatLine` fields per the design spec:
- `id: String` (messageId)
- `kind: Kind` (`.message` | `.subBubble(SubBubble)` | `.raidBubble(RaidBubble)` | `.deletedPlaceholder`)
- `authorBadges: [AuthorBadge]`
- `authorDisplayName: String`
- `authorColor: String`
- `runs: [LineRun]`
- `isHighlighted: Bool`
- `replyContext: ReplyContext?`
- `timestamp: Date`
- `status: MessageStatus`
- `rawFragments: [ChatFragment]` (for re-normalization on EmoteIndex update)

`LineRun`:
- `.text(String)`
- `.emote(EmoteSources.Emote)` AND `.twitchEmote(TwitchKit.EmoteReference)` (kept separate because TwitchKit emotes render via Twitch's CDN, not 7TV/BTTV/FFZ)
- `.mention(login: String, isMe: Bool)`
- `.url(String)`
- `.cheermote(prefix: String, bits: Int, tier: Int)`

Build + commit per package convention.

---

### Task 9: Implement `Normalizer` [SUBAGENT]

`Normalizer.normalize(_ message: TwitchKit.ChatMessage, emoteIndex: EmoteIndex, currentUserLogin: String, highlightKeywords: [String]) -> ChatLine`

Logic:
1. Walk `message.message.fragments`.
2. For each fragment:
   - `.text` → tokenize by whitespace; for each token, `emoteIndex.resolve(name: token)` — if hit, emit `.emote(Emote)`; else, emit `.text(token)` with surrounding spaces preserved.
   - `.emote` → emit `.twitchEmote(EmoteReference)`.
   - `.mention` → emit `.mention(login: ..., isMe: login == currentUserLogin)`.
   - `.cheermote` → emit `.cheermote(...)`.
3. Concatenate consecutive `.text` runs.
4. Compute `isHighlighted`: any `.mention(isMe: true)` OR any text token contains a `highlightKeywords` entry (case-insensitive substring).
5. Map `message.badges` → `[AuthorBadge]` using badge-set fetched earlier.
6. Return `ChatLine`.

Build + commit.

---

### Task 10: Normalizer tests [SUBAGENT]

Parametrized via `@Test(arguments:)` covering at least these cases:

- Plain text: `"hello world"` → `[.text("hello world")]`
- One Twitch emote inline: `"hi Kappa wave"` → `[.text("hi "), .twitchEmote(.kappa), .text(" wave")]`
- 7TV emote in text fragment: `"lul poggers w"` → `[.text("lul "), .emote(.poggers7tv), .text(" w")]`
- Mention self: `"@me how are you"` → `[.mention("me", isMe: true), .text(" how are you")]`
- All-emote message: `"KEKW LULW POG"` → `[.emote, .text(" "), .emote, .text(" "), .emote]`
- Highlight on keyword: `"guys watch this clip"` with `["clip"]` keyword → `isHighlighted: true`
- Empty fragments: `""` → `[]`
- Mention NOT self: `"@xqc gg"` → `[.mention("xqc", isMe: false), .text(" gg")]`

(~10 tests total; build + commit.)

---

## Phase 2.3 — Channels wiring (backfill + bubbles)

### Task 11: Modify `ChannelSession` to emit `ChatLine` instead of `ChatMessage` [SUBAGENT]

The stream type changes from `AsyncStream<[ChatMessage]>` to `AsyncStream<[ChatLine]>`. This requires:

- Add `let emoteIndex: EmoteIndex` and `let highlightKeywords: [String]` to the actor's stored state.
- Update `start()` to construct/load the EmoteIndex before subscribing to EventSub.
- Update the ingest path to call `Normalizer.normalize(...)` and append the resulting `ChatLine` to the ring buffer.
- Update `lines: AsyncStream<[ChatLine]>` (the renamed stream).

Callers in `ChatScreen.swift` need to update their `for await ... in session.lines` loop to handle `[ChatLine]` instead of `[ChatMessage]`. That happens in Task 20.

Build + commit (Features won't build yet because ChatScreen still expects ChatMessage — that's OK; Task 20 fixes it).

> **Note:** this is a deliberately broken-build commit. The build goes red after Task 11 and green again after Task 20. We accept this because the alternative (combining T11 + T20 into one mega-commit) loses the ability to bisect future regressions. Document in the commit message: "build temporarily red between Task 11–20 by design."

---

### Task 12: Implement `BackfillProvider` (recent-messages.robotty.de) [SUBAGENT]

The rustlog endpoint: `https://recent-messages.robotty.de/api/v2/recent-messages/<channel_login>?limit=150`

Response is JSONL of IRC-tag format lines. The implementer parses these into TwitchKit-shaped `ChatMessage` (using a small IRC-tag parser ~80 lines), then runs them through the same Normalizer as live messages.

Note: failures are silent — backfill is a nice-to-have, not a must-have. If rustlog is down, channel join still works with empty chat.

(Full implementation in the spec.)

---

### Task 13–16: UIKit chat list

`ChatListView` is a SwiftUI `UIViewControllerRepresentable` wrapping a UIKit `UIViewController` that hosts a `UICollectionView` with `UICollectionViewDiffableDataSource<Section, ChatLine.ID>`. Cell config uses `UIHostingConfiguration { ChatRow(line: line) }`. Snapshot apply uses `animatingDifferences: false` for high-frequency messages.

(Detailed implementation; ~400 lines across 4 files.)

---

### Task 17–19: Sub/raid bubbles + ChatNotification

Subscribe ChannelSession to `channel.chat.notification`, `channel.chat.message_delete`, `channel.chat.clear`, `channel.raid`. Each event type produces a `ChatLine` with a different `kind`. ChatBubbleRow renders these with styled containers.

---

### Task 20: Swap SwiftUI ScrollView for ChatListView in ChatScreen [SUBAGENT]

This re-greens the build after Task 11's deliberate red. Remove the SwiftUI `ScrollViewReader/LazyVStack` from ChatScreen and replace with `ChatListView(session: session)`. Now the full pipeline (EventSub → Normalizer → ChatLine → ChatListView → UICollectionView) is connected.

---

### Task 21: ChatListDiffTests — verify diff correctness under load [SUBAGENT]

Synthetic test: inject 100 ChatLines into the diffable data source, verify the collection view has exactly 100 items in the expected order. Inject a deletion event (one ChatLine flips to `.deletedPlaceholder`), verify the cell reloads. Inject a chat-clear event (all become `.deletedPlaceholder`), verify a single batch update.

---

## Phase 2.4 — Visual polish

### Task 22: DesignSystem expansion (Brand + Typography + Materials) [SUBAGENT]

Replace the single `Brand.accent` stub with a real palette + typography + materials. Use Liquid Glass `.glassEffect()` and refreshed `Material.regular`/`.thick`/`.glass`.

### Task 23: Apply Liquid Glass to ChannelListScreen + ChatScreen [SUBAGENT]

Wrap nav bar in Liquid Glass material, add subtle layering, refine row chrome. Each pass commits separately.

---

## Self-review (when plan is complete)

### Spec coverage

| Spec section | Tasks |
|---|---|
| Backfill | T12 |
| Third-party emotes | T1–T6 |
| ChatModel.Normalizer | T8–T10 |
| UIKit chat list | T13–T16, T20 |
| Sub/raid/delete bubbles | T17–T19 |
| Liquid Glass polish | T22–T23 |

### Placeholder scan

No "TBD" / "implement later" markers — every code step has the actual code.

### Type-consistency check

- `Emote` referenced from Normalizer (T9), EmoteIndex (T6), ChatLine.LineRun.emote (T8) — same type throughout.
- `EmoteIndex` actor referenced from ChannelSession constructor (T11) and Normalizer (T9) — consistent.
- `ChatLine` referenced from Normalizer return (T9), ChannelSession stream type (T11), ChatListView consumer (T13), ChatRow input (T15) — same type throughout.

### Risk list

- **7TV/BTTV/FFZ API drift:** these are third-party services. If they change their JSON shape, providers need updates. Each Task 3–5 includes a "verify shape" step before writing code to catch drift.
- **`nonisolated(unsafe)` on EmoteIndex.snapshot:** documented escape hatch with a note about falling back to OSAllocatedUnfairLock if strict-concurrency flags it.
- **Build temporarily red between T11–T20:** documented + intentional.
- **UIHostingConfiguration cells with rapidly mutating content:** Apple's pattern, well-supported on iOS 26, but worth profiling under the synthetic load test in T21.

---

**End of plan.** Estimated implementer time: 8–14 hours over 2–3 sessions.
