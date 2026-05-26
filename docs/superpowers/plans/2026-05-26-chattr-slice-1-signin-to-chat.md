# chattr Slice 1 — Sign-In to Live Chat (vertical-slice plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks marked **[USER]** require Xcode UI clicks and must be done by Andrew; **[SUBAGENT]** tasks can be dispatched.

**Goal:** Deliver the thinnest possible end-to-end path: launch chattr → sign in with Twitch → see followed channels → tap one → see real live `channel.chat.message` events render as `username: text` rows. No third-party emotes, no UIKit chat list, no backfill, no Liquid Glass polish — those are *additive* in later slices.

**Why a slice first:** validates that every layer (OAuth → SwiftData → TwitchKit Helix → TwitchKit EventSub → `ChannelSession` actor → `AsyncStream` → SwiftUI) actually plays nicely together before fanning out 50 files. Once green, every later phase is additive.

**Architecture (this slice):**

```
chattrApp (@main, SwiftUI App)
   ├─ ModelContainer (SwiftData: Account, JoinedChannel)
   └─ RootView
        ├─ if accountStore.activeAccount == nil → SignInView
        │     └─ ASWebAuthenticationSession → TwitchAuth.authenticate(withAuthorizationCode:)
        │     └─ persists Account via SwiftData
        └─ else → NavigationStack
             ├─ ChannelListScreen
             │     └─ HelixClient.followedChannels(userId:) → List(channels) { row → ChatScreen }
             └─ ChatScreen
                   └─ ChannelSession actor → EventSub → AsyncStream<[ChatMessage]> → List(messages)
```

**Tech stack:** Swift 6.2, iOS 26, SwiftUI, SwiftData, `branch: "main"` of `https://github.com/AndrewBeshay/TwitchKit.git`, Swift Testing, `os.Logger`. No third-party deps for this slice (Nuke etc. come later).

**Spec:** `docs/superpowers/specs/2026-05-24-chattr-design.md` (the slice covers the foundational subset; later slices fill in `ChatModel`, `EmoteSources`, the UIKit chat list, etc.)

---

## File map (this slice)

```
chattr/                                       ← Xcode app target source
  chattrApp.swift                             T25  modify
  ContentView.swift                           T25  modify (or delete)
  Assets.xcassets                             (Xcode generates)

Packages/                                     ← all are local SPM packages
  Core/
    Package.swift                             T7   new
    Sources/Core/AppLogger.swift              T7   new
    Sources/Core/AppError.swift               T7   new
  DesignSystem/
    Package.swift                             T8   new
    Sources/DesignSystem/Brand.swift          T8   new
  Accounts/
    Package.swift                             T10  new
    Sources/Accounts/Account.swift            T10  new (SwiftData @Model)
    Sources/Accounts/OAuthFlow.swift          T11  new (ASWebAuthenticationSession)
    Sources/Accounts/AccountStore.swift       T12  new (actor)
    Sources/Accounts/SignInView.swift         T13  new (SwiftUI)
    Tests/AccountsTests/AccountStoreTests.swift T15 new
  Channels/
    Package.swift                             T16  new
    Sources/Channels/JoinedChannel.swift      T16  new (SwiftData @Model)
    Sources/Channels/ChannelSession.swift     T17  new (actor + AsyncStream)
    Sources/Channels/ChannelSessionRegistry.swift T18  new (actor)
    Tests/ChannelsTests/ChannelSessionTests.swift T20 new
  Features/
    Package.swift                             T21  new
    Sources/Features/ChannelListScreen.swift  T21  new
    Sources/Features/ChatScreen.swift        T22  new
    Sources/Features/RootView.swift           T23  new
```

---

## Phase chattr-slice.1 — Project Foundation

### Task 1: Create the chattr iOS app target in Xcode [USER]

**Files:** `chattr.xcodeproj/` (Xcode-generated)

- [ ] **Step 1: Create the project**

In Xcode: **File → New → Project…**
  - Template: **iOS → App**
  - Product Name: `chattr`
  - Team: your personal team (or none for now)
  - Organization Identifier: `com.andrewbeshay` (or whatever bundle prefix you use)
  - Bundle Identifier: `com.andrewbeshay.chattr` (auto-fills from above)
  - Interface: **SwiftUI**
  - Language: **Swift**
  - Storage: **None** (we'll add SwiftData manually so we control the schema)
  - Include Tests: **YES** (creates a `chattrTests` target)
  - **Save location:** `/Users/landy/Dev/chattr/` — **uncheck "Create Git repository"** (we already have one)
  - Click **Create**

- [ ] **Step 2: Verify project structure**

You should now have:
```
/Users/landy/Dev/chattr/
├── chattr.xcodeproj/
├── chattr/                ← Xcode's app target source
│   ├── chattrApp.swift
│   ├── ContentView.swift
│   └── Assets.xcassets/
├── chattrTests/
├── chattrUITests/
├── docs/                  ← (pre-existing)
└── .gitignore             ← (pre-existing)
```

- [ ] **Step 3: Verify it builds + runs (clean baseline)**

In Xcode toolbar: pick **iPhone 17 Pro** simulator. Press **⌘R**. The default "Hello, world!" screen should appear in the simulator. Close the simulator.

---

### Task 2: Configure deployment target + Swift mode [USER]

**Files:** Project settings (Xcode UI)

- [ ] **Step 1: Set iOS deployment target to 26.0**

Project Navigator → top-level `chattr` project → `chattr` target → **General** tab → **Minimum Deployments** → iOS: change from default to **`26.0`**.

- [ ] **Step 2: Set Swift language version to 6 + strict concurrency**

Same target → **Build Settings** tab → search for `Swift Language Version` → set to **Swift 6**. (If it shows the dropdown as "Swift 6.x", pick the highest available.)

Search for `Swift Concurrency Checking` → set to **Complete** (`SWIFT_STRICT_CONCURRENCY=complete`).

- [ ] **Step 3: Verify still builds**

⌘B. Should compile clean with no warnings (the default template is Swift 6 ready).

---

### Task 3: Create the Packages directory + add to .gitignore [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/.gitkeep`
- Modify: `/Users/landy/Dev/chattr/.gitignore`

- [ ] **Step 1: Create the directory and a placeholder**

Run:
```bash
mkdir -p /Users/landy/Dev/chattr/Packages && touch /Users/landy/Dev/chattr/Packages/.gitkeep
```

- [ ] **Step 2: Ensure xcuserdata is gitignored**

Read `/Users/landy/Dev/chattr/.gitignore`. If `*.xcworkspace/xcuserdata/` is not present, append it. If anything else from this list is missing, add it:
```
*.xcworkspace/xcuserdata/
xcuserdata/
DerivedData/
.build/
.swiftpm/
*.xcuserdata
```
(The pre-existing `.gitignore` already covers most of these — only add missing lines.)

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/.gitkeep .gitignore && git commit -m "Add Packages/ directory for local SPM packages"
```

---

### Task 4: Add TwitchKit as a remote SPM dependency on branch=main [USER]

**Files:** `chattr.xcodeproj/project.pbxproj` (Xcode UI modifies)

- [ ] **Step 1: Add the package dependency in Xcode**

Xcode: **File → Add Package Dependencies…** → in the search bar paste:
```
https://github.com/AndrewBeshay/TwitchKit.git
```
Press Return. Once it resolves:
- **Dependency Rule:** Branch
- **Branch:** `main`
- Click **Add Package**
- In the next dialog, ensure `TwitchKit` library is **checked**, target is **chattr** → **Add Package**

- [ ] **Step 2: Verify the dependency in project settings**

Project → chattr target → **General** → **Frameworks, Libraries, and Embedded Content** → you should see `TwitchKit` listed.

- [ ] **Step 3: Verify it builds**

⌘B. The package will resolve and build (takes ~30 seconds on first import). No errors.

- [ ] **Step 4: Commit Package.resolved**

```bash
cd /Users/landy/Dev/chattr && git add chattr.xcodeproj && git commit -m "Add TwitchKit as remote SPM dependency (branch: main)"
```

---

### Task 5: Quick smoke import to verify TwitchKit is reachable from the app [SUBAGENT]

**Files:** `chattr/chattrApp.swift`

- [ ] **Step 1: Add a smoke `import TwitchKit` line**

Edit `/Users/landy/Dev/chattr/chattr/chattrApp.swift`. At the top, add `import TwitchKit` below `import SwiftUI`. The file should look like:
```swift
import SwiftUI
import TwitchKit

@main
struct chattrApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 2: Verify build**

Have the user run ⌘B from Xcode. (Subagent: report this step as "USER VERIFIES BUILD ⌘B" in your output.) Expected: clean compile.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add chattr/chattrApp.swift && git commit -m "Smoke import: verify TwitchKit is reachable from app target"
```

---

## Phase chattr-slice.2 — Core + DesignSystem skeletons

### Task 6: Create the `Core` local SPM package [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Core/Package.swift`
- Create: `/Users/landy/Dev/chattr/Packages/Core/Sources/Core/AppLogger.swift`
- Create: `/Users/landy/Dev/chattr/Packages/Core/Sources/Core/AppError.swift`

- [ ] **Step 1: Write `Packages/Core/Package.swift`**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"]),
    ],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

