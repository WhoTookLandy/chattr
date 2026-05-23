# TwitchKit Extraction (Phase 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract Streamly's local `TwitchKit` package to its own git repo at `~/Dev/twitch-kit/`, refactor it to support multi-account use (pluggable `TokenStore`), add viewer-side scopes + Helix endpoints, extend EventSub parsing for chat-side event types, and tag `v0.1.0` — all while keeping Streamly building at every commit.

**Architecture:** Five-phase refactor. 0.1 extract repo (no API changes). 0.2 introduce pluggable `TokenStore` protocol with a back-compat alias so Streamly keeps building. 0.3 make scopes explicit (constructor parameter) and add viewer endpoints to `HelixClient`. 0.4 extend `EventSubClient.parseEvent` for chat notification / message delete / chat clear / raid events. 0.5 README + CHANGELOG + tag `v0.1.0` + Streamly commit pinning the tag.

**Tech Stack:** Swift 6.2 (language mode 6, strict concurrency), iOS 26 deployment target, swift-tools-version 6.2, Swift Testing framework, `URLProtocol` stubs for network tests, KeychainServices, `os.Logger`.

**Spec:** `docs/superpowers/specs/2026-05-24-chattr-design.md` § "Phase 0 — work order before chattr UI work begins"

---

## File map