- [ ] **Step 2: Write `AppLogger.swift`**

```swift
import Foundation
import os

/// Centralized logger subsystem identifier for all chattr packages.
public enum AppLogger {
    /// Bundle-identifier-style subsystem name used by every chattr logger.
    public static let subsystem = "com.andrewbeshay.chattr"

    /// Convenience builder: `AppLogger.make("Accounts")` → `Logger(subsystem: ..., category: "Accounts")`.
    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
```

- [ ] **Step 3: Write `AppError.swift`**

```swift
import Foundation

/// Domain-agnostic error envelope used at high-level boundaries (UI surfaces, store actors).
/// Specific subsystems can still throw their own typed errors; this is for cases where the
/// UI just needs "something went wrong + display message".
public struct AppError: Error, Sendable, Equatable {
    public let message: String
    public let underlying: String?

    public init(message: String, underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying.map { "\($0)" }
    }
}

extension AppError: LocalizedError {
    public var errorDescription: String? { message }
}
```

- [ ] **Step 4: Verify the package builds**

```bash
cd /Users/landy/Dev/chattr/Packages/Core && swift build
```
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Core && git commit -m "Add Core local SPM package (AppLogger, AppError)"
```

---

### Task 7: Create the `DesignSystem` local SPM package [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/DesignSystem/Package.swift`
- Create: `/Users/landy/Dev/chattr/Packages/DesignSystem/Sources/DesignSystem/Brand.swift`

- [ ] **Step 1: Write `Packages/DesignSystem/Package.swift`**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
    ],
    targets: [
        .target(
            name: "DesignSystem",
            path: "Sources/DesignSystem",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

- [ ] **Step 2: Write `Brand.swift` (minimal — full theme comes in a later slice)**

```swift
import SwiftUI

/// Brand tokens for chattr. This file is intentionally minimal for slice 1 —
/// the full Liquid Glass palette, typography, and material catalog lands in
/// a future slice once the chat path is working end-to-end.
public enum Brand {
    /// Accent color used for chattr's interactive elements.
    /// Picked to be distinguishable from Twitch's purple.
    public static let accent = Color(red: 0.20, green: 0.78, blue: 0.78)
}
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/landy/Dev/chattr/Packages/DesignSystem && swift build
```

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/DesignSystem && git commit -m "Add DesignSystem local SPM package (brand accent stub)"
```

---

### Task 8: Add Core + DesignSystem to the app target [USER]

**Files:** Xcode UI

- [ ] **Step 1: Add the local packages**

Xcode: **File → Add Package Dependencies… → Add Local…** → navigate to `/Users/landy/Dev/chattr/Packages/Core` → **Add Package**. In the next dialog, ensure `Core` library is checked, target is `chattr` → **Add Package**.

Repeat for `/Users/landy/Dev/chattr/Packages/DesignSystem`.

- [ ] **Step 2: Verify in target settings**

Project → chattr target → **General** → **Frameworks, Libraries, and Embedded Content** → you should now see `TwitchKit`, `Core`, `DesignSystem` listed.

- [ ] **Step 3: Build**

⌘B. Clean.

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr && git add chattr.xcodeproj && git commit -m "Add Core + DesignSystem to chattr app target"
```

---

## Phase chattr-slice.3 — Accounts package + OAuth flow

### Task 9: Create the `Accounts` package skeleton with `Account` SwiftData model [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Accounts/Package.swift`
- Create: `/Users/landy/Dev/chattr/Packages/Accounts/Sources/Accounts/Account.swift`

- [ ] **Step 1: Write `Packages/Accounts/Package.swift`**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Accounts",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Accounts", targets: ["Accounts"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Accounts",
            dependencies: [
                "Core",
                .product(name: "TwitchKit", package: "TwitchKit"),
            ],
            path: "Sources/Accounts",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AccountsTests",
            dependencies: ["Accounts"],
            path: "Tests/AccountsTests"
        ),
    ]
)
```

- [ ] **Step 2: Write the `Account` SwiftData model**

File: `Packages/Accounts/Sources/Accounts/Account.swift`
```swift
import Foundation
import SwiftData

/// A locally persisted Twitch account.
///
/// One row per signed-in Twitch identity. Tokens are *not* stored here —
/// they live in TwitchKit's `KeychainTokenStore` keyed by `tokenNamespace`.
/// This row stores the public-ish identity bits the UI needs.
@Model
public final class Account {
    /// Twitch user_id — the canonical stable identifier.
    @Attribute(.unique)
    public var userId: String

    /// Twitch login (lowercase username, e.g. "xqc").
    public var login: String

    /// Twitch display name (preserved capitalization, e.g. "xQc").
    public var displayName: String

    /// URL string to the user's profile image (Twitch hosts these).
    public var profileImageURL: String

    /// The `tokenNamespace` value passed to `TwitchClient` for this account.
    /// Constructed once at sign-in and never changes.
    public var tokenNamespace: String

    /// When this account was added. Used for sorting in the account switcher.
    public var addedAt: Date

    /// When true, the account's refresh token failed and the user must re-auth.
    public var needsReauth: Bool

    public init(
        userId: String,
        login: String,
        displayName: String,
        profileImageURL: String,
        tokenNamespace: String,
        addedAt: Date = .now,
        needsReauth: Bool = false
    ) {
        self.userId = userId
        self.login = login
        self.displayName = displayName
        self.profileImageURL = profileImageURL
        self.tokenNamespace = tokenNamespace
        self.addedAt = addedAt
        self.needsReauth = needsReauth
    }
}
```

- [ ] **Step 3: Verify package builds**

```bash
cd /Users/landy/Dev/chattr/Packages/Accounts && swift build
```
Expected: `Build complete!` (note: first build will resolve TwitchKit from GitHub; may take a moment).

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Accounts && git commit -m "Accounts: Account SwiftData model + package skeleton"
```

---

### Task 10: Implement `OAuthFlow` (ASWebAuthenticationSession wrapper) [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Accounts/Sources/Accounts/OAuthFlow.swift`