**New repo: `~/Dev/twitch-kit/`** (created from Streamly's existing `Streamly/Packages/TwitchKit/`)

| Path | Phase | Status |
|---|---|---|
| `.gitignore` | 0.1 | new |
| `LICENSE` | 0.1 | new (MIT) |
| `README.md` | 0.1, 0.5 | new (stub in 0.1, full in 0.5) |
| `CHANGELOG.md` | 0.5 | new |
| `Package.swift` | 0.1 | moved (unchanged content) |
| `Sources/TwitchKit/TwitchClient.swift` | 0.2, 0.3 | modified (accepts `tokenStore:`, `scopes:`) |
| `Sources/TwitchKit/Auth/TwitchAuth.swift` | 0.2, 0.3 | modified (TokenStore-backed, scopes-as-param) |
| `Sources/TwitchKit/Auth/KeychainStore.swift` | 0.2 | unchanged (internal helper, used by `KeychainTokenStore`) |
| `Sources/TwitchKit/Auth/TokenStore.swift` | 0.2 | **new** (protocol + `KeychainTokenStore` + `InMemoryTokenStore`) |
| `Sources/TwitchKit/Scopes.swift` | 0.3 | **new** (namespace with viewer + streamer scope constants) |
| `Sources/TwitchKit/API/HelixClient.swift` | 0.3 | modified (new viewer endpoints) |
| `Sources/TwitchKit/EventSub/EventSubClient.swift` | 0.4 | modified (parseEvent additions) |
| `Sources/TwitchKit/EventSub/EventSubMessage.swift` | 0.4 | modified (new `EventSubEvent` cases) |
| `Sources/TwitchKit/Models/ChatNotification.swift` | 0.4 | **new** (sub/resub/gift/announcement) |
| `Sources/TwitchKit/Models/MessageDelete.swift` | 0.4 | **new** |
| `Sources/TwitchKit/Models/ChatClear.swift` | 0.4 | **new** |
| `Sources/TwitchKit/Models/Raid.swift` | 0.4 | **new** |
| `Tests/TwitchKitTests/TokenStoreTests.swift` | 0.2 | **new** |
| `Tests/TwitchKitTests/KeychainTokenStoreTests.swift` | 0.2 | **new** |
| `Tests/TwitchKitTests/HelixViewerEndpointsTests.swift` | 0.3 | **new** |
| `Tests/TwitchKitTests/HelixURLProtocolStub.swift` | 0.3 | **new** (shared test helper) |
| `Tests/TwitchKitTests/ScopesTests.swift` | 0.3 | **new** |
| `Tests/TwitchKitTests/EventSubChatNotificationTests.swift` | 0.4 | **new** |
| `Tests/TwitchKitTests/EventSubMessageDeleteTests.swift` | 0.4 | **new** |
| `Tests/TwitchKitTests/EventSubChatClearTests.swift` | 0.4 | **new** |
| `Tests/TwitchKitTests/EventSubRaidTests.swift` | 0.4 | **new** |

**Streamly modifications: `~/Dev/Streamly/`**

| Path | Phase | Status |
|---|---|---|
| `Streamly.xcodeproj/project.pbxproj` | 0.1 | modified (SPM local path) |
| `Streamly/Packages/TwitchKit/` (entire directory) | 0.1 | **deleted** |
| `Streamly/App/SceneDelegate.swift:19-23` | 0.2, 0.3 | modified (new `TwitchClient` init args) |
| `Streamly/App/TwitchStore.swift:35` | 0.3 | modified (`Scopes.streamer` instead of `TwitchAuth.scopes`) |
| `Streamly.xcodeproj` (after 0.5) | 0.5 | modified (pin to `v0.1.0` tag) |

---

## Phase 0.1 — Extract TwitchKit to its own repo

### Task 1: Create `~/Dev/twitch-kit/` repo skeleton

**Files:**
- Create: `~/Dev/twitch-kit/.gitignore`
- Create: `~/Dev/twitch-kit/LICENSE`
- Create: `~/Dev/twitch-kit/README.md` (stub)

- [ ] **Step 1: Create directory and init git**

Run:
```bash
mkdir -p ~/Dev/twitch-kit && cd ~/Dev/twitch-kit && git init -b main
```
Expected: `Initialized empty Git repository in /Users/landy/Dev/twitch-kit/.git/`

- [ ] **Step 2: Write `.gitignore`**

File: `~/Dev/twitch-kit/.gitignore`
```
.DS_Store
.build/
.swiftpm/
.vscode/
*.xcodeproj/xcuserdata/
DerivedData/
Package.resolved
```

- [ ] **Step 3: Write `LICENSE` (MIT)**

File: `~/Dev/twitch-kit/LICENSE`
```
MIT License

Copyright (c) 2026 Andrew Beshay

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 4: Write `README.md` stub**

File: `~/Dev/twitch-kit/README.md`
```markdown
# TwitchKit

A modern Swift 6 / iOS 26 client library for the Twitch Helix API and EventSub WebSocket. Pluggable token storage, multi-account ready.

Status: 0.1 — in development. Full README and CHANGELOG land in v0.1.0.
```

- [ ] **Step 5: Initial commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add .gitignore LICENSE README.md && git commit -m "Initial commit: repo skeleton"
```
Expected: one commit on `main` with three files.

---

### Task 2: Copy TwitchKit sources from Streamly into the new repo

**Files:**
- Copy: `~/Dev/Streamly/Streamly/Packages/TwitchKit/Package.swift` → `~/Dev/twitch-kit/Package.swift`
- Copy: `~/Dev/Streamly/Streamly/Packages/TwitchKit/Sources/` → `~/Dev/twitch-kit/Sources/`
- Copy: `~/Dev/Streamly/Streamly/Packages/TwitchKit/Tests/` → `~/Dev/twitch-kit/Tests/`

- [ ] **Step 1: Copy package files**

Run:
```bash
cp -R ~/Dev/Streamly/Streamly/Packages/TwitchKit/Package.swift ~/Dev/twitch-kit/Package.swift
cp -R ~/Dev/Streamly/Streamly/Packages/TwitchKit/Sources ~/Dev/twitch-kit/Sources
cp -R ~/Dev/Streamly/Streamly/Packages/TwitchKit/Tests ~/Dev/twitch-kit/Tests
```

- [ ] **Step 2: Verify file tree**

Run:
```bash
cd ~/Dev/twitch-kit && find . -name "*.swift" -o -name "Package.swift" | sort
```
Expected: lists `Package.swift`, all files under `Sources/TwitchKit/`, all files under `Tests/TwitchKitTests/`. No empty results.

- [ ] **Step 3: Run package tests**

Run:
```bash
cd ~/Dev/twitch-kit && swift test
```
Expected: all existing tests pass (the package was tested in Streamly; nothing has changed). If any fail, stop — something didn't copy correctly.

- [ ] **Step 4: Commit extracted sources**

Run:
```bash
cd ~/Dev/twitch-kit && git add Package.swift Sources Tests && git commit -m "Import TwitchKit sources from Streamly"
```

---

### Task 3: Point Streamly at the new local SPM path; remove the embedded copy

**Files:**
- Modify: `~/Dev/Streamly/Streamly.xcodeproj/project.pbxproj` (via Xcode UI)
- Delete: `~/Dev/Streamly/Streamly/Packages/TwitchKit/` (entire directory)

- [ ] **Step 1: Open Streamly in Xcode**

Run:
```bash
open ~/Dev/Streamly/Streamly.xcodeproj
```

- [ ] **Step 2: In Xcode, replace the embedded TwitchKit SPM reference with a local path to the sibling repo**

Manual Xcode steps:
1. In the Project Navigator, expand the `Streamly` project (top-level icon)
2. Right-click the `TwitchKit` package reference (under "Package Dependencies" or shown as a folder reference) → "Remove Reference" (do NOT click "Move to Trash")
3. With the `Streamly` project still selected: **File → Add Package Dependencies… → Add Local…**
4. Navigate to `~/Dev/twitch-kit` and click `Add Package`
5. Ensure the `TwitchKit` library product is checked, target is `Streamly`, click `Add Package`

Verify: in the `Streamly` target's "Frameworks, Libraries, and Embedded Content", `TwitchKit` should now show with a "Workspace" or local path indicator.

- [ ] **Step 3: Delete the now-orphaned embedded TwitchKit directory**

Run:
```bash
rm -rf ~/Dev/Streamly/Streamly/Packages/TwitchKit
```

- [ ] **Step 4: Build Streamly**

In Xcode: **Product → Build** (⌘B). Expected: build succeeds with no errors.

- [ ] **Step 5: Run Streamly's tests**

In Xcode: **Product → Test** (⌘U). Expected: all tests pass.

- [ ] **Step 6: Commit Streamly's switch to the sibling repo**

Run:
```bash
cd ~/Dev/Streamly && git add -A && git commit -m "TwitchKit: switch from embedded SPM to ../twitch-kit local path"
```

---

## Phase 0.2 — Introduce `TokenStore` protocol (back-compat)

### Task 4: Add `TokenStore` protocol + `InMemoryTokenStore` (TDD)

**Files:**
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Auth/TokenStore.swift`
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/TokenStoreTests.swift`

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/TokenStoreTests.swift`
```swift
import Testing
import Foundation
@testable import TwitchKit

@Suite("InMemoryTokenStore")
struct InMemoryTokenStoreTests {

    @Test("save then load returns the same tokens")
    func saveLoadRoundTrip() async throws {
        let store = InMemoryTokenStore()
        try await store.save(accessToken: "access-abc", refreshToken: "refresh-xyz")
        #expect(try await store.loadAccessToken() == "access-abc")
        #expect(try await store.loadRefreshToken() == "refresh-xyz")
    }

    @Test("loads return nil when nothing was saved")
    func loadEmpty() async throws {
        let store = InMemoryTokenStore()
        #expect(try await store.loadAccessToken() == nil)
        #expect(try await store.loadRefreshToken() == nil)
    }

    @Test("clear erases both tokens")
    func clear() async throws {
        let store = InMemoryTokenStore()
        try await store.save(accessToken: "a", refreshToken: "r")
        try await store.clear()
        #expect(try await store.loadAccessToken() == nil)
        #expect(try await store.loadRefreshToken() == nil)
    }

    @Test("save overwrites prior values")
    func saveOverwrites() async throws {
        let store = InMemoryTokenStore()
        try await store.save(accessToken: "a1", refreshToken: "r1")
        try await store.save(accessToken: "a2", refreshToken: "r2")
        #expect(try await store.loadAccessToken() == "a2")
        #expect(try await store.loadRefreshToken() == "r2")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter InMemoryTokenStoreTests
```
Expected: FAIL with "cannot find type 'InMemoryTokenStore' in scope" (or similar — protocol and impl don't exist yet).

- [ ] **Step 3: Implement `TokenStore` protocol + `InMemoryTokenStore`**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Auth/TokenStore.swift`
```swift
import Foundation

/// Persistence abstraction for OAuth tokens. Consumers inject an implementation
/// into TwitchAuth; the library does not assume Keychain or any specific backend.
public protocol TokenStore: Sendable {
    func loadAccessToken() async throws -> String?
    func loadRefreshToken() async throws -> String?
    func save(accessToken: String, refreshToken: String) async throws
    func clear() async throws
}

/// Non-persistent in-memory implementation. Useful for tests and ephemeral sessions.
public actor InMemoryTokenStore: TokenStore {
    private var access: String?
    private var refresh: String?

    public init() {}

    public func loadAccessToken() throws -> String? { access }
    public func loadRefreshToken() throws -> String? { refresh }

    public func save(accessToken: String, refreshToken: String) throws {
        self.access = accessToken
        self.refresh = refreshToken
    }

    public func clear() throws {
        self.access = nil
        self.refresh = nil
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter InMemoryTokenStoreTests
```
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Auth/TokenStore.swift Tests/TwitchKitTests/TokenStoreTests.swift && git commit -m "Add TokenStore protocol + InMemoryTokenStore"
```

---

### Task 5: Add `KeychainTokenStore` implementation (TDD)

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/Auth/TokenStore.swift` (add `KeychainTokenStore` to same file)
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/KeychainTokenStoreTests.swift`

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/KeychainTokenStoreTests.swift`
```swift
import Testing
import Foundation
@testable import TwitchKit

@Suite("KeychainTokenStore")
struct KeychainTokenStoreTests {

    @Test("save then load returns the same tokens; isolated by identifier")
    func saveLoadRoundTrip() async throws {
        let id = "twitchkit.test.\(UUID().uuidString)"
        let store = KeychainTokenStore(identifier: id)
        defer { Task { try? await store.clear() } }

        try await store.save(accessToken: "access-keychain", refreshToken: "refresh-keychain")
        #expect(try await store.loadAccessToken() == "access-keychain")
        #expect(try await store.loadRefreshToken() == "refresh-keychain")
    }

    @Test("two stores with different identifiers are isolated")
    func isolationByIdentifier() async throws {
        let storeA = KeychainTokenStore(identifier: "twitchkit.test.A.\(UUID().uuidString)")
        let storeB = KeychainTokenStore(identifier: "twitchkit.test.B.\(UUID().uuidString)")
        defer {
            Task { try? await storeA.clear() }
            Task { try? await storeB.clear() }
        }

        try await storeA.save(accessToken: "a-access", refreshToken: "a-refresh")
        try await storeB.save(accessToken: "b-access", refreshToken: "b-refresh")

        #expect(try await storeA.loadAccessToken() == "a-access")
        #expect(try await storeB.loadAccessToken() == "b-access")
    }

    @Test("clear removes tokens; reload returns nil")
    func clearRemovesTokens() async throws {
        let store = KeychainTokenStore(identifier: "twitchkit.test.\(UUID().uuidString)")
        try await store.save(accessToken: "a", refreshToken: "r")
        try await store.clear()

        #expect(try await store.loadAccessToken() == nil)
        #expect(try await store.loadRefreshToken() == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter KeychainTokenStoreTests
```
Expected: FAIL — "cannot find type 'KeychainTokenStore' in scope".

- [ ] **Step 3: Implement `KeychainTokenStore`**

Append to `~/Dev/twitch-kit/Sources/TwitchKit/Auth/TokenStore.swift`:
```swift
/// Keychain-backed token persistence. Each instance is namespaced by `identifier`;
/// two stores with different identifiers do not see each other's tokens.
public struct KeychainTokenStore: TokenStore {
    private let accessKey: String
    private let refreshKey: String

    /// - Parameter identifier: a stable string used to scope Keychain entries.
    ///   For multi-account consumers, pass a per-account value (e.g., the user_id).
    ///   For single-account consumers, any constant works (e.g., "default").
    public init(identifier: String) {
        self.accessKey = "twitchkit.\(identifier).access"
        self.refreshKey = "twitchkit.\(identifier).refresh"
    }

    public func loadAccessToken() throws -> String? {
        try KeychainStore.load(key: accessKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func loadRefreshToken() throws -> String? {
        try KeychainStore.load(key: refreshKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func save(accessToken: String, refreshToken: String) throws {
        try KeychainStore.save(key: accessKey, data: Data(accessToken.utf8))
        try KeychainStore.save(key: refreshKey, data: Data(refreshToken.utf8))
    }

    public func clear() throws {
        KeychainStore.delete(key: accessKey)
        KeychainStore.delete(key: refreshKey)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter KeychainTokenStoreTests
```
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Auth/TokenStore.swift Tests/TwitchKitTests/KeychainTokenStoreTests.swift && git commit -m "Add KeychainTokenStore (identifier-namespaced)"
```

---

### Task 6: Refactor `TwitchAuth` to use `TokenStore`; keep legacy initializer

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/Auth/TwitchAuth.swift`

- [ ] **Step 1: Add the new initializer and route persistence through `TokenStore`**

Edit `TwitchAuth.swift`. Replace the property/initializer/storage block (lines 6–60 in current file) with:

```swift
public actor TwitchAuth {
    private let clientId: String
    private let clientSecret: String
    private let tokenStore: any TokenStore

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?

    /// Redirect URI — Twitch requires HTTPS but allows https://localhost as a special case.
    /// No server runs on localhost — the WKWebView intercepts the navigation before it connects.
    public static let redirectUri = "https://localhost"

    /// Default streamer scope set, retained as a static for backwards source compatibility.
    /// New consumers should pass `scopes` explicitly via `Scopes.streamer` or `Scopes.viewer`.
    public static let scopes = [
        "user:read:email",
        "channel:read:stream_key",
        "channel:manage:broadcast",
        "user:read:chat",
        "user:write:chat",
        "moderator:read:followers",
        "channel:read:ads",
        "channel:read:subscriptions",
    ]

    /// Designated initializer — accepts a pluggable `TokenStore`.
    public init(clientId: String, clientSecret: String, tokenStore: any TokenStore) {
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.tokenStore = tokenStore
    }

    /// Back-compat convenience initializer. Uses `KeychainTokenStore(identifier: "default")`.
    /// New code should prefer the designated initializer.
    public init(clientId: String, clientSecret: String) {
        self.init(
            clientId: clientId,
            clientSecret: clientSecret,
            tokenStore: KeychainTokenStore(identifier: "default")
        )
    }

    // MARK: - Public

    public var isAuthenticated: Bool {
        get async {
            if cachedAccessToken != nil { return true }
            do { return try await tokenStore.loadAccessToken() != nil } catch { return false }
        }
    }

    public func accessToken() async throws -> String {
        if let token = cachedAccessToken { return token }
        if let token = try await tokenStore.loadAccessToken() {
            cachedAccessToken = token
            cachedRefreshToken = try await tokenStore.loadRefreshToken()
            return token
        }
        throw HelixError.notAuthenticated
    }
```

- [ ] **Step 2: Replace direct `KeychainStore.save/delete` calls inside `TwitchAuth` with `tokenStore` calls**

In `TwitchAuth.swift`, find any remaining direct uses of:
- `KeychainStore.save(key: Self.accessTokenKey, ...)`
- `KeychainStore.save(key: Self.refreshTokenKey, ...)`
- `KeychainStore.delete(key: Self.accessTokenKey)`
- `KeychainStore.delete(key: Self.refreshTokenKey)`

Replace them with the corresponding `try await tokenStore.save(accessToken:refreshToken:)` and `try await tokenStore.clear()` calls.

Also delete the now-unused static keys:
```swift
// Remove these two lines:
private static let accessTokenKey = "com.streamly.twitch.accessToken"
private static let refreshTokenKey = "com.streamly.twitch.refreshToken"
```

In the `storeTokens(access:refresh:)` helper, the body becomes:
```swift
private func storeTokens(access: String, refresh: String) async throws {
    cachedAccessToken = access
    cachedRefreshToken = refresh
    try await tokenStore.save(accessToken: access, refreshToken: refresh)
}
```

In `logout()`, the body becomes:
```swift
public func logout() async {
    logger.info("Logging out — clearing tokens")
    cachedAccessToken = nil
    cachedRefreshToken = nil
    try? await tokenStore.clear()
}
```

- [ ] **Step 3: Run all existing TwitchAuth tests + build**

Run:
```bash
cd ~/Dev/twitch-kit && swift test
```
Expected: all tests pass, including any that exercise `TwitchAuth`. If compilation errors complain about `KeychainStore.load` calls in other files, those would surface here — fix by routing through `tokenStore`.

- [ ] **Step 4: Verify Streamly still builds (using legacy initializer)**

In Xcode (`open ~/Dev/Streamly/Streamly.xcodeproj`): **Product → Build** (⌘B). Expected: success — Streamly's `SceneDelegate.swift:19-23` still uses `TwitchClient(clientId:clientSecret:isLive:)` which routes through the legacy `TwitchAuth.init(clientId:clientSecret:)` alias.

- [ ] **Step 5: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Auth/TwitchAuth.swift && git commit -m "TwitchAuth: pluggable TokenStore (legacy init preserved)"
```

---

### Task 7: Update `TwitchClient` facade to accept `tokenStore`

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/TwitchClient.swift`

- [ ] **Step 1: Add designated initializer; keep legacy as convenience**

Replace the entire `TwitchClient.swift` content with:
```swift
import Foundation

/// Top-level facade for TwitchKit. Holds auth, API client, and EventSub client.
/// Sendable — safe to pass across actor boundaries. NOT @Observable.
public final class TwitchClient: Sendable {
    public let clientId: String
    public let auth: TwitchAuth
    public let api: HelixClient
    public let eventSub: EventSubClient

    /// Designated initializer — explicit `tokenStore`.
    public init(
        clientId: String,
        clientSecret: String,
        tokenStore: any TokenStore,
        isLive: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.clientId = clientId
        let auth = TwitchAuth(clientId: clientId, clientSecret: clientSecret, tokenStore: tokenStore)
        let api = HelixClient(auth: auth, clientId: clientId)
        self.auth = auth
        self.api = api
        self.eventSub = EventSubClient(api: api, isLive: isLive)
    }

    /// Back-compat convenience: uses `KeychainTokenStore(identifier: "default")`.
    public convenience init(
        clientId: String,
        clientSecret: String,
        isLive: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.init(
            clientId: clientId,
            clientSecret: clientSecret,
            tokenStore: KeychainTokenStore(identifier: "default"),
            isLive: isLive
        )
    }
}
```

- [ ] **Step 2: Run tests**

Run:
```bash
cd ~/Dev/twitch-kit && swift test
```
Expected: all tests pass.

- [ ] **Step 3: Verify Streamly still builds**

In Xcode, ⌘B. Expected: success.

- [ ] **Step 4: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/TwitchClient.swift && git commit -m "TwitchClient: accept explicit TokenStore (legacy init preserved)"
```

---

### Task 8: Migrate Streamly to the new `TwitchClient` initializer

**Files:**
- Modify: `~/Dev/Streamly/Streamly/App/SceneDelegate.swift:19-23`

- [ ] **Step 1: Update Streamly's `TwitchClient` instantiation**

Edit `~/Dev/Streamly/Streamly/App/SceneDelegate.swift` lines 19-23.

Old:
```swift
let twitchClient = TwitchClient(
    clientId: "8rqdpnm3o5zkv7nlbqsipjdyum3i5k",
    clientSecret: "mdmfgo5dmhoaz21l870sxg3ddeyrnv",
    isLive: { @MainActor in appState.isLive }
)
```

New:
```swift
let twitchClient = TwitchClient(
    clientId: "8rqdpnm3o5zkv7nlbqsipjdyum3i5k",
    clientSecret: "mdmfgo5dmhoaz21l870sxg3ddeyrnv",
    tokenStore: KeychainTokenStore(identifier: "streamly"),
    isLive: { @MainActor in appState.isLive }
)
```

> **Note: existing tokens.** This changes the Keychain key namespace from `com.streamly.twitch.accessToken` to `twitchkit.streamly.access`. Streamly users will need to sign in once after this update. Acceptable for a personal-use app at this stage; document in CHANGELOG.

- [ ] **Step 2: Build Streamly**

In Xcode, ⌘B. Expected: success.

- [ ] **Step 3: Run Streamly tests**

In Xcode, ⌘U. Expected: pass.

- [ ] **Step 4: Commit Streamly migration**

Run:
```bash
cd ~/Dev/Streamly && git add Streamly/App/SceneDelegate.swift && git commit -m "Use new TwitchClient(tokenStore:) initializer with identifier \"streamly\""
```

---

## Phase 0.3 — Viewer scopes + Helix endpoints

### Task 9: Introduce `Scopes` namespace (TDD)

**Files:**
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Scopes.swift`
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/ScopesTests.swift`

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/ScopesTests.swift`
```swift
import Testing
@testable import TwitchKit

@Suite("Scopes")
struct ScopesTests {

    @Test("viewer scope set covers chat read+send and follows")
    func viewerScopes() {
        let viewer = Scopes.viewer
        #expect(viewer.contains("user:read:chat"))
        #expect(viewer.contains("user:write:chat"))
        #expect(viewer.contains("user:read:follows"))
    }

    @Test("streamer scope set covers broadcast manage and stream_key")
    func streamerScopes() {
        let streamer = Scopes.streamer
        #expect(streamer.contains("channel:manage:broadcast"))
        #expect(streamer.contains("channel:read:stream_key"))
    }

    @Test("scope sets are deduplicated")
    func scopesAreUnique() {
        #expect(Set(Scopes.viewer).count == Scopes.viewer.count)
        #expect(Set(Scopes.streamer).count == Scopes.streamer.count)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter ScopesTests
```
Expected: FAIL — "cannot find 'Scopes' in scope".

- [ ] **Step 3: Implement `Scopes`**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Scopes.swift`
```swift
import Foundation

/// Curated Twitch OAuth scope sets for common consumer use cases.
/// Consumers can also pass their own ad-hoc `[String]` to `TwitchAuth`.
public enum Scopes {

    /// Scopes appropriate for a chat-client / viewer-facing app.
    public static let viewer: [String] = [
        "user:read:email",
        "user:read:chat",
        "user:write:chat",
        "user:read:follows",
    ]

    /// Scopes appropriate for a streamer-facing app (broadcast control, stream key).
    public static let streamer: [String] = [
        "user:read:email",
        "channel:read:stream_key",
        "channel:manage:broadcast",
        "user:read:chat",
        "user:write:chat",
        "moderator:read:followers",
        "channel:read:ads",
        "channel:read:subscriptions",
    ]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter ScopesTests
```
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Scopes.swift Tests/TwitchKitTests/ScopesTests.swift && git commit -m "Add Scopes namespace (viewer + streamer)"
```

---

### Task 10: Make `TwitchAuth` accept an explicit `scopes` parameter

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/Auth/TwitchAuth.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/TwitchClient.swift`

- [ ] **Step 1: Add `scopes` parameter to `TwitchAuth.init`**

In `TwitchAuth.swift`, replace the designated initializer signature:

Old:
```swift
public init(clientId: String, clientSecret: String, tokenStore: any TokenStore) {
    self.clientId = clientId
    self.clientSecret = clientSecret
    self.tokenStore = tokenStore
}
```

New:
```swift
private let scopes: [String]

public init(clientId: String, clientSecret: String, scopes: [String], tokenStore: any TokenStore) {
    self.clientId = clientId
    self.clientSecret = clientSecret
    self.scopes = scopes
    self.tokenStore = tokenStore
}

/// Back-compat convenience: scopes default to `Scopes.streamer` (Streamly's prior set).
public init(clientId: String, clientSecret: String, tokenStore: any TokenStore) {
    self.init(
        clientId: clientId,
        clientSecret: clientSecret,
        scopes: Scopes.streamer,
        tokenStore: tokenStore
    )
}
```

- [ ] **Step 2: Use instance `scopes` in `buildAuthURL()`**

In `TwitchAuth.swift`, find `buildAuthURL()` (around line 66). Replace `Self.scopes.joined(separator: " ")` with `self.scopes.joined(separator: " ")`. The relevant queryItem becomes:
```swift
URLQueryItem(name: "scope", value: self.scopes.joined(separator: " ")),
```

- [ ] **Step 3: Add `scopes` parameter to `TwitchClient.init` (both designated and convenience)**

In `TwitchClient.swift`, update:

Designated:
```swift
public init(
    clientId: String,
    clientSecret: String,
    scopes: [String],
    tokenStore: any TokenStore,
    isLive: @escaping @Sendable () async -> Bool = { false }
) {
    self.clientId = clientId
    let auth = TwitchAuth(clientId: clientId, clientSecret: clientSecret, scopes: scopes, tokenStore: tokenStore)
    let api = HelixClient(auth: auth, clientId: clientId)
    self.auth = auth
    self.api = api
    self.eventSub = EventSubClient(api: api, isLive: isLive)
}
```

Back-compat convenience (used by Streamly today):
```swift
public convenience init(
    clientId: String,
    clientSecret: String,
    isLive: @escaping @Sendable () async -> Bool = { false }
) {
    self.init(
        clientId: clientId,
        clientSecret: clientSecret,
        scopes: Scopes.streamer,
        tokenStore: KeychainTokenStore(identifier: "default"),
        isLive: isLive
    )
}

public convenience init(
    clientId: String,
    clientSecret: String,
    tokenStore: any TokenStore,
    isLive: @escaping @Sendable () async -> Bool = { false }
) {
    self.init(
        clientId: clientId,
        clientSecret: clientSecret,
        scopes: Scopes.streamer,
        tokenStore: tokenStore,
        isLive: isLive
    )
}
```

- [ ] **Step 4: Run tests**

Run:
```bash
cd ~/Dev/twitch-kit && swift test
```
Expected: all pass.

- [ ] **Step 5: Verify Streamly still builds**

In Xcode, ⌘B. Expected: success (Streamly uses the back-compat convenience which defaults to `Scopes.streamer`, matching its prior behavior).

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Auth/TwitchAuth.swift Sources/TwitchKit/TwitchClient.swift && git commit -m "TwitchAuth/TwitchClient: explicit scopes parameter (legacy defaults to Scopes.streamer)"
```

---

### Task 11: Migrate Streamly to pass `Scopes.streamer` explicitly

**Files:**
- Modify: `~/Dev/Streamly/Streamly/App/SceneDelegate.swift:19-24`
- Modify: `~/Dev/Streamly/Streamly/App/TwitchStore.swift:35`

- [ ] **Step 1: Update Streamly's `TwitchClient` instantiation to pass `scopes` explicitly**

In `~/Dev/Streamly/Streamly/App/SceneDelegate.swift`, replace lines 19-24:

```swift
let twitchClient = TwitchClient(
    clientId: "8rqdpnm3o5zkv7nlbqsipjdyum3i5k",
    clientSecret: "mdmfgo5dmhoaz21l870sxg3ddeyrnv",
    scopes: Scopes.streamer,
    tokenStore: KeychainTokenStore(identifier: "streamly"),
    isLive: { @MainActor in appState.isLive }
)
```

- [ ] **Step 2: Update `TwitchStore.swift:35` to use `Scopes.streamer` instead of `TwitchAuth.scopes`**

In `~/Dev/Streamly/Streamly/App/TwitchStore.swift`, find line 35 (`URLQueryItem(name: "scope", value: TwitchAuth.scopes.joined(separator: " "))`). Replace `TwitchAuth.scopes` with `Scopes.streamer`:

```swift
URLQueryItem(name: "scope", value: Scopes.streamer.joined(separator: " ")),
```

- [ ] **Step 3: Build Streamly**

In Xcode, ⌘B. Expected: success.

- [ ] **Step 4: Run Streamly tests**

In Xcode, ⌘U. Expected: pass.

- [ ] **Step 5: Commit Streamly migration**

Run:
```bash
cd ~/Dev/Streamly && git add Streamly/App/SceneDelegate.swift Streamly/App/TwitchStore.swift && git commit -m "Use explicit Scopes.streamer in client init and auth URL"
```

---

### Task 12: Add `URLProtocol` stub helper for HelixClient tests

**Files:**
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixURLProtocolStub.swift`

- [ ] **Step 1: Implement the URLProtocol stub**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixURLProtocolStub.swift`
```swift
import Foundation
@testable import TwitchKit

/// Test-only URLProtocol subclass. Configure responses via `Self.handlers` then
/// install a URLSession that uses this protocol.
///
/// Each handler receives the URLRequest and returns (statusCode, bodyData).
final class HelixURLProtocolStub: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)

    nonisolated(unsafe) static var handlers: [Handler] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    static func reset() {
        handlers = []
        capturedRequests = []
    }

    static func push(handler: @escaping Handler) {
        handlers.append(handler)
    }

    /// Returns a URLSession configured to route through this protocol.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HelixURLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        guard !Self.handlers.isEmpty else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "HelixURLProtocolStub", code: 0))
            return
        }
        let handler = Self.handlers.removeFirst()
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

> **Note:** This stub assumes `HelixClient` uses `URLSession.shared` for its requests. Phase 0.3 includes a small refactor (Task 13) to make the `URLSession` injectable so tests can use the stub-backed one.

- [ ] **Step 2: Commit the stub**

Run:
```bash
cd ~/Dev/twitch-kit && git add Tests/TwitchKitTests/HelixURLProtocolStub.swift && git commit -m "Add HelixURLProtocolStub test helper"
```

---

### Task 13: Make `HelixClient`'s `URLSession` injectable

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/API/HelixClient.swift`

- [ ] **Step 1: Add `urlSession` parameter; default to `.shared`**

In `HelixClient.swift`, modify the type and initializer:

Old:
```swift
public struct HelixClient: Sendable {
    private let auth: TwitchAuth
    private let clientId: String

    private static let baseURL = "https://api.twitch.tv/helix/"

    public init(auth: TwitchAuth, clientId: String) {
        self.auth = auth
        self.clientId = clientId
    }
```

New:
```swift
public struct HelixClient: Sendable {
    private let auth: TwitchAuth
    private let clientId: String
    private let urlSession: URLSession

    private static let baseURL = "https://api.twitch.tv/helix/"

    public init(auth: TwitchAuth, clientId: String, urlSession: URLSession = .shared) {
        self.auth = auth
        self.clientId = clientId
        self.urlSession = urlSession
    }
```

- [ ] **Step 2: Replace `URLSession.shared.data(for:)` calls with `self.urlSession.data(for:)`**

Find every `URLSession.shared.data(for:` in `HelixClient.swift` (typically inside `request<T>` and the 401-retry block) and change to `self.urlSession.data(for:`.

- [ ] **Step 3: Build the package to verify**

Run:
```bash
cd ~/Dev/twitch-kit && swift build
```
Expected: success.

- [ ] **Step 4: Verify Streamly still builds**

In Xcode, ⌘B. Expected: success — Streamly uses `HelixClient` via `TwitchClient` which doesn't pass `urlSession`, so the default applies.

- [ ] **Step 5: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/API/HelixClient.swift && git commit -m "HelixClient: injectable URLSession (defaults to .shared)"
```

---

### Task 14: Add `getUser(login:)` endpoint with test

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/API/HelixClient.swift`
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixViewerEndpointsTests.swift`

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixViewerEndpointsTests.swift`
```swift
import Testing
import Foundation
@testable import TwitchKit

@Suite("Helix viewer endpoints")
struct HelixViewerEndpointsTests {

    private func makeClient() async -> HelixClient {
        let store = InMemoryTokenStore()
        try? await store.save(accessToken: "fake-access", refreshToken: "fake-refresh")
        let auth = TwitchAuth(
            clientId: "client-id-test",
            clientSecret: "client-secret-test",
            scopes: Scopes.viewer,
            tokenStore: store
        )
        return HelixClient(
            auth: auth,
            clientId: "client-id-test",
            urlSession: HelixURLProtocolStub.makeSession()
        )
    }

    @Test("getUser(login:) returns the user matching the login")
    func getUserByLogin() async throws {
        HelixURLProtocolStub.reset()
        HelixURLProtocolStub.push { req in
            #expect(req.url?.absoluteString.contains("users") == true)
            #expect(req.url?.absoluteString.contains("login=xqc") == true)
            let body = """
            {"data":[{"id":"71092938","login":"xqc","display_name":"xQc","type":"","broadcaster_type":"partner","description":"","profile_image_url":"https://example.com/p.png","offline_image_url":"","view_count":0,"created_at":"2019-12-23T00:00:00Z"}]}
            """.data(using: .utf8)!
            return (200, body)
        }
        let client = await makeClient()

        let user = try await client.getUser(login: "xqc")
        #expect(user.id == "71092938")
        #expect(user.login == "xqc")
        #expect(user.displayName == "xQc")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests
```
Expected: FAIL — "no exact matches in call to instance method 'getUser'" or "value of type 'HelixClient' has no member 'getUser(login:)'".

- [ ] **Step 3: Implement `getUser(login:)`**

In `HelixClient.swift`, add a new method (after the existing `getUser()`):
```swift
public func getUser(login: String) async throws -> TwitchUser {
    let queryItems = [URLQueryItem(name: "login", value: login)]
    let response: HelixResponse<TwitchUser> = try await request(
        endpoint: "users",
        queryItems: queryItems
    )
    guard let user = response.data.first else {
        throw HelixError.notFound
    }
    return user
}
```

> **Note:** This assumes `HelixError.notFound` exists. If `HelixError` doesn't define it, add `case notFound` to that enum in `HelixError.swift` first.

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests
```
Expected: 1 test passes.

- [ ] **Step 5: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/API/HelixClient.swift Sources/TwitchKit/API/HelixError.swift Tests/TwitchKitTests/HelixViewerEndpointsTests.swift && git commit -m "HelixClient: getUser(login:)"
```

---

### Task 15: Add `getUser(id:)` endpoint with test

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/API/HelixClient.swift`
- Modify: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixViewerEndpointsTests.swift`

- [ ] **Step 1: Add the failing test (append to the existing suite)**

In `HelixViewerEndpointsTests.swift`, append before the closing brace:
```swift
@Test("getUser(id:) returns the user matching the id")
func getUserById() async throws {
    HelixURLProtocolStub.reset()
    HelixURLProtocolStub.push { req in
        #expect(req.url?.absoluteString.contains("users") == true)
        #expect(req.url?.absoluteString.contains("id=71092938") == true)
        let body = """
        {"data":[{"id":"71092938","login":"xqc","display_name":"xQc","type":"","broadcaster_type":"partner","description":"","profile_image_url":"https://example.com/p.png","offline_image_url":"","view_count":0,"created_at":"2019-12-23T00:00:00Z"}]}
        """.data(using: .utf8)!
        return (200, body)
    }
    let client = await makeClient()
    let user = try await client.getUser(id: "71092938")
    #expect(user.login == "xqc")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/getUserById
```
Expected: FAIL — "value of type 'HelixClient' has no member 'getUser(id:)'".

- [ ] **Step 3: Implement `getUser(id:)`**

In `HelixClient.swift`, add:
```swift
public func getUser(id: String) async throws -> TwitchUser {
    let queryItems = [URLQueryItem(name: "id", value: id)]
    let response: HelixResponse<TwitchUser> = try await request(
        endpoint: "users",
        queryItems: queryItems
    )
    guard let user = response.data.first else {
        throw HelixError.notFound
    }
    return user
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/getUserById
```
Expected: pass.

- [ ] **Step 5: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/API/HelixClient.swift Tests/TwitchKitTests/HelixViewerEndpointsTests.swift && git commit -m "HelixClient: getUser(id:)"
```

---

### Task 16: Add `getFollowedChannels(userId:after:)` endpoint with test

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/API/HelixClient.swift`
- Modify: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixViewerEndpointsTests.swift`
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Models/FollowedChannel.swift`

- [ ] **Step 1: Write the failing test**

Append to `HelixViewerEndpointsTests.swift`:
```swift
@Test("getFollowedChannels returns user's followed channel list")
func getFollowedChannels() async throws {
    HelixURLProtocolStub.reset()
    HelixURLProtocolStub.push { req in
        #expect(req.url?.absoluteString.contains("channels/followed") == true)
        #expect(req.url?.absoluteString.contains("user_id=42") == true)
        let body = """
        {"total":2,"data":[
            {"broadcaster_id":"71","broadcaster_login":"xqc","broadcaster_name":"xQc","followed_at":"2024-01-01T00:00:00Z"},
            {"broadcaster_id":"55","broadcaster_login":"caedrel","broadcaster_name":"Caedrel","followed_at":"2024-02-01T00:00:00Z"}
        ],"pagination":{"cursor":"cur-abc"}}
        """.data(using: .utf8)!
        return (200, body)
    }
    let client = await makeClient()
    let result = try await client.getFollowedChannels(userId: "42", after: nil)
    #expect(result.followed.count == 2)
    #expect(result.followed[0].broadcasterLogin == "xqc")
    #expect(result.nextCursor == "cur-abc")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/getFollowedChannels
```
Expected: FAIL — types and method don't exist.

- [ ] **Step 3: Define the `FollowedChannel` model**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Models/FollowedChannel.swift`
```swift
import Foundation

/// A channel the authenticated user follows. From `GET /helix/channels/followed`.
public struct FollowedChannel: Codable, Sendable, Equatable, Identifiable {
    public let broadcasterId: String
    public let broadcasterLogin: String
    public let broadcasterName: String
    public let followedAt: String

    public var id: String { broadcasterId }
}

/// Page of followed-channel results.
public struct FollowedChannelsPage: Sendable, Equatable {
    public let followed: [FollowedChannel]
    public let nextCursor: String?
}
```

- [ ] **Step 4: Implement `getFollowedChannels`**

In `HelixClient.swift`, add:
```swift
public func getFollowedChannels(userId: String, after cursor: String?) async throws -> FollowedChannelsPage {
    var queryItems = [URLQueryItem(name: "user_id", value: userId), URLQueryItem(name: "first", value: "100")]
    if let cursor { queryItems.append(URLQueryItem(name: "after", value: cursor)) }
    let response: HelixResponse<FollowedChannel> = try await request(
        endpoint: "channels/followed",
        queryItems: queryItems
    )
    return FollowedChannelsPage(followed: response.data, nextCursor: response.pagination?.cursor)
}
```

> **Note:** This assumes `HelixResponse<T>` has a `pagination: HelixPagination?` field with a `cursor: String?`. If it doesn't, add it to the existing `HelixResponse` definition before this step.

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/getFollowedChannels
```
Expected: pass.

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Models/FollowedChannel.swift Sources/TwitchKit/API/HelixClient.swift Tests/TwitchKitTests/HelixViewerEndpointsTests.swift && git commit -m "HelixClient: getFollowedChannels(userId:after:)"
```

---

### Task 17: Add `searchChannels(query:liveOnly:)` endpoint with test

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/API/HelixClient.swift`
- Modify: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixViewerEndpointsTests.swift`
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Models/ChannelSearchResult.swift`

- [ ] **Step 1: Write the failing test**

Append to `HelixViewerEndpointsTests.swift`:
```swift
@Test("searchChannels returns matching channels")
func searchChannels() async throws {
    HelixURLProtocolStub.reset()
    HelixURLProtocolStub.push { req in
        #expect(req.url?.absoluteString.contains("search/channels") == true)
        #expect(req.url?.absoluteString.contains("query=xqc") == true)
        #expect(req.url?.absoluteString.contains("live_only=true") == true)
        let body = """
        {"data":[
            {"broadcaster_language":"en","broadcaster_login":"xqc","display_name":"xQc","game_id":"509658","game_name":"Just Chatting","id":"71092938","is_live":true,"tag_ids":[],"thumbnail_url":"https://example.com/t.jpg","title":"X","started_at":"2024-01-01T00:00:00Z"}
        ]}
        """.data(using: .utf8)!
        return (200, body)
    }
    let client = await makeClient()
    let results = try await client.searchChannels(query: "xqc", liveOnly: true)
    #expect(results.count == 1)
    #expect(results[0].broadcasterLogin == "xqc")
    #expect(results[0].isLive == true)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/searchChannels
```
Expected: FAIL.

- [ ] **Step 3: Define the model**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Models/ChannelSearchResult.swift`
```swift
import Foundation

/// A channel result from `GET /helix/search/channels`.
public struct ChannelSearchResult: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let broadcasterLogin: String
    public let displayName: String
    public let broadcasterLanguage: String
    public let gameId: String
    public let gameName: String
    public let isLive: Bool
    public let thumbnailUrl: String
    public let title: String
    public let startedAt: String
}
```

- [ ] **Step 4: Implement `searchChannels`**

In `HelixClient.swift`, add:
```swift
public func searchChannels(query: String, liveOnly: Bool) async throws -> [ChannelSearchResult] {
    let queryItems = [
        URLQueryItem(name: "query", value: query),
        URLQueryItem(name: "live_only", value: liveOnly ? "true" : "false"),
        URLQueryItem(name: "first", value: "20"),
    ]
    let response: HelixResponse<ChannelSearchResult> = try await request(
        endpoint: "search/channels",
        queryItems: queryItems
    )
    return response.data
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/searchChannels
```
Expected: pass.

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Models/ChannelSearchResult.swift Sources/TwitchKit/API/HelixClient.swift Tests/TwitchKitTests/HelixViewerEndpointsTests.swift && git commit -m "HelixClient: searchChannels(query:liveOnly:)"
```

---

### Task 18: Add `deleteEventSubSubscription(id:)` + `listEventSubSubscriptions()` with tests

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/API/HelixClient.swift`
- Modify: `~/Dev/twitch-kit/Tests/TwitchKitTests/HelixViewerEndpointsTests.swift`
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Models/EventSubSubscription.swift`

- [ ] **Step 1: Write the failing tests**

Append to `HelixViewerEndpointsTests.swift`:
```swift
@Test("deleteEventSubSubscription issues DELETE with id query param")
func deleteEventSubSubscription() async throws {
    HelixURLProtocolStub.reset()
    HelixURLProtocolStub.push { req in
        #expect(req.httpMethod == "DELETE")
        #expect(req.url?.absoluteString.contains("eventsub/subscriptions") == true)
        #expect(req.url?.absoluteString.contains("id=sub-abc-123") == true)
        return (204, Data())
    }
    let client = await makeClient()
    try await client.deleteEventSubSubscription(id: "sub-abc-123")
    #expect(HelixURLProtocolStub.capturedRequests.count == 1)
}

@Test("listEventSubSubscriptions decodes id + type + status")
func listEventSubSubscriptions() async throws {
    HelixURLProtocolStub.reset()
    HelixURLProtocolStub.push { req in
        #expect(req.url?.absoluteString.contains("eventsub/subscriptions") == true)
        let body = """
        {"total":1,"data":[
            {"id":"sub-1","status":"enabled","type":"channel.chat.message","version":"1","cost":0,
             "condition":{"broadcaster_user_id":"71092938","user_id":"42"},
             "transport":{"method":"websocket","session_id":"sess-1"},
             "created_at":"2024-01-01T00:00:00Z"}
        ],"max_total_cost":10000,"total_cost":0}
        """.data(using: .utf8)!
        return (200, body)
    }
    let client = await makeClient()
    let subs = try await client.listEventSubSubscriptions()
    #expect(subs.count == 1)
    #expect(subs[0].id == "sub-1")
    #expect(subs[0].type == "channel.chat.message")
    #expect(subs[0].status == "enabled")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/deleteEventSubSubscription
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests/listEventSubSubscriptions
```
Expected: FAIL — methods and `EventSubSubscription` don't exist.

- [ ] **Step 3: Define the model**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Models/EventSubSubscription.swift`
```swift
import Foundation

/// An EventSub subscription record from `GET /helix/eventsub/subscriptions`.
public struct EventSubSubscription: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let status: String       // "enabled", "webhook_callback_verification_pending", "authorization_revoked", ...
    public let type: String         // e.g. "channel.chat.message"
    public let version: String
    public let cost: Int
    public let condition: [String: String]
    public let transport: Transport
    public let createdAt: String

    public struct Transport: Codable, Sendable, Equatable {
        public let method: String   // "websocket" or "webhook"
        public let sessionId: String?
    }
}
```

- [ ] **Step 4: Implement the two endpoints**

In `HelixClient.swift`, add:
```swift
public func deleteEventSubSubscription(id: String) async throws {
    let queryItems = [URLQueryItem(name: "id", value: id)]
    // request<T> requires a Decodable T; for 204-no-content endpoints, use an empty marker.
    let _: HelixResponse<EmptyResponse> = try await request(
        endpoint: "eventsub/subscriptions",
        method: "DELETE",
        queryItems: queryItems
    )
}

public func listEventSubSubscriptions() async throws -> [EventSubSubscription] {
    let response: HelixResponse<EventSubSubscription> = try await request(
        endpoint: "eventsub/subscriptions"
    )
    return response.data
}
```

If `EmptyResponse` doesn't exist, add it next to `HelixResponse`:
```swift
public struct EmptyResponse: Codable, Sendable {}
```

Also adapt `HelixClient.request<T>` to handle status 204 by returning `HelixResponse<EmptyResponse>(data: [])` instead of decoding a body. Update `handleResponse` cases:
```swift
case 200, 202, 204:
    if statusCode == 204 || data.isEmpty {
        // Return an empty response if T is decodable from empty input
        if let empty = HelixResponse<T>(data: [], pagination: nil) as HelixResponse<T>? {
            return empty
        }
        return try JSONDecoder.twitch().decode(HelixResponse<T>.self, from: "{\"data\":[]}".data(using: .utf8)!)
    }
    return try JSONDecoder.twitch().decode(HelixResponse<T>.self, from: data)
```

(If `HelixResponse` doesn't already have an `init(data:pagination:)`, add one.)

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter HelixViewerEndpointsTests
```
Expected: all tests in the suite pass.

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Models/EventSubSubscription.swift Sources/TwitchKit/API/HelixClient.swift Tests/TwitchKitTests/HelixViewerEndpointsTests.swift && git commit -m "HelixClient: deleteEventSubSubscription + listEventSubSubscriptions"
```

---

## Phase 0.4 — Extend EventSub events

### Task 19: Add `MessageDelete` model + parsing with test

**Files:**
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Models/MessageDelete.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubMessage.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubClient.swift`
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubMessageDeleteTests.swift`

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubMessageDeleteTests.swift`
```swift
import Testing
import Foundation
@testable import TwitchKit

@Suite("EventSub channel.chat.message_delete")
struct EventSubMessageDeleteTests {

    @Test("Decode a channel.chat.message_delete event")
    func decodeMessageDelete() throws {
        let json = """
        {
            "broadcaster_user_id": "12826",
            "broadcaster_user_login": "twitch",
            "broadcaster_user_name": "Twitch",
            "target_user_id": "55555",
            "target_user_login": "spammer",
            "target_user_name": "Spammer",
            "message_id": "msg-deleted-xyz"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.twitch().decode(MessageDelete.self, from: json)
        #expect(event.messageId == "msg-deleted-xyz")
        #expect(event.targetUserLogin == "spammer")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubMessageDeleteTests
```
Expected: FAIL — `MessageDelete` undefined.

- [ ] **Step 3: Define the model**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Models/MessageDelete.swift`
```swift
import Foundation

/// `channel.chat.message_delete` payload — a moderator deleted a specific message.
public struct MessageDelete: Codable, Sendable, Equatable, Identifiable {
    public let broadcasterUserId: String
    public let broadcasterUserLogin: String
    public let broadcasterUserName: String
    public let targetUserId: String
    public let targetUserLogin: String
    public let targetUserName: String
    public let messageId: String

    public var id: String { messageId }
}
```

- [ ] **Step 4: Add `EventSubEvent` case + parseEvent routing**

In `EventSubMessage.swift` (or wherever `EventSubEvent` is defined), add a case:
```swift
case messageDelete(MessageDelete)
```

In `EventSubClient.swift`'s `parseEvent(type:data:)` switch, add:
```swift
case "channel.chat.message_delete":
    if let event = try? decoder.decode(MessageDelete.self, from: data) {
        return .messageDelete(event)
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubMessageDeleteTests
```
Expected: pass.

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Models/MessageDelete.swift Sources/TwitchKit/EventSub/EventSubMessage.swift Sources/TwitchKit/EventSub/EventSubClient.swift Tests/TwitchKitTests/EventSubMessageDeleteTests.swift && git commit -m "EventSub: channel.chat.message_delete model + parsing"
```

---

### Task 20: Add `ChatClear` model + parsing with test

**Files:**
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Models/ChatClear.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubMessage.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubClient.swift`
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubChatClearTests.swift`

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubChatClearTests.swift`
```swift
import Testing
import Foundation
@testable import TwitchKit

@Suite("EventSub channel.chat.clear")
struct EventSubChatClearTests {

    @Test("Decode a channel.chat.clear event")
    func decodeChatClear() throws {
        let json = """
        {
            "broadcaster_user_id": "12826",
            "broadcaster_user_login": "twitch",
            "broadcaster_user_name": "Twitch"
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.twitch().decode(ChatClear.self, from: json)
        #expect(event.broadcasterUserLogin == "twitch")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubChatClearTests
```
Expected: FAIL.

- [ ] **Step 3: Define the model**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Models/ChatClear.swift`
```swift
import Foundation

/// `channel.chat.clear` payload — moderator cleared the entire channel chat.
public struct ChatClear: Codable, Sendable, Equatable {
    public let broadcasterUserId: String
    public let broadcasterUserLogin: String
    public let broadcasterUserName: String
}
```

- [ ] **Step 4: Add `EventSubEvent` case + parseEvent routing**

In `EventSubMessage.swift`, add a case:
```swift
case chatClear(ChatClear)
```

In `EventSubClient.swift`'s `parseEvent`, add:
```swift
case "channel.chat.clear":
    if let event = try? decoder.decode(ChatClear.self, from: data) {
        return .chatClear(event)
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubChatClearTests
```
Expected: pass.

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Models/ChatClear.swift Sources/TwitchKit/EventSub/EventSubMessage.swift Sources/TwitchKit/EventSub/EventSubClient.swift Tests/TwitchKitTests/EventSubChatClearTests.swift && git commit -m "EventSub: channel.chat.clear model + parsing"
```

---

### Task 21: Add `Raid` model + parsing with test

**Files:**
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Models/Raid.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubMessage.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubClient.swift`
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubRaidTests.swift`

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubRaidTests.swift`
```swift
import Testing
import Foundation
@testable import TwitchKit

@Suite("EventSub channel.raid")
struct EventSubRaidTests {

    @Test("Decode a channel.raid event")
    func decodeRaid() throws {
        let json = """
        {
            "from_broadcaster_user_id": "1234",
            "from_broadcaster_user_login": "raider",
            "from_broadcaster_user_name": "Raider",
            "to_broadcaster_user_id": "5678",
            "to_broadcaster_user_login": "raided",
            "to_broadcaster_user_name": "Raided",
            "viewers": 150
        }
        """.data(using: .utf8)!

        let event = try JSONDecoder.twitch().decode(Raid.self, from: json)
        #expect(event.fromBroadcasterUserLogin == "raider")
        #expect(event.toBroadcasterUserLogin == "raided")
        #expect(event.viewers == 150)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubRaidTests
```
Expected: FAIL.

- [ ] **Step 3: Define the model**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Models/Raid.swift`
```swift
import Foundation

/// `channel.raid` payload — a channel is raiding ours, or ours is raiding another.
public struct Raid: Codable, Sendable, Equatable {
    public let fromBroadcasterUserId: String
    public let fromBroadcasterUserLogin: String
    public let fromBroadcasterUserName: String
    public let toBroadcasterUserId: String
    public let toBroadcasterUserLogin: String
    public let toBroadcasterUserName: String
    public let viewers: Int
}
```

- [ ] **Step 4: Add `EventSubEvent` case + parseEvent routing**

In `EventSubMessage.swift`, add:
```swift
case raid(Raid)
```

In `EventSubClient.swift`'s `parseEvent`, add:
```swift
case "channel.raid":
    if let event = try? decoder.decode(Raid.self, from: data) {
        return .raid(event)
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubRaidTests
```
Expected: pass.

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Models/Raid.swift Sources/TwitchKit/EventSub/EventSubMessage.swift Sources/TwitchKit/EventSub/EventSubClient.swift Tests/TwitchKitTests/EventSubRaidTests.swift && git commit -m "EventSub: channel.raid model + parsing"
```

---

### Task 22: Add `ChatNotification` model + parsing with tests (sub / resub / gift / announcement)

**Files:**
- Create: `~/Dev/twitch-kit/Sources/TwitchKit/Models/ChatNotification.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubMessage.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubClient.swift`
- Create: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubChatNotificationTests.swift`

`channel.chat.notification` is the most complex of the new events — its payload changes shape by `notice_type`. We model the union as an enum.

- [ ] **Step 1: Write the failing test**

File: `~/Dev/twitch-kit/Tests/TwitchKitTests/EventSubChatNotificationTests.swift`
```swift
import Testing
import Foundation
@testable import TwitchKit

@Suite("EventSub channel.chat.notification")
struct EventSubChatNotificationTests {

    @Test("Decode a sub notification")
    func decodeSubNotification() throws {
        let json = """
        {
            "broadcaster_user_id": "12826","broadcaster_user_login": "twitch","broadcaster_user_name": "Twitch",
            "chatter_user_id": "100","chatter_user_login": "newsub","chatter_user_name": "NewSub",
            "chatter_is_anonymous": false,
            "color": "#FF0000","badges": [],
            "system_message": "NewSub subscribed at Tier 1!",
            "message_id": "msg-1",
            "message": {"text":"thanks!","fragments":[{"type":"text","text":"thanks!"}]},
            "notice_type": "sub",
            "sub": {"sub_tier": "1000", "is_prime": false, "duration_months": 1}
        }
        """.data(using: .utf8)!

        let notification = try JSONDecoder.twitch().decode(ChatNotification.self, from: json)
        #expect(notification.noticeType == "sub")
        if case let .sub(sub) = notification.payload {
            #expect(sub.subTier == "1000")
            #expect(sub.isPrime == false)
        } else {
            Issue.record("Expected .sub payload")
        }
    }

    @Test("Decode an announcement notification")
    func decodeAnnouncement() throws {
        let json = """
        {
            "broadcaster_user_id": "12826","broadcaster_user_login": "twitch","broadcaster_user_name": "Twitch",
            "chatter_user_id": "1","chatter_user_login": "mod","chatter_user_name": "Mod",
            "chatter_is_anonymous": false,
            "color": "#00FF00","badges": [],
            "system_message": "",
            "message_id": "msg-ann-1",
            "message": {"text":"PSA","fragments":[{"type":"text","text":"PSA"}]},
            "notice_type": "announcement",
            "announcement": {"color": "PRIMARY"}
        }
        """.data(using: .utf8)!

        let notification = try JSONDecoder.twitch().decode(ChatNotification.self, from: json)
        #expect(notification.noticeType == "announcement")
        if case let .announcement(ann) = notification.payload {
            #expect(ann.color == "PRIMARY")
        } else {
            Issue.record("Expected .announcement payload")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubChatNotificationTests
```
Expected: FAIL — `ChatNotification` undefined.

- [ ] **Step 3: Define the model**

File: `~/Dev/twitch-kit/Sources/TwitchKit/Models/ChatNotification.swift`
```swift
import Foundation

/// `channel.chat.notification` — the envelope for in-chat system bubbles
/// (subs, resubs, gift subs, raids, announcements, etc.). The shape of the
/// inner payload varies by `noticeType`; we model that as a typed enum.
public struct ChatNotification: Codable, Sendable, Equatable, Identifiable {

    public let messageId: String
    public var id: String { messageId }

    public let broadcasterUserId: String
    public let broadcasterUserLogin: String
    public let broadcasterUserName: String

    public let chatterUserId: String
    public let chatterUserLogin: String
    public let chatterUserName: String
    public let chatterIsAnonymous: Bool

    public let color: String
    public let badges: [ChatBadge]
    public let systemMessage: String
    public let message: ChatMessage.ChatMessageBody

    public let noticeType: String
    public let payload: Payload

    public enum Payload: Sendable, Equatable {
        case sub(Sub)
        case resub(Resub)
        case subGift(SubGift)
        case communitySubGift(CommunitySubGift)
        case announcement(Announcement)
        case raid(RaidNotice)
        case unknown(noticeType: String)
    }

    public struct Sub: Codable, Sendable, Equatable {
        public let subTier: String       // "1000", "2000", "3000"
        public let isPrime: Bool
        public let durationMonths: Int
    }
    public struct Resub: Codable, Sendable, Equatable {
        public let cumulativeMonths: Int
        public let durationMonths: Int
        public let streakMonths: Int?
        public let subTier: String
        public let isPrime: Bool
        public let isGift: Bool
    }
    public struct SubGift: Codable, Sendable, Equatable {
        public let durationMonths: Int
        public let cumulativeTotal: Int?
        public let recipientUserId: String
        public let recipientUserLogin: String
        public let recipientUserName: String
        public let subTier: String
        public let communityGiftId: String?
    }
    public struct CommunitySubGift: Codable, Sendable, Equatable {
        public let id: String
        public let total: Int
        public let subTier: String
        public let cumulativeTotal: Int?
    }
    public struct Announcement: Codable, Sendable, Equatable {
        public let color: String         // "PRIMARY", "BLUE", "GREEN", "ORANGE", "PURPLE"
    }
    public struct RaidNotice: Codable, Sendable, Equatable {
        public let userId: String
        public let userLogin: String
        public let userName: String
        public let viewerCount: Int
        public let profileImageUrl: String
    }

    // Custom decoding: dispatch on noticeType
    private enum CodingKeys: String, CodingKey {
        case messageId, broadcasterUserId, broadcasterUserLogin, broadcasterUserName
        case chatterUserId, chatterUserLogin, chatterUserName, chatterIsAnonymous
        case color, badges, systemMessage, message
        case noticeType
        case sub, resub, subGift = "sub_gift", communitySubGift = "community_sub_gift"
        case announcement, raid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.messageId = try c.decode(String.self, forKey: .messageId)
        self.broadcasterUserId = try c.decode(String.self, forKey: .broadcasterUserId)
        self.broadcasterUserLogin = try c.decode(String.self, forKey: .broadcasterUserLogin)
        self.broadcasterUserName = try c.decode(String.self, forKey: .broadcasterUserName)
        self.chatterUserId = try c.decode(String.self, forKey: .chatterUserId)
        self.chatterUserLogin = try c.decode(String.self, forKey: .chatterUserLogin)
        self.chatterUserName = try c.decode(String.self, forKey: .chatterUserName)
        self.chatterIsAnonymous = try c.decode(Bool.self, forKey: .chatterIsAnonymous)
        self.color = try c.decode(String.self, forKey: .color)
        self.badges = try c.decode([ChatBadge].self, forKey: .badges)
        self.systemMessage = try c.decode(String.self, forKey: .systemMessage)
        self.message = try c.decode(ChatMessage.ChatMessageBody.self, forKey: .message)
        let noticeType = try c.decode(String.self, forKey: .noticeType)
        self.noticeType = noticeType

        switch noticeType {
        case "sub":               self.payload = .sub(try c.decode(Sub.self, forKey: .sub))
        case "resub":             self.payload = .resub(try c.decode(Resub.self, forKey: .resub))
        case "sub_gift":          self.payload = .subGift(try c.decode(SubGift.self, forKey: .subGift))
        case "community_sub_gift": self.payload = .communitySubGift(try c.decode(CommunitySubGift.self, forKey: .communitySubGift))
        case "announcement":      self.payload = .announcement(try c.decode(Announcement.self, forKey: .announcement))
        case "raid":              self.payload = .raid(try c.decode(RaidNotice.self, forKey: .raid))
        default:                  self.payload = .unknown(noticeType: noticeType)
        }
    }

    public func encode(to encoder: Encoder) throws {
        // ChatNotification is decode-only in MVP — Twitch only sends these to us.
        throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "ChatNotification is decode-only"))
    }
}
```

- [ ] **Step 4: Add `EventSubEvent` case + parseEvent routing**

In `EventSubMessage.swift`, add:
```swift
case chatNotification(ChatNotification)
```

In `EventSubClient.swift`'s `parseEvent`, add:
```swift
case "channel.chat.notification":
    if let event = try? decoder.decode(ChatNotification.self, from: data) {
        return .chatNotification(event)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
cd ~/Dev/twitch-kit && swift test --filter EventSubChatNotificationTests
```
Expected: both tests pass.

- [ ] **Step 6: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Models/ChatNotification.swift Sources/TwitchKit/EventSub/EventSubMessage.swift Sources/TwitchKit/EventSub/EventSubClient.swift Tests/TwitchKitTests/EventSubChatNotificationTests.swift && git commit -m "EventSub: channel.chat.notification (sub/resub/gift/announcement/raid)"
```

---

## Phase 0.5 — Cleanup + tag v0.1.0

### Task 23: Write full README

**Files:**
- Modify: `~/Dev/twitch-kit/README.md`

- [ ] **Step 1: Replace the stub README with a full one**

File: `~/Dev/twitch-kit/README.md`
```markdown
# TwitchKit

A modern Swift 6 / iOS 26 client library for the Twitch Helix API and EventSub WebSocket. Pluggable token storage, multi-account ready. Used by [Streamly](https://github.com/landy/streamly) (streamer-side) and [chattr](https://github.com/landy/chattr) (viewer-side).

## Requirements

- iOS 26+
- Swift 6.2+
- Xcode 17+

## Installation

Add as a Swift Package dependency via Xcode (File → Add Package Dependencies…) or in your `Package.swift`:

```swift
.package(url: "https://github.com/landy/twitch-kit", from: "0.1.0")
```

## Quick start

```swift
import TwitchKit

let client = TwitchClient(
    clientId: "<your-client-id>",
    clientSecret: "<your-client-secret>",
    scopes: Scopes.viewer,
    tokenStore: KeychainTokenStore(identifier: "myapp.user.42"),
    isLive: { true }
)

// Helix HTTP
let user = try await client.api.getUser(login: "xqc")

// EventSub WebSocket
try await client.eventSub.connect()
try await client.eventSub.subscribe(
    type: "channel.chat.message",
    version: "1",
    condition: ["broadcaster_user_id": user.id, "user_id": "<your-user-id>"]
)
for await event in client.eventSub.events {
    if case let .chatMessage(msg) = event {
        print("\(msg.chatterUserName): \(msg.message.text)")
    }
}
```

## Multi-account

`KeychainTokenStore(identifier:)` namespaces Keychain entries. For a multi-account app, create one `TwitchClient` per account, each with a distinct `identifier`:

```swift
let clientA = TwitchClient(..., tokenStore: KeychainTokenStore(identifier: "account.12345"))
let clientB = TwitchClient(..., tokenStore: KeychainTokenStore(identifier: "account.67890"))
```

## Custom token storage

Implement `TokenStore` for non-Keychain backends (in-memory, file, app group, app extension):

```swift
struct MyTokenStore: TokenStore {
    func loadAccessToken() async throws -> String? { ... }
    func loadRefreshToken() async throws -> String? { ... }
    func save(accessToken: String, refreshToken: String) async throws { ... }
    func clear() async throws { ... }
}
```

## Supported EventSub events

- `channel.chat.message`
- `channel.chat.notification` (sub / resub / gift / community gift / raid / announcement)
- `channel.chat.message_delete`
- `channel.chat.clear`
- `channel.raid`
- `channel.follow`
- `channel.subscribe`

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 2: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add README.md && git commit -m "README: full v0.1.0 documentation"
```

---

### Task 24: Write CHANGELOG

**Files:**
- Create: `~/Dev/twitch-kit/CHANGELOG.md`

- [ ] **Step 1: Add the CHANGELOG**

File: `~/Dev/twitch-kit/CHANGELOG.md`
```markdown
# Changelog

All notable changes to TwitchKit are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/), and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-05-24

Initial extraction from Streamly into a standalone Swift package.

### Added
- `TokenStore` protocol with default `KeychainTokenStore(identifier:)` and `InMemoryTokenStore` implementations
- `Scopes` namespace with curated `viewer` and `streamer` scope sets
- `TwitchAuth(clientId:clientSecret:scopes:tokenStore:)` designated initializer
- `TwitchClient(clientId:clientSecret:scopes:tokenStore:isLive:)` designated initializer
- `HelixClient.getUser(login:)`, `getUser(id:)`, `getFollowedChannels(userId:after:)`, `searchChannels(query:liveOnly:)`, `deleteEventSubSubscription(id:)`, `listEventSubSubscriptions()`
- EventSub event types: `channel.chat.notification`, `channel.chat.message_delete`, `channel.chat.clear`, `channel.raid`
- Injectable `URLSession` parameter on `HelixClient` for test isolation

### Changed
- `TwitchAuth` no longer hard-codes Keychain key names — all persistence routes through the injected `TokenStore`
- `TwitchAuth.scopes` static is retained for source compatibility but is the streamer scope set; new code should use `Scopes.viewer` or `Scopes.streamer` explicitly

### Migration notes for Streamly
- `TwitchClient(clientId:clientSecret:isLive:)` still works (back-compat); preferred form is now `TwitchClient(clientId:clientSecret:scopes: Scopes.streamer, tokenStore: KeychainTokenStore(identifier: "streamly"), isLive:)`
- Keychain key namespace changed from `com.streamly.twitch.accessToken` / `com.streamly.twitch.refreshToken` to `twitchkit.streamly.access` / `twitchkit.streamly.refresh` — users must sign in once after this update
```

- [ ] **Step 2: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add CHANGELOG.md && git commit -m "Add CHANGELOG with v0.1.0 entry"
```

---

### Task 25: Mark legacy `TwitchAuth` and `TwitchClient` initializers as deprecated

**Files:**
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/Auth/TwitchAuth.swift`
- Modify: `~/Dev/twitch-kit/Sources/TwitchKit/TwitchClient.swift`

- [ ] **Step 1: Add `@available(*, deprecated)` to the legacy initializers**

In `TwitchAuth.swift`, change:
```swift
public init(clientId: String, clientSecret: String) { ... }
```
to:
```swift
@available(*, deprecated, message: "Pass an explicit TokenStore. Use init(clientId:clientSecret:scopes:tokenStore:).")
public init(clientId: String, clientSecret: String) { ... }
```

And:
```swift
public init(clientId: String, clientSecret: String, tokenStore: any TokenStore) { ... }
```
to:
```swift
@available(*, deprecated, message: "Pass explicit scopes. Use init(clientId:clientSecret:scopes:tokenStore:).")
public init(clientId: String, clientSecret: String, tokenStore: any TokenStore) { ... }
```

In `TwitchClient.swift`, similarly deprecate the two-arg and three-arg convenience initializers (`init(clientId:clientSecret:isLive:)` and `init(clientId:clientSecret:tokenStore:isLive:)`).

- [ ] **Step 2: Build the package**

Run:
```bash
cd ~/Dev/twitch-kit && swift build
```
Expected: success (deprecation warnings are not errors).

- [ ] **Step 3: Build Streamly (should still build — uses non-deprecated init now)**

In Xcode, ⌘B. Expected: success. If you see a deprecation warning, it means a Streamly file still uses the old form — fix that call site.

- [ ] **Step 4: Commit**

Run:
```bash
cd ~/Dev/twitch-kit && git add Sources/TwitchKit/Auth/TwitchAuth.swift Sources/TwitchKit/TwitchClient.swift && git commit -m "Deprecate legacy initializers (scopes/tokenStore now required)"
```

---

### Task 26: Tag `v0.1.0`

**Files:** (no file changes; tag only)

- [ ] **Step 1: Verify full test suite passes**

Run:
```bash
cd ~/Dev/twitch-kit && swift test
```
Expected: all tests pass (existing + 4 new test suites).

- [ ] **Step 2: Tag the current commit as v0.1.0**

Run:
```bash
cd ~/Dev/twitch-kit && git tag -a v0.1.0 -m "v0.1.0: initial extraction from Streamly + viewer-side additions"
```

- [ ] **Step 3: Verify tag**

Run:
```bash
cd ~/Dev/twitch-kit && git tag -l
```
Expected output:
```
v0.1.0
```

---

### Task 27: Pin Streamly to `v0.1.0`

**Files:**
- Modify: `~/Dev/Streamly/Streamly.xcodeproj` (Xcode UI)

> If you intend to publish twitch-kit to a remote (e.g. GitHub), do that first (`git remote add origin git@github.com:landy/twitch-kit.git && git push origin main --tags`). Then pin Streamly to the published tag. If staying local-only, skip the publish and keep Streamly on the local-path dependency — re-pin after publishing later.

- [ ] **Step 1 (optional, if publishing): Create GitHub repo and push**

Run:
```bash
cd ~/Dev/twitch-kit
gh repo create landy/twitch-kit --private --source=. --remote=origin --push
git push origin v0.1.0
```
Expected: repo created on GitHub; `v0.1.0` tag visible in repo.

- [ ] **Step 2 (if publishing): Switch Streamly's dependency from local path to versioned package**

In Xcode (`~/Dev/Streamly/Streamly.xcodeproj`):
1. Project Navigator → Streamly project → "Package Dependencies" tab
2. Select `twitch-kit` → "−" (remove)
3. "+" → enter `https://github.com/landy/twitch-kit` → choose Exact Version `0.1.0` → Add Package

- [ ] **Step 3: Build Streamly**

In Xcode, ⌘B. Expected: success — same TwitchKit code, different dependency mode.

- [ ] **Step 4: Commit Streamly's dependency pin**

Run:
```bash
cd ~/Dev/Streamly && git add Streamly.xcodeproj/project.pbxproj Streamly.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved && git commit -m "Pin TwitchKit to v0.1.0"
```

- [ ] **Step 5: Verify Streamly runs end-to-end**

Run Streamly on a device or simulator. Sign in with your Twitch account (one-time, since Keychain keys changed). Verify chat/EventSub works as before.

---

**Phase 0 complete.** TwitchKit is now an independent versioned package at `v0.1.0`, Streamly consumes it cleanly, and chattr can take a dependency on it.

---

## Self-review

### Spec coverage check

Walking the spec's "Phase 0 — work order" section against tasks:

| Spec sub-phase | Tasks |
|---|---|
| 0.1 Extract TwitchKit to its own repo | Tasks 1–3 |
| 0.2 Introduce TokenStore (back-compat) | Tasks 4–8 |
| 0.3 Viewer scopes + Helix endpoints | Tasks 9–18 |
| 0.4 Extend EventSub events | Tasks 19–22 |
| 0.5 Cleanup & tag v0.1.0 | Tasks 23–27 |

Every spec sub-phase is mapped to one or more tasks. The "open questions" table is not implemented here — those are decisions for the chattr plan / first device build, deliberately left for later.

### Placeholder scan

- No "TBD" / "TODO" / "implement later" strings in any task.
- LICENSE defaulted to MIT (not a placeholder — a real choice that the user can change before publish if preferred).
- `HelixError.notFound` is referenced in Task 14 — Task 14 Step 3 explicitly notes "if HelixError doesn't define it, add `case notFound` to that enum first," giving the engineer a concrete instruction. Same pattern for `EmptyResponse` and `HelixPagination` references in Task 18.

### Type consistency check

- `KeychainTokenStore` is referenced in Tasks 5, 6, 7, 8, 10, 11, 23 — always as `KeychainTokenStore(identifier: ...)`. Consistent.
- `Scopes.viewer` / `Scopes.streamer` used in Tasks 9, 10, 11, 14, 23 — consistent.
- `EventSubEvent` cases added in Tasks 19–22: `messageDelete`, `chatClear`, `raid`, `chatNotification`. No naming drift.
- `TokenStore` protocol method signatures used identically across tests (Task 4, 5) and implementation (Tasks 4, 5).
- `HelixClient.urlSession` parameter introduced in Task 13 and used in every endpoint test from Task 14 onward.

No type drift detected.