- [ ] **Step 1: Read TwitchKit's `TwitchOAuthClient` to confirm the redirect URI**

Run:
```bash
grep -E "redirect|Redirect|callback" /Users/landy/Dev/twitch-kit/Sources/TwitchKit/Auth/TwitchOAuthClient.swift | head -10
```

If the redirect URI is hard-coded (e.g. `"https://localhost"`), use that value. If it's configurable, use the default. Note the value for use in `ASWebAuthenticationSession`.

- [ ] **Step 2: Write `OAuthFlow.swift`**

The exact callback scheme depends on TwitchKit's redirect URI (verify in Step 1). The skeleton below assumes `https://localhost`; if you find a different value, substitute it.

File: `Packages/Accounts/Sources/Accounts/OAuthFlow.swift`
```swift
import AuthenticationServices
import Foundation
import TwitchKit
import os

private let logger = AppLogger.make("Accounts.OAuthFlow")

/// Runs the Twitch authorization-code OAuth flow inside an `ASWebAuthenticationSession`.
///
/// Usage:
/// ```
/// let token = try await OAuthFlow.run(
///     authURL: client.auth.authorizationCodeURL(scopes: [.userReadChat, .userWriteChat, .userReadFollows, .userReadEmail]),
///     callbackScheme: "https",
///     callbackHost: "localhost",
///     presentationContext: anchor
/// )
/// ```
///
/// The caller is responsible for then calling `client.auth.authenticate(withAuthorizationCode:)`
/// with the `code` value returned from the URL.
public enum OAuthFlow {

    public struct Result: Sendable {
        public let code: String
        public let state: String?
    }

    /// Presents the Twitch authorization page and waits for the redirect.
    ///
    /// - Parameters:
    ///   - authURL: URL produced by `TwitchAuth.authorizationCodeURL(scopes:state:)`.
    ///   - callbackScheme: Scheme portion of the redirect URI (e.g. `"https"`).
    ///   - callbackHost: Host portion (e.g. `"localhost"`).
    ///   - presentationAnchor: The `ASPresentationAnchor` (typically a window) the session presents from.
    /// - Returns: Authorization code + optional state.
    @MainActor
    public static func run(
        authURL: URL,
        callbackScheme: String,
        callbackHost: String,
        presentationAnchor: ASPresentationAnchor
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    logger.error("OAuth session failed: \(error.localizedDescription)")
                    continuation.resume(throwing: AppError(message: "Sign in cancelled or failed", underlying: error))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AppError(message: "Sign in returned no URL"))
                    return
                }
                guard
                    let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                    comps.host == callbackHost
                else {
                    continuation.resume(throwing: AppError(message: "Redirect host did not match expected '\(callbackHost)'"))
                    return
                }
                let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
                let state = comps.queryItems?.first(where: { $0.name == "state" })?.value
                guard let code else {
                    continuation.resume(throwing: AppError(message: "Twitch redirect missing authorization code"))
                    return
                }
                continuation.resume(returning: Result(code: code, state: state))
            }
            session.presentationContextProvider = PresentationContextProvider(anchor: presentationAnchor)
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                continuation.resume(throwing: AppError(message: "Failed to start ASWebAuthenticationSession"))
            }
        }
    }

    /// Bridges `ASPresentationAnchor` from a Swift Concurrency caller into the
    /// `ASWebAuthenticationSessionPresentationContextProviding` delegate dance.
    private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        let anchor: ASPresentationAnchor
        init(anchor: ASPresentationAnchor) { self.anchor = anchor }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    }
}

import Core
```

> **Note for implementer:** Swift's `@MainActor` annotation on `run(...)` is intentional — `ASWebAuthenticationSession` requires the main thread to present. The `PresentationContextProvider` is a stored class so it survives the duration of the session callback (otherwise it would be deallocated and the system would dismiss the sheet).

- [ ] **Step 3: Verify the package builds**

```bash
cd /Users/landy/Dev/chattr/Packages/Accounts && swift build
```

If you get errors about `AuthenticationServices` not being available on macOS, add a `#if os(iOS)` wrapper around the file's contents and produce an `#error("OAuthFlow is iOS-only")` on macOS. (Slice 1 is iOS-only; macOS support is a future concern.)

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Accounts/Sources/Accounts/OAuthFlow.swift && git commit -m "Accounts: OAuthFlow (ASWebAuthenticationSession wrapper)"
```

---

### Task 11: Implement `AccountStore` actor [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Accounts/Sources/Accounts/AccountStore.swift`

- [ ] **Step 1: Write `AccountStore.swift`**

```swift
import Foundation
import SwiftData
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.AccountStore")

/// Local registry of signed-in Twitch accounts. Single source of truth for "who is signed in"
/// and which account is currently active.
///
/// Persistence: SwiftData (`Account` rows).
/// Per-account `TwitchClient` instances are constructed lazily and cached in-memory.
public actor AccountStore {
    private let modelContainer: ModelContainer
    private let clientId: String

    /// Cached per-account TwitchClient instances. Keyed by `userId`.
    private var clients: [String: TwitchClient] = [:]

    /// Currently active account's userId. Drives which client/identity drives the UI.
    private var activeUserId: String?

    public init(modelContainer: ModelContainer, clientId: String) {
        self.modelContainer = modelContainer
        self.clientId = clientId
    }

    // MARK: - Public API

    /// All known accounts, newest-first.
    public func allAccounts() async throws -> [Account] {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Account>()
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// The currently active account, if any.
    public func activeAccount() async throws -> Account? {
        guard let activeUserId else { return nil }
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.userId == activeUserId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Set which account is active.
    public func setActive(userId: String) {
        self.activeUserId = userId
        logger.info("Active account → \(userId)")
    }

    /// Returns (constructing if needed) the TwitchClient for the given account.
    public func client(for account: Account) -> TwitchClient {
        if let existing = clients[account.userId] {
            return existing
        }
        let client = TwitchClient(
            clientId: clientId,
            tokenNamespace: account.tokenNamespace
        )
        clients[account.userId] = client
        return client
    }

    /// Persists a new account after a successful OAuth flow. Returns the inserted Account.
    /// `token` is set on the new client's auth before returning so the first Helix call works.
    public func add(token: OAuthToken, scopes: [TwitchScope]) async throws -> Account {
        // 1. Use a temporary TwitchClient with an in-memory store to call /users and learn who we are.
        //    This avoids polluting Keychain with tokens until we know the userId.
        let probe = TwitchClient(
            clientId: clientId,
            tokenStore: InMemoryTokenStore()
        )
        try await probe.auth.setToken(token)
        let user = try await probe.api.fetchUser()

        // 2. Construct the canonical tokenNamespace from userId.
        let namespace = Self.namespace(for: user.id)

        // 3. Build the persistent client (Keychain-backed) and seed it with the token.
        let persistent = TwitchClient(
            clientId: clientId,
            tokenNamespace: namespace
        )
        try await persistent.auth.setToken(token)
        clients[user.id] = persistent

        // 4. Persist the Account row.
        let account = Account(
            userId: user.id,
            login: user.login,
            displayName: user.displayName,
            profileImageURL: user.profileImageUrl,
            tokenNamespace: namespace
        )
        let context = ModelContext(modelContainer)
        context.insert(account)
        try context.save()
        activeUserId = user.id

        logger.info("Added account @\(user.login) (\(user.id))")
        return account
    }

    /// Removes an account: clears its Keychain entries, drops cached client, deletes SwiftData row.
    public func remove(account: Account) async throws {
        let client = client(for: account)
        try await client.auth.tokenProvider.logout()
        clients[account.userId] = nil
        if activeUserId == account.userId {
            activeUserId = nil
        }
        let context = ModelContext(modelContainer)
        context.delete(account)
        try context.save()
        logger.info("Removed account @\(account.login)")
    }

    // MARK: - Helpers

    /// The canonical tokenNamespace string for a given Twitch userId.
    /// Stays stable across launches so Keychain entries persist.
    public static func namespace(for userId: String) -> String {
        "chattr.account.\(userId)"
    }
}
```

> **Note for implementer:** the property `user.profileImageUrl` and method `fetchUser()` come from TwitchKit. The `OAuthToken.setToken(_:)` is on `TwitchAuth`. If any of these names don't match what's actually in TwitchKit, use Grep on `/Users/landy/Dev/twitch-kit/Sources/TwitchKit/` to find the right name and adjust.

- [ ] **Step 2: Build the package**

```bash
cd /Users/landy/Dev/chattr/Packages/Accounts && swift build
```

Fix any compile errors revealed by mismatches with the actual TwitchKit API (use Grep to find the right names). Do not invent methods — only use what exists.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Accounts/Sources/Accounts/AccountStore.swift && git commit -m "Accounts: AccountStore actor (add/remove/activate accounts)"
```

---

### Task 12: Implement `SignInView` (SwiftUI) [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Accounts/Sources/Accounts/SignInView.swift`

- [ ] **Step 1: Write `SignInView.swift`**

```swift
import SwiftUI
import AuthenticationServices
import TwitchKit
import DesignSystem
import Core
import os

private let logger = AppLogger.make("Accounts.SignInView")

/// First-launch screen: presents a "Sign in with Twitch" button that runs the OAuth flow.
///
/// On success, the new Account is persisted via `AccountStore.add(token:scopes:)` and the
/// caller observes the change via SwiftData's `@Query`.
public struct SignInView: View {
    private let accountStore: AccountStore
    private let clientId: String

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    /// The viewer-facing scopes chattr needs.
    private static let scopes: [TwitchScope] = [
        .userReadEmail,
        .userReadChat,
        .userWriteChat,
        .userReadFollows,
    ]

    public init(accountStore: AccountStore, clientId: String) {
        self.accountStore = accountStore
        self.clientId = clientId
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(Brand.accent)

            VStack(spacing: 8) {
                Text("chattr")
                    .font(.largeTitle)
                    .bold()
                Text("Twitch chat, multi-account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Sign in with Twitch")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)
            .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer().frame(height: 32)
        }
    }

    @MainActor
    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            // 1. Build the OAuth URL.
            let temporaryClient = TwitchClient(clientId: clientId, tokenStore: InMemoryTokenStore())
            let authURL = temporaryClient.auth.authorizationCodeURL(scopes: Self.scopes)

            // 2. Present ASWebAuthenticationSession.
            guard let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene }) as? UIWindowScene,
                  let anchor = scene.windows.first else {
                errorMessage = "Couldn't find a window to present sign-in from."
                return
            }

            let result = try await OAuthFlow.run(
                authURL: authURL,
                callbackScheme: "https",
                callbackHost: "localhost",
                presentationAnchor: anchor
            )

            // 3. Exchange the code for tokens (use the same temporary client; it has the OAuthClient configured).
            try await temporaryClient.auth.authenticate(withAuthorizationCode: result.code)
            let token = try await temporaryClient.auth.tokenProvider.token()

            // 4. Hand off to AccountStore — it does the /users probe + persistence.
            _ = try await accountStore.add(token: token, scopes: Self.scopes)
            logger.info("Sign-in succeeded")
        } catch {
            logger.error("Sign-in failed: \(error.localizedDescription)")
            errorMessage = (error as? AppError)?.message ?? error.localizedDescription
        }
    }
}
```

> **Note for implementer:** if any TwitchKit API names don't match (e.g., `authenticate(withAuthorizationCode:)` might be called differently in your local copy), grep `/Users/landy/Dev/twitch-kit/Sources/TwitchKit/Auth/` and adjust.

- [ ] **Step 2: Build the package**

```bash
cd /Users/landy/Dev/chattr/Packages/Accounts && swift build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Accounts/Sources/Accounts/SignInView.swift && git commit -m "Accounts: SignInView (SwiftUI + ASWebAuthenticationSession)"
```

---

### Task 13: Add `Accounts` package to the app target [USER]

- [ ] **Step 1: Add the local package in Xcode**

**File → Add Package Dependencies… → Add Local…** → select `/Users/landy/Dev/chattr/Packages/Accounts` → **Add Package** → check `Accounts` library, target `chattr` → **Add Package**.

- [ ] **Step 2: Verify build**

⌘B. Clean.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add chattr.xcodeproj && git commit -m "Add Accounts package to chattr app target"
```

---

### Task 14: Write the `AccountStore` tests [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Accounts/Tests/AccountsTests/AccountStoreTests.swift`

> **Scope of these tests:** verify SwiftData persistence behavior of `AccountStore` using an in-memory `ModelContainer`. We do *not* test the network/OAuth path here — that needs a live Twitch and is covered by Task 26's smoke test.

- [ ] **Step 1: Write `AccountStoreTests.swift`**

```swift
import Testing
import SwiftData
import Foundation
@testable import Accounts

@Suite("AccountStore (SwiftData persistence)")
struct AccountStoreTests {

    /// In-memory ModelContainer for isolated tests.
    private static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Account.self, configurations: config)
    }

    @Test("allAccounts returns empty initially")
    func emptyInitially() async throws {
        let container = try Self.makeContainer()
        let store = AccountStore(modelContainer: container, clientId: "test-client")
        let all = try await store.allAccounts()
        #expect(all.isEmpty)
    }

    @Test("activeAccount returns nil when no active set")
    func noActiveByDefault() async throws {
        let container = try Self.makeContainer()
        let store = AccountStore(modelContainer: container, clientId: "test-client")
        let active = try await store.activeAccount()
        #expect(active == nil)
    }

    @Test("namespace produces stable identifier per userId")
    func namespaceStable() {
        #expect(AccountStore.namespace(for: "42") == "chattr.account.42")
        #expect(AccountStore.namespace(for: "71092938") == "chattr.account.71092938")
    }
}
```

> **What we deliberately don't test in slice 1:** `add(token:scopes:)` — it hits `client.api.fetchUser()` which is a live network call. We'd need to mock the HTTP layer (which TwitchKit supports via `HTTPClient` protocol injection); deferring this to a later slice when we have richer mock infrastructure.

- [ ] **Step 2: Run the tests**

```bash
cd /Users/landy/Dev/chattr/Packages/Accounts && swift test
```
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Accounts/Tests && git commit -m "Accounts: AccountStore persistence tests"
```

---

## Phase chattr-slice.4 — Channels package + ChannelSession

### Task 15: Create the `Channels` package skeleton + `JoinedChannel` model [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Channels/Package.swift`
- Create: `/Users/landy/Dev/chattr/Packages/Channels/Sources/Channels/JoinedChannel.swift`

- [ ] **Step 1: Write `Packages/Channels/Package.swift`**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Channels",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Channels", targets: ["Channels"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../Accounts"),
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Channels",
            dependencies: [
                "Core",
                "Accounts",
                .product(name: "TwitchKit", package: "TwitchKit"),
            ],
            path: "Sources/Channels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChannelsTests",
            dependencies: ["Channels"],
            path: "Tests/ChannelsTests"
        ),
    ]
)
```

- [ ] **Step 2: Write the `JoinedChannel` SwiftData model**

```swift
import Foundation
import SwiftData

/// A Twitch channel a user is currently sitting in chat for.
///
/// One row per (account, channel) pair. Rows persist across launches so we can
/// restore the user's chat tabs on cold start.
@Model
public final class JoinedChannel {
    /// Twitch broadcaster_user_id.
    public var channelId: String

    /// userId of the Account this join is scoped to (which identity we're chatting *as*).
    public var accountUserId: String

    /// Twitch login of the broadcaster (e.g. "xqc").
    public var loginName: String

    /// Twitch display name of the broadcaster (e.g. "xQc").
    public var displayName: String

    /// When the user joined this channel.
    public var joinedAt: Date

    public init(channelId: String, accountUserId: String, loginName: String, displayName: String, joinedAt: Date = .now) {
        self.channelId = channelId
        self.accountUserId = accountUserId
        self.loginName = loginName
        self.displayName = displayName
        self.joinedAt = joinedAt
    }
}
```

- [ ] **Step 3: Verify build**

```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift build
```

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Channels && git commit -m "Channels: JoinedChannel SwiftData model + package skeleton"
```

---

### Task 16: Implement `ChannelSession` actor [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Channels/Sources/Channels/ChannelSession.swift`

> **Slice 1 scope for ChannelSession:** subscribe to one EventSub event type only (`channel.chat.message`), filter to this session's channel, maintain a ring buffer (cap 500), emit snapshots on a 15ms debounced cadence via `AsyncStream<[ChatMessage]>`. **No** backfill, **no** badges, **no** emote substitution, **no** message-delete handling, **no** send. Those land in later slices.

- [ ] **Step 1: Write `ChannelSession.swift`**

```swift
import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// Owns one chat session for a (account × channel) pair.
///
/// Slice 1 behavior: connects to TwitchKit's EventSub, subscribes to `channel.chat.message`
/// for `channelId × accountUserId`, accumulates messages in a 500-element ring buffer,
/// and emits coalesced snapshots via `lines` every ~15ms while messages arrive.
public actor ChannelSession {

    /// Sliding-window stream of message snapshots. Consumers iterate without actor hops.
    public nonisolated let lines: AsyncStream<[ChatMessage]>
    private let linesContinuation: AsyncStream<[ChatMessage]>.Continuation

    private let client: TwitchClient
    private let channelId: String
    private let channelLoginName: String
    private let accountUserId: String

    /// Ring buffer of received messages, capped at 500.
    private var ring: [ChatMessage] = []
    private static let ringCapacity = 500

    /// Coalesce ticker — debounces snapshot emission to ~15ms.
    private var coalesceTask: Task<Void, Never>?
    private var lastEmittedCount: Int = 0

    /// EventSub event-listening task. Cancelled on `stop()`.
    private var listenerTask: Task<Void, Never>?

    public init(
        client: TwitchClient,
        channelId: String,
        channelLoginName: String,
        accountUserId: String
    ) {
        self.client = client
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.accountUserId = accountUserId
        (lines, linesContinuation) = AsyncStream.makeStream(of: [ChatMessage].self)
    }

    deinit {
        linesContinuation.finish()
    }

    // MARK: - Public

    /// Starts the session: connects EventSub (if needed) and subscribes to chat messages.
    public func start() async throws {
        logger.info("Starting session for #\(self.channelLoginName) (channelId=\(self.channelId))")

        // EventSub.connect() is idempotent and waits for session_welcome before returning.
        try await client.eventSub.connect()

        // Subscribe to channel.chat.message for this channel + our identity.
        let subscription = EventSubSubscription.Chat.message(
            broadcasterID: channelId,
            userID: accountUserId
        )
        try await client.eventSub.subscribe(subscription)
        logger.info("Subscribed to channel.chat.message for #\(self.channelLoginName)")

        // Start listening for events.
        listenerTask?.cancel()
        listenerTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.client.eventSub.events
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self.handle(event: event)
            }
        }
    }

    /// Stops the session: cancels the listener and finishes the lines stream.
    /// (We do NOT delete the EventSub subscription in slice 1 — that's a later slice's concern.)
    public func stop() {
        logger.info("Stopping session for #\(self.channelLoginName)")
        listenerTask?.cancel()
        listenerTask = nil
        coalesceTask?.cancel()
        coalesceTask = nil
    }

    // MARK: - Private

    private func handle(event: EventSubEvent) {
        // EventSubEvent enum cases differ by TwitchKit version — peel out the chat-message variant.
        // The exact case name is whatever your TwitchKit exposes; use Grep on EventSub/EventSubEvents.swift
        // to find it. The likely names are `.chatMessage(ChatMessage)` or `.knownEvent(EventSubKnownEvent)`.
        guard let message = Self.extractChatMessage(from: event) else { return }
        guard message.broadcasterUserId == channelId else { return }

        // Append to ring buffer with cap.
        if ring.count >= Self.ringCapacity {
            ring.removeFirst(ring.count - Self.ringCapacity + 1)
        }
        ring.append(message)

        scheduleCoalescedEmit()
    }

    private func scheduleCoalescedEmit() {
        // If a coalesce task is already pending, leave it — the next emit will include this message.
        if coalesceTask != nil { return }

        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(15))
            guard let self else { return }
            await self.emitSnapshot()
        }
    }

    private func emitSnapshot() {
        coalesceTask = nil
        guard ring.count != lastEmittedCount else { return }
        lastEmittedCount = ring.count
        linesContinuation.yield(ring)
    }

    /// Extracts a `TwitchKit.ChatMessage` from whatever `EventSubEvent` variant your TwitchKit exposes.
    ///
    /// **Implementer note:** the exact pattern-match shape depends on TwitchKit's EventSubEvent enum.
    /// Grep `/Users/landy/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubEvents.swift` for
    /// the case that wraps `channel.chat.message`. Common shapes:
    ///   - `.chatMessage(ChatMessage)` (direct case per event type)
    ///   - `.knownEvent(EventSubKnownEvent)` where `.payload` is an `Any` you type-cast
    /// Update this method's body to match.
    private static func extractChatMessage(from event: EventSubEvent) -> ChatMessage? {
        // PLACEHOLDER pattern — substitute the real one after grepping TwitchKit:
        // if case let .chatMessage(message) = event { return message }
        // return nil
        //
        // For example, if TwitchKit uses .knownEvent(.channelChatMessage(let m)) → adjust accordingly.
        return nil
    }
}
```

> **Implementer must do before commit:** Grep TwitchKit's `EventSubEvents.swift` for the case that delivers a `channel.chat.message` payload. Replace the `extractChatMessage` body with the correct pattern match. Verify the build compiles before committing.

- [ ] **Step 2: Find the real EventSub case and patch `extractChatMessage`**

Run:
```bash
grep -n "case " /Users/landy/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubEvents.swift | head -10
grep -n "EventSubEvent\|case chatMessage\|case knownEvent" /Users/landy/Dev/twitch-kit/Sources/TwitchKit/EventSub/EventSubEvents.swift | head -20
```

Read the result to learn the case name. Then update `extractChatMessage` to do the real match. Example forms:
```swift
// If TwitchKit has: case chatMessage(ChatMessage)
private static func extractChatMessage(from event: EventSubEvent) -> ChatMessage? {
    if case let .chatMessage(message) = event { return message }
    return nil
}
```

- [ ] **Step 3: Build the package**

```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift build
```

Fix compile errors as needed.

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Channels/Sources/Channels/ChannelSession.swift && git commit -m "Channels: ChannelSession actor (subscribe + coalesced AsyncStream)"
```

---

### Task 17: Implement `ChannelSessionRegistry` actor [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift`

> **Slice 1 scope:** the registry owns the lifecycle of `ChannelSession` instances and de-dupes by (account, channel) so we don't spawn two sessions for the same chat. **No** lazy spinup, **no** scene-phase observation, **no** zombie subscription cleanup. Those land in a later slice.

- [ ] **Step 1: Write `ChannelSessionRegistry.swift`**

```swift
import Foundation
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Registry")

/// Owns active `ChannelSession` instances. Keys by (accountUserId, channelId).
public actor ChannelSessionRegistry {
    private let accountStore: AccountStore

    /// Active sessions, keyed by composite "accountUserId/channelId".
    private var sessions: [String: ChannelSession] = [:]

    public init(accountStore: AccountStore) {
        self.accountStore = accountStore
    }

    /// Returns (creating if needed) the session for the given account × channel pair.
    /// The session is `start()`ed automatically on first access.
    public func session(account: Account, channelId: String, channelLoginName: String) async throws -> ChannelSession {
        let key = Self.key(accountUserId: account.userId, channelId: channelId)
        if let existing = sessions[key] {
            return existing
        }

        let client = await accountStore.client(for: account)
        let session = ChannelSession(
            client: client,
            channelId: channelId,
            channelLoginName: channelLoginName,
            accountUserId: account.userId
        )
        try await session.start()
        sessions[key] = session
        logger.info("Created session for @\(account.login)/#\(channelLoginName)")
        return session
    }

    /// Stops and removes the session for the given pair.
    public func leave(accountUserId: String, channelId: String) async {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let session = sessions[key] {
            await session.stop()
            sessions[key] = nil
            logger.info("Left session \(key)")
        }
    }

    private static func key(accountUserId: String, channelId: String) -> String {
        "\(accountUserId)/\(channelId)"
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Channels/Sources/Channels/ChannelSessionRegistry.swift && git commit -m "Channels: ChannelSessionRegistry actor"
```

---

### Task 18: Add `Channels` package to the app target [USER]

- [ ] **Step 1: Add the local package**

Xcode: **File → Add Package Dependencies… → Add Local…** → `/Users/landy/Dev/chattr/Packages/Channels` → **Add Package** → check `Channels` library → target `chattr` → **Add Package**.

- [ ] **Step 2: Build**

⌘B. Clean.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add chattr.xcodeproj && git commit -m "Add Channels package to chattr app target"
```

---

### Task 19: Write `ChannelSession` tests (no live network) [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Channels/Tests/ChannelsTests/ChannelSessionTests.swift`

> **Slice 1 test scope:** Verify the ring-buffer + coalesce behavior using a *synthetic* event stream (no real TwitchKit network). We test our own logic; TwitchKit has its own tests.

- [ ] **Step 1: Write `ChannelSessionTests.swift`**

```swift
import Testing
import Foundation
@testable import Channels

@Suite("ChannelSession (ring buffer + coalesce)")
struct ChannelSessionTests {

    // Slice 1 has limited testability for ChannelSession because its public API requires
    // a real TwitchClient (which would hit the network). We add richer mocking infrastructure
    // in a later slice (Task: HTTPClient protocol mock + EventSub event injector).
    //
    // For now, we have one trivial test that just verifies the type compiles + initializes.
    // Real behavior is verified by Task 26's end-to-end smoke test.

    @Test("ChannelSession placeholder — see end-to-end smoke test for real coverage")
    func placeholder() {
        #expect(true)
    }
}
```

> **Why this test is so thin:** `ChannelSession`'s constructor takes a `TwitchClient`, which can't be constructed without network. Adding a meaningful test requires a mockable transport — which TwitchKit *does* support via its `HTTPClient` protocol, but wiring it through `EventSubClient` events for synthetic injection is itself a chunk of test infrastructure. Deferred to the next slice when we have richer coverage requirements.

- [ ] **Step 2: Run**

```bash
cd /Users/landy/Dev/chattr/Packages/Channels && swift test
```
Expected: 1 test passes.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Channels/Tests && git commit -m "Channels: placeholder tests (real behavior validated by smoke test)"
```

---

## Phase chattr-slice.5 — Features + UI screens

### Task 20: Create the `Features` package skeleton [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Features/Package.swift`

- [ ] **Step 1: Write `Packages/Features/Package.swift`**

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Features",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "Features", targets: ["Features"]),
    ],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../DesignSystem"),
        .package(path: "../Accounts"),
        .package(path: "../Channels"),
        .package(url: "https://github.com/AndrewBeshay/TwitchKit.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Features",
            dependencies: [
                "Core",
                "DesignSystem",
                "Accounts",
                "Channels",
                .product(name: "TwitchKit", package: "TwitchKit"),
            ],
            path: "Sources/Features",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

- [ ] **Step 2: Verify build (will fail until sources exist — that's expected)**

```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build 2>&1 | head -10
```
Expected: "no Swift source files found" or similar — that's OK; we add sources next.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Features/Package.swift && git commit -m "Features: package skeleton"
```

---

### Task 21: Implement `ChannelListScreen` (followed channels) [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Features/Sources/Features/ChannelListScreen.swift`

- [ ] **Step 1: Write `ChannelListScreen.swift`**

```swift
import SwiftUI
import Accounts
import TwitchKit
import Core
import DesignSystem
import os

private let logger = AppLogger.make("Features.ChannelList")

/// Displays the signed-in user's followed channels.
/// Tapping a row pushes a `ChatScreen` for that channel.
public struct ChannelListScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    @State private var channels: [FollowedChannel] = []
    @State private var loadState: LoadState = .idle
    @State private var errorMessage: String?

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed
    }

    public init(account: Account, accountStore: AccountStore) {
        self.account = account
        self.accountStore = accountStore
    }

    public var body: some View {
        Group {
            switch loadState {
            case .idle, .loading:
                ProgressView("Loading channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded where channels.isEmpty:
                ContentUnavailableView(
                    "No followed channels",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Follow channels on twitch.tv and they'll appear here.")
                )
            case .loaded:
                List(channels) { channel in
                    NavigationLink {
                        ChatScreen(
                            account: account,
                            accountStore: accountStore,
                            channelId: channel.broadcasterId,
                            channelLoginName: channel.broadcasterLogin,
                            channelDisplayName: channel.broadcasterName
                        )
                    } label: {
                        HStack {
                            Text(channel.broadcasterName)
                                .font(.headline)
                            Spacer()
                            Text("@\(channel.broadcasterLogin)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            case .failed:
                ContentUnavailableView(
                    "Couldn't load channels",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage ?? "Unknown error")
                )
            }
        }
        .navigationTitle("\(account.displayName)'s Follows")
        .task { await load() }
        .refreshable { await load() }
    }

    @MainActor
    private func load() async {
        loadState = .loading
        errorMessage = nil
        do {
            let client = await accountStore.client(for: account)
            // Pull the first page only for slice 1 — pagination expansion is later.
            let page = try await client.api.fetchFollowedChannelsPage(userID: account.userId, first: 100, after: nil)
            channels = page.followed
            loadState = .loaded
            logger.info("Loaded \(channels.count) followed channels")
        } catch {
            errorMessage = "\(error)"
            loadState = .failed
            logger.error("Failed to load followed channels: \(error.localizedDescription)")
        }
    }
}
```

> **Implementer note:** the exact `fetchFollowedChannelsPage` signature in TwitchKit — verify by reading `/Users/landy/Dev/twitch-kit/Sources/TwitchKit/API/HelixClient+Channels.swift`. Parameter labels (`userID:` vs `userId:`, `first:` vs `pageSize:`, `after:` vs `cursor:`) may differ from what's written above. Adjust to match.

- [ ] **Step 2: Build**

```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build
```
Fix any parameter-label mismatches.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Features/Sources/Features/ChannelListScreen.swift && git commit -m "Features: ChannelListScreen (followed channels list)"
```

---

### Task 22: Implement `ChatScreen` (live messages) [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Features/Sources/Features/ChatScreen.swift`

- [ ] **Step 1: Write `ChatScreen.swift`**

```swift
import SwiftUI
import Accounts
import Channels
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ChatScreen")

/// Renders live `channel.chat.message` events from EventSub as `username: text` rows.
///
/// Slice 1 scope: text only. Twitch native emote fragments are rendered as their literal
/// text values (e.g. "Kappa" remains the word "Kappa", not the image). Image rendering,
/// third-party emote substitution, and message decoration arrive in later slices.
public struct ChatScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    private let channelId: String
    private let channelLoginName: String
    private let channelDisplayName: String

    @State private var session: ChannelSession?
    @State private var lines: [ChatMessage] = []
    @State private var errorMessage: String?

    public init(
        account: Account,
        accountStore: AccountStore,
        channelId: String,
        channelLoginName: String,
        channelDisplayName: String
    ) {
        self.account = account
        self.accountStore = accountStore
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .padding()
                    }
                    ForEach(lines) { line in
                        ChatRow(message: line)
                            .id(line.messageId)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.messageId, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("#\(channelLoginName)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await startSession() }
    }

    @MainActor
    private func startSession() async {
        do {
            let client = await accountStore.client(for: account)
            let session = ChannelSession(
                client: client,
                channelId: channelId,
                channelLoginName: channelLoginName,
                accountUserId: account.userId
            )
            try await session.start()
            self.session = session
            logger.info("ChatScreen started session for #\(channelLoginName)")

            // Bridge AsyncStream → @State updates on the main actor.
            Task { [session] in
                for await snapshot in session.lines {
                    await MainActor.run {
                        self.lines = snapshot
                    }
                }
            }
        } catch {
            errorMessage = "Couldn't open chat: \(error.localizedDescription)"
            logger.error("ChatScreen start failed: \(error.localizedDescription)")
        }
    }
}

/// One chat-message row: bold username then message text.
struct ChatRow: View {
    let message: ChatMessage

    var body: some View {
        (
            Text(message.chatterUserName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            + Text(": ")
                .foregroundStyle(.secondary)
            + Text(message.message.text)
                .font(.callout)
        )
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Best-effort author color. Falls back to neutral when not parseable.
    private var color: Color {
        guard !message.color.isEmpty,
              let parsed = Color(hex: message.color) else {
            return .primary
        }
        return parsed
    }
}

/// Tiny helper: Color from "#RRGGBB" string.
private extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self.init(red: r, green: g, blue: b)
    }
}
```

> **Implementer note:** `ChatMessage` is `TwitchKit.ChatMessage`. The fields used (`messageId`, `chatterUserName`, `message.text`, `color`) match what we saw in TwitchKit's `Models/ChatMessage.swift`. If any field name differs, adjust.

- [ ] **Step 2: Build**

```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Features/Sources/Features/ChatScreen.swift && git commit -m "Features: ChatScreen (live messages render as username: text)"
```

---

### Task 23: Implement `RootView` (auth-gate) [SUBAGENT]

**Files:**
- Create: `/Users/landy/Dev/chattr/Packages/Features/Sources/Features/RootView.swift`

- [ ] **Step 1: Write `RootView.swift`**

```swift
import SwiftUI
import SwiftData
import Accounts
import Channels
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.Root")

/// The app's root view. Decides between sign-in flow and the main app shell.
///
/// `accounts` is driven by SwiftData's `@Query` so it auto-refreshes when
/// `AccountStore.add(...)` inserts a new row.
public struct RootView: View {
    private let accountStore: AccountStore
    private let clientId: String

    @Query(sort: \Account.addedAt, order: .reverse)
    private var accounts: [Account]

    public init(accountStore: AccountStore, clientId: String) {
        self.accountStore = accountStore
        self.clientId = clientId
    }

    public var body: some View {
        Group {
            if let active = accounts.first {
                NavigationStack {
                    ChannelListScreen(account: active, accountStore: accountStore)
                }
            } else {
                SignInView(accountStore: accountStore, clientId: clientId)
            }
        }
        .onChange(of: accounts.first?.userId) { _, newId in
            // Keep AccountStore.activeUserId in sync with whatever account is currently first.
            // For slice 1 we just pick first-by-addedAt. Real switching UI lands in a later slice.
            if let newId {
                Task { await accountStore.setActive(userId: newId) }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build
```

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add Packages/Features/Sources/Features/RootView.swift && git commit -m "Features: RootView (auth-gate driven by @Query)"
```

---

### Task 24: Add `Features` package to the app target [USER]

- [ ] **Step 1: Add the local package**

Xcode: **File → Add Package Dependencies… → Add Local…** → `/Users/landy/Dev/chattr/Packages/Features` → **Add Package** → check `Features` library → target `chattr` → **Add Package**.

- [ ] **Step 2: Build**

⌘B. Clean.

- [ ] **Step 3: Commit**

```bash
cd /Users/landy/Dev/chattr && git add chattr.xcodeproj && git commit -m "Add Features package to chattr app target"
```

---

### Task 25: Wire `chattrApp.swift` end-to-end [SUBAGENT, then USER for credential paste]

**Files:**
- Modify: `/Users/landy/Dev/chattr/chattr/chattrApp.swift`
- Delete (or replace): `/Users/landy/Dev/chattr/chattr/ContentView.swift`

- [ ] **Step 1: Replace the default app entry with the real wiring**

Edit `chattrApp.swift` to:
```swift
import SwiftUI
import SwiftData
import Accounts
import Channels
import Features
import TwitchKit

@main
struct chattrApp: App {
    // ────────────────────────────────────────────────────────────────────────
    // ⚠️ REPLACE `TWITCH_CLIENT_ID_HERE` with the Client ID from dev.twitch.tv
    // for the chattr application you registered. Note: this is the public
    // client ID, not the client secret — that's fine to commit. For Twitch's
    // authorization-code flow, the client secret is NOT required when using
    // PKCE on a mobile/installed app. (TwitchKit's TwitchOAuthClient handles
    // the flow.)
    // ────────────────────────────────────────────────────────────────────────
    static let clientId = "TWITCH_CLIENT_ID_HERE"

    let modelContainer: ModelContainer
    let accountStore: AccountStore

    init() {
        do {
            let container = try ModelContainer(for: Account.self, JoinedChannel.self)
            self.modelContainer = container
            self.accountStore = AccountStore(modelContainer: container, clientId: Self.clientId)
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(accountStore: accountStore, clientId: Self.clientId)
                .modelContainer(modelContainer)
        }
    }
}
```

Delete `ContentView.swift` (it's the Xcode default and no longer used).

- [ ] **Step 2: USER — paste your Twitch Client ID**

In `chattrApp.swift`, replace `"TWITCH_CLIENT_ID_HERE"` with the actual Client ID from your chattr application registered at https://dev.twitch.tv/console/apps.

> **Important:** the redirect URI registered at dev.twitch.tv must include `https://localhost` (matching what TwitchKit's OAuth flow uses by default). If it doesn't, the OAuth flow will fail with a "redirect URI mismatch" error.

- [ ] **Step 3: Build**

⌘B. Clean.

- [ ] **Step 4: Commit (note: the client ID IS safe to commit — it's a public identifier)**

```bash
cd /Users/landy/Dev/chattr && git add chattr/chattrApp.swift && git rm chattr/ContentView.swift && git commit -m "Wire chattr app: SwiftData + AccountStore + RootView"
```

---

## Phase chattr-slice.6 — End-to-end smoke test

### Task 26: Real-account end-to-end smoke test [USER]

**Files:** None — you're driving the simulator.

This is the moment the architecture proves itself. We sign in with a real Twitch account and watch real messages stream into the app.

- [ ] **Step 1: Verify your Twitch app registration**

Visit https://dev.twitch.tv/console/apps. Your chattr application must have:
- A registered name (e.g. "chattr")
- OAuth Redirect URLs containing `https://localhost`
- Category: "Mobile Application" (or similar)
- The Client ID matches what you pasted in `chattrApp.swift`

- [ ] **Step 2: Launch the app on a simulator**

In Xcode: pick iPhone 17 Pro (iOS 26) simulator → **⌘R**. The app launches to `SignInView`.

- [ ] **Step 3: Sign in**

Tap **Sign in with Twitch**. A web sheet appears showing Twitch's authorization page. Log in with your Twitch credentials. Approve the requested scopes. The sheet dismisses.

- [ ] **Step 4: Verify the followed-channels list loads**

You should see your followed channels list. Each row shows display name + @login.

- [ ] **Step 5: Tap a live channel**

Pick a channel you know is currently live (or any followed channel — but if they're offline, the chat will be quiet). Tap the row. The chat screen pushes onto the nav stack.

- [ ] **Step 6: Verify live messages arrive**

Within 1–3 seconds of EventSub subscribing, you should see chat messages appear in the bottom of the screen, scrolling as new ones arrive. Each message shows `[username]: [text]`.

**If you see messages: 🎉 the slice is complete and the architecture is proven end-to-end.**

- [ ] **Step 7: Try the back navigation**

Tap **<** to go back to the channel list. Tap another channel. Confirm a fresh session establishes and messages flow there too.

---

### Task 27: Commit the working slice + capture screenshots [USER]

- [ ] **Step 1: Capture a screenshot of the working chat screen**

In the simulator: **File → New Screen Shot** (⌘S). Save to `~/Dev/chattr/docs/slice-1-screenshot.png`.

- [ ] **Step 2: Document the working state**

Create `docs/slice-1-completed.md`:
```markdown
# chattr slice-1 completed

**Date:** [today's date]
**Status:** ✅ Slice 1 working end-to-end.

## What works
- Sign in with Twitch via ASWebAuthenticationSession + TwitchKit auth-code flow
- Account persisted via SwiftData with per-account Keychain token isolation
- Followed-channels list pulled from Helix `fetchFollowedChannelsPage`
- `ChannelSession` actor subscribes to `channel.chat.message` EventSub
- Live messages stream into a SwiftUI `ScrollView`/`LazyVStack` as `username: text`

## What's deliberately deferred to later slices
- Backfill via `recent-messages.robotty.de`
- Third-party emote substitution (7TV / BTTV / FFZ) via `EmoteSources` + `EmoteIndex`
- `ChatModel.Normalizer` (raw fragments → display-ready `ChatLine.runs`)
- UIKit `UICollectionView` + `UIHostingConfiguration` chat list (we're on SwiftUI ScrollView for now)
- Liquid Glass theming polish
- Multi-account UI (switcher, add additional account)
- Sub / raid / message-delete / chat-clear event rendering
- Sending messages
- Highlight sound on mentions
- Emote picker
- Stick-to-bottom controller w/ "↓ N new messages" pill
- Settings, highlight keywords, account management UI

## Screenshot

![chattr chat screen — slice 1](slice-1-screenshot.png)
```

- [ ] **Step 3: Commit everything**

```bash
cd /Users/landy/Dev/chattr && git add docs/slice-1-screenshot.png docs/slice-1-completed.md && git commit -m "Slice 1 complete: sign-in to live chat working end-to-end"
```

---

## Self-review

### Spec coverage check

This slice covers the architectural foundation of the chattr design spec:

| Spec area | Slice covers? |
|---|---|
| Multi-account (`AccountStore` + per-account `TwitchClient`) | ✅ infrastructure in place; UI for multiple accounts is later |
| OAuth (`ASWebAuthenticationSession` + Keychain via TwitchKit) | ✅ |
| SwiftData persistence (`Account`, `JoinedChannel`) | ✅ |
| TwitchKit Helix consumption (followed channels) | ✅ |
| TwitchKit EventSub consumption (`channel.chat.message`) | ✅ |
| `ChannelSession` actor + `AsyncStream<[ChatMessage]>` | ✅ |
| 15ms snapshot coalesce | ✅ |
| 500-element ring buffer | ✅ |
| SwiftUI UI (RootView, ChannelListScreen, ChatScreen) | ✅ |
| Third-party emotes | ❌ deferred to next slice |
| UIKit chat list w/ `UIHostingConfiguration` | ❌ deferred (SwiftUI suffices for slice) |
| Liquid Glass polish | ❌ deferred (Brand stub only) |
| Backfill | ❌ deferred |
| Send + emote picker | ❌ deferred |
| Sub/raid/delete event rendering | ❌ deferred (only `channel.chat.message` in this slice) |
| Mod actions | ❌ post-MVP per spec |
| Push notifications | ❌ post-MVP per spec |

The deferred items are all *additive* and don't change the existing slice's architecture — they expand it.

### Placeholder scan

- `"TWITCH_CLIENT_ID_HERE"` in Task 25 is a deliberate placeholder *for the user to fill in*. Marked clearly in comments.
- `extractChatMessage` in Task 16 is a placeholder that the implementer **must** patch in Task 16 Step 2 with the real pattern match (the exact case name depends on TwitchKit's current `EventSubEvent` shape). Marked with explicit instructions and verification step.
- No other `TODO` / `TBD` strings.

### Type-consistency check

- `Account.userId` / `JoinedChannel.accountUserId` / `accountUserId` parameter consistently use the Twitch user_id string (no `userID`/`userId` drift).
- `tokenNamespace` used consistently across `Account.tokenNamespace`, `AccountStore.namespace(for:)`, `TwitchClient(... tokenNamespace:)`.
- `channelId` / `channelLoginName` / `channelDisplayName` used consistently across `ChannelSession`, `ChannelSessionRegistry.session(...)`, `ChatScreen`.
- `lines: AsyncStream<[ChatMessage]>` used consistently on `ChannelSession` and `ChatScreen.lines: [ChatMessage]`.

### Risk list (things this plan trusts TwitchKit to deliver as documented)

- `TwitchAuth.authorizationCodeURL(scopes:)` returns a URL that hits `https://localhost` as the redirect — verified earlier. If TwitchKit ever changes its default redirect URI, Task 10/12's `callbackHost: "localhost"` must change too.
- `EventSubClient.connect()` is idempotent — multiple concurrent `start()` calls should not double-connect. (TwitchKit's source supports this assumption; verify if you see double-subscriptions in the smoke test.)
- `EventSubEvent` exposes a case that wraps `ChatMessage` for `channel.chat.message`. Task 16 explicitly verifies this and patches the pattern match.
- `HelixClient.fetchFollowedChannelsPage(...)` exists with the parameter labels used in Task 21. If labels differ slightly, Task 21 Step 2 catches them at build time and the implementer adjusts.

---

**End of plan.** Total: 27 tasks. After successful completion, the next slice covers: third-party emotes (`EmoteSources` package), `ChatModel.Normalizer`, the UIKit chat list with synthetic load tests, and Liquid Glass polish.
