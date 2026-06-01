# Block + Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a viewer block and report users from chat — hiding the blocked user's messages and bubbles immediately, syncing with Twitch, and managing the list from Profile.

**Architecture:** A per-account `@Observable @MainActor BlockStore` (Features) owns a local `Codable` `[BlockedChatter]` set, seeded from Twitch (authoritative) + a UserDefaults cache, mutated optimistically with rollback. A pure `BlockFilter` drops any `ChatLine` whose `authorUserId` is blocked; `TabChatModel` applies it reactively. `ChatRow` gains Block + Report… context-menu items; a Profile screen manages unblock.

**Tech Stack:** Swift 6.2 strict concurrency, `@Observable`/`@MainActor`, SwiftUI (`confirmationDialog`, `.glassEffect`), UserDefaults + Codable, Swift Testing. TwitchKit 0.3.0: `blockUser(targetUserID:sourceContext:reason:)`, `unblockUser(targetUserID:)`, `fetchUserBlockListPage(broadcasterID:first:after:) -> HelixPage<BlockedUser>` (`BlockedUser{userId,userLogin,displayName}`), `UserBlockReason{.harassment,.spam,.other}`, `UserBlockSourceContext{.chat}`.

**Spec:** `docs/superpowers/specs/2026-06-01-block-report-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `Packages/Features/Sources/Features/Chat/BlockFilter.swift` | Pure kind-agnostic line filter on `authorUserId` | Create |
| `Packages/Features/Tests/FeaturesTests/BlockFilterTests.swift` | Filter tests | Create |
| `Packages/Features/Sources/Features/Account/BlockStore.swift` | Per-account `@Observable` block set + persistence + `\.blockStore` env key + `BlockedChatter` model | Create |
| `Packages/Features/Tests/FeaturesTests/BlockStoreTests.swift` | Reconcile + persistence + isBlocked tests | Create |
| `Packages/Features/Sources/Features/App/RootView.swift` | Own + seed + inject `BlockStore` for active account | Modify |
| `Packages/Features/Sources/Features/Chat/TabChatModel.swift` | Filter `lines` via `BlockFilter` reactively | Modify |
| `Packages/Features/Sources/Features/Chat/ChatRow.swift` | Block + Report… menu items | Modify |
| `Packages/Features/Sources/Features/Chat/ChatScreen.swift` | Wire `onBlock`/`onReport` (own-message guard) + report confirmation pill | Modify |
| `Packages/Features/Sources/Features/Account/BlockedUsersScreen.swift` | Blocked-users list + unblock | Create |
| `Packages/Features/Sources/Features/Account/ProfileScreen.swift` | NavigationLink to `BlockedUsersScreen` | Modify |

**Unit-tested (pure / sync):** `BlockFilter.apply`, `BlockStore` reconcile + persistence + `isBlocked`. **Manually verified:** the async `block`/`unblock` Helix round-trips, context menu, Profile screen, end-to-end.

---

## Task 1: `BlockFilter` pure filter

**Files:**
- Create: `Packages/Features/Sources/Features/Chat/BlockFilter.swift`
- Test: `Packages/Features/Tests/FeaturesTests/BlockFilterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Tests/FeaturesTests/BlockFilterTests.swift`:
```swift
import Testing
import ChatModel
@testable import Features

@Suite("BlockFilter")
struct BlockFilterTests {
    private func line(_ author: String, kind: ChatLine.Kind = .message) -> ChatLine {
        ChatLine(id: "m-\(author)-\(kind)", kind: kind, authorUserId: author)
    }

    @Test("Empty block set is the identity")
    func emptyIsIdentity() {
        let lines = [line("a"), line("b")]
        #expect(BlockFilter.apply(lines: lines, blockedIds: []) == lines)
    }

    @Test("Removes every line from a blocked author, any kind")
    func removesBlockedAuthorAllKinds() {
        let lines = [
            line("a"),
            line("villain"),
            line("villain", kind: .raidBubble(.init())),
            line("b"),
        ]
        let result = BlockFilter.apply(lines: lines, blockedIds: ["villain"])
        #expect(result.map(\.authorUserId) == ["a", "b"])
    }

    @Test("Lines from non-blocked authors pass through")
    func keepsUnblocked() {
        let lines = [line("a"), line("b")]
        #expect(BlockFilter.apply(lines: lines, blockedIds: ["villain"]) == lines)
    }
}
```
> If `ChatLine`/`ChatLine.Kind`/`RaidBubble`'s memberwise init differs, adjust the `line(...)` helper to match `ChatLine`'s actual initializer (it has defaulted params — `authorUserId` is one of them). The test only needs lines that differ by `authorUserId` and kind.

- [ ] **Step 2: Run the test, verify it fails**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test --filter BlockFilter 2>&1 | tail -12
```
Expected: FAIL — `cannot find 'BlockFilter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Features/Sources/Features/Chat/BlockFilter.swift`:
```swift
import ChatModel

/// Pure, kind-agnostic chat-line filter for blocked users.
///
/// Keys solely on `ChatLine.authorUserId`, which the Normalizer populates for
/// every line kind — so a blocked user's messages AND their sub/raid bubbles all
/// drop with one predicate, no per-kind special-casing. Static + pure so it's
/// unit-testable without a model or view.
enum BlockFilter {
    static func apply(lines: [ChatLine], blockedIds: Set<String>) -> [ChatLine] {
        guard !blockedIds.isEmpty else { return lines }
        return lines.filter { !blockedIds.contains($0.authorUserId) }
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test --filter BlockFilter 2>&1 | tail -12
```
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/Chat/BlockFilter.swift Packages/Features/Tests/FeaturesTests/BlockFilterTests.swift
git commit -m "Features: BlockFilter pure kind-agnostic blocked-author line filter"
```

---

## Task 2: `BlockStore` + `BlockedChatter` model + env key

**Files:**
- Create: `Packages/Features/Sources/Features/Account/BlockStore.swift`
- Test: `Packages/Features/Tests/FeaturesTests/BlockStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Tests/FeaturesTests/BlockStoreTests.swift`:
```swift
import Testing
import Accounts
import SwiftData
@testable import Features

@MainActor
@Suite("BlockStore")
struct BlockStoreTests {
    // A throwaway AccountStore — the tested methods (reconcile/persist/isBlocked)
    // never touch its client, so an in-memory container is enough.
    private func makeStore(suite: String) -> BlockStore {
        let container = try! ModelContainer(
            for: Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let accountStore = AccountStore(modelContainer: container, clientId: "test")
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return BlockStore(accountUserId: "u1", accountStore: accountStore, defaults: defaults)
    }

    @Test("reconcile replaces the set and isBlocked reflects it")
    func reconcileReplaces() {
        let store = makeStore(suite: "block.test.reconcile")
        store.reconcile(with: [BlockedChatter(id: "x", login: "x", displayName: "X")])
        #expect(store.isBlocked("x"))
        #expect(!store.isBlocked("y"))
        store.reconcile(with: [BlockedChatter(id: "y", login: "y", displayName: "Y")])
        #expect(!store.isBlocked("x"))   // replaced, not merged
        #expect(store.isBlocked("y"))
    }

    @Test("persisted set is reloaded by a fresh store on the same defaults")
    func persistenceRoundTrip() {
        let suite = "block.test.persist"
        let store = makeStore(suite: suite)
        store.reconcile(with: [BlockedChatter(id: "x", login: "x", displayName: "X")])

        // A second store on the same suite must load the cached block from init.
        let container = try! ModelContainer(
            for: Account.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let accountStore = AccountStore(modelContainer: container, clientId: "test")
        let reloaded = BlockStore(
            accountUserId: "u1",
            accountStore: accountStore,
            defaults: UserDefaults(suiteName: suite)!
        )
        #expect(reloaded.isBlocked("x"))
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test --filter BlockStore 2>&1 | tail -12
```
Expected: FAIL — `cannot find 'BlockStore'` / `'BlockedChatter' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Features/Sources/Features/Account/BlockStore.swift`:
```swift
import Observation
import SwiftUI
import Accounts
import Core
import TwitchKit
import os

private let logger = AppLogger.make("Features.BlockStore")

/// One blocked user. Local `Codable` model (TwitchKit's `BlockedUser` is
/// `Decodable`-only, so it can't be persisted) — mapped from `TwitchKit.BlockedUser`
/// at the fetch boundary.
public struct BlockedChatter: Codable, Sendable, Identifiable, Equatable {
    public let id: String          // Twitch user id
    public let login: String
    public let displayName: String

    public init(id: String, login: String, displayName: String) {
        self.id = id
        self.login = login
        self.displayName = displayName
    }
}

/// Per-account, app-wide blocked-user state. Twitch is the source of truth
/// (`load()` fetches the authoritative list); a UserDefaults cache makes blocks
/// apply on next launch before that fetch returns. Mutations are optimistic with
/// rollback. `@Observable` so chat filtering + the Profile screen re-render on change.
@MainActor
@Observable
public final class BlockStore {
    public private(set) var blocked: [BlockedChatter] = []
    public private(set) var blockedIds: Set<String> = []

    private let accountUserId: String
    private let accountStore: AccountStore
    private let defaults: UserDefaults
    private var storageKey: String { "blockedUsers.\(accountUserId)" }

    public init(accountUserId: String, accountStore: AccountStore, defaults: UserDefaults = .standard) {
        self.accountUserId = accountUserId
        self.accountStore = accountStore
        self.defaults = defaults
        loadPersisted()
    }

    public func isBlocked(_ userId: String) -> Bool { blockedIds.contains(userId) }

    /// Seed from Twitch (authoritative), paginating the block list. Keeps the
    /// persisted cache on failure (best-effort).
    public func load() async {
        let client = accountStore.client(forUserId: accountUserId)
        do {
            var fetched: [BlockedChatter] = []
            var cursor: String? = nil
            repeat {
                let page = try await client.api.fetchUserBlockListPage(broadcasterID: accountUserId, after: cursor)
                fetched.append(contentsOf: page.data.map {
                    BlockedChatter(id: $0.userId, login: $0.userLogin, displayName: $0.displayName)
                })
                cursor = page.pagination?.cursor
            } while cursor != nil
            reconcile(with: fetched)
        } catch {
            logger.debug("Block-list fetch failed for \(self.accountUserId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Block (optimistic). `reason` doubles as the report reason.
    public func block(userId: String, login: String, displayName: String, reason: UserBlockReason) async {
        guard !blockedIds.contains(userId) else { return }
        insert(BlockedChatter(id: userId, login: login, displayName: displayName))
        do {
            try await accountStore.client(forUserId: accountUserId).api.blockUser(
                targetUserID: userId, sourceContext: .chat, reason: reason
            )
        } catch {
            remove(id: userId)   // rollback
            logger.error("block \(userId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unblock (optimistic).
    public func unblock(userId: String) async {
        guard let existing = blocked.first(where: { $0.id == userId }) else { return }
        remove(id: userId)
        do {
            try await accountStore.client(forUserId: accountUserId).api.unblockUser(targetUserID: userId)
        } catch {
            insert(existing)     // rollback
            logger.error("unblock \(userId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Synchronous state ops (unit-tested)

    /// Replace the whole set with an authoritative list and persist.
    func reconcile(with fetched: [BlockedChatter]) {
        blocked = fetched.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        blockedIds = Set(fetched.map(\.id))
        persist()
    }

    private func insert(_ user: BlockedChatter) {
        guard !blockedIds.contains(user.id) else { return }
        blocked.append(user)
        blocked.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        blockedIds.insert(user.id)
        persist()
    }

    private func remove(id: String) {
        blocked.removeAll { $0.id == id }
        blockedIds.remove(id)
        persist()
    }

    private func loadPersisted() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([BlockedChatter].self, from: data) else { return }
        blocked = decoded
        blockedIds = Set(decoded.map(\.id))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(blocked) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Environment plumbing (mirrors GlobalCatalog's Optional/RootView-injected shape)

private struct BlockStoreKey: EnvironmentKey {
    static let defaultValue: BlockStore? = nil
}

public extension EnvironmentValues {
    /// App-wide blocked-user store for the active account. Injected by RootView.
    /// `nil` outside a RootView ancestor (e.g. previews) — treat absence as
    /// "nothing blocked."
    var blockStore: BlockStore? {
        get { self[BlockStoreKey.self] }
        set { self[BlockStoreKey.self] = newValue }
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test --filter BlockStore 2>&1 | tail -12
```
Expected: PASS — 2 tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/Account/BlockStore.swift Packages/Features/Tests/FeaturesTests/BlockStoreTests.swift
git commit -m "Features: BlockStore (per-account block set + persistence + env key)"
```

---

## Task 3: RootView owns + seeds + injects `BlockStore`

**Files:**
- Modify: `Packages/Features/Sources/Features/App/RootView.swift` (state ~line 37; launch `.task`s ~line 139–145; environment injections ~line 95–97)

- [ ] **Step 1: Add the store as state**

Near `@State private var globalCatalog = GlobalCatalog()` (~line 37), add:
```swift
        // Per-active-account blocked-user store. Re-created when the active
        // account changes (the .id below / @State identity). Seeded in a launch
        // .task and injected via the environment, like globalCatalog.
        @State private var blockStore: BlockStore?
```
> `BlockStore` needs the `accountStore` + the active userId, neither available at property-initializer time, so it's an `Optional` created in the seeding task (Step 3), not a default-constructed `@State`.

- [ ] **Step 2: Inject it into the environment**

Near `.environment(\.globalCatalog, globalCatalog)` (~line 95), add:
```swift
        .environment(\.blockStore, blockStore)
```

- [ ] **Step 3: Create + seed it in a launch task**

After the existing `.task(id: activeAccount?.userId)` blocks (~line 145), add a sibling:
```swift
        // Create the active account's BlockStore (loads its persisted cache in
        // init) and seed it from Twitch's authoritative block list. `.task(id:)`
        // re-fires on account swap, replacing the store for the new account.
        .task(id: activeAccount?.userId) {
            guard let active = activeAccount else {
                blockStore = nil
                return
            }
            let store = BlockStore(accountUserId: active.userId, accountStore: accountStore)
            blockStore = store
            await store.load()
        }
```

- [ ] **Step 4: Build**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/App/RootView.swift
git commit -m "Features: RootView owns + seeds + injects BlockStore for active account"
```

---

## Task 4: `TabChatModel` filters `lines` via `BlockFilter`

**Files:**
- Modify: `Packages/Features/Sources/Features/Chat/TabChatModel.swift` (the `lines` property ~line 56; wherever `lines` is assigned — the `apply`/build path)

The model must expose blocked-filtered `lines` and re-filter when either new events arrive OR the blocked set changes. Approach: store the unfiltered lines privately, expose a filtered `lines`, and hold the current `blockedIds` (pushed in by the view, which observes `BlockStore`).

- [ ] **Step 1: Add a blocked-ids input + private unfiltered store**

Find the `public private(set) var lines: [ChatLine] = []` (~line 56). Replace it with a private backing store + a filtered public projection, and add a settable blocked set:
```swift
    /// All lines before block-filtering. The public `lines` is this filtered by
    /// `blockedIds`.
    private var allLines: [ChatLine] = []

    /// Blocked user ids, pushed in by the view (which observes BlockStore).
    /// Changing it re-filters `lines` immediately.
    public var blockedIds: Set<String> = [] {
        didSet { guard oldValue != blockedIds else { return }; rebuildLines() }
    }

    /// Block-filtered, display-ready lines. Drives the SwiftUI/diffable list.
    public private(set) var lines: [ChatLine] = []

    private func rebuildLines() {
        lines = BlockFilter.apply(lines: allLines, blockedIds: blockedIds)
    }
```

- [ ] **Step 2: Route existing `lines` writes through `allLines` + rebuild**

Find every place the model assigns to `lines` (the snapshot/apply path that builds the displayed list from session events). Change those assignments to write `allLines` then call `rebuildLines()`. For example, an assignment like:
```swift
        lines = rebuilt
```
becomes:
```swift
        allLines = rebuilt
        rebuildLines()
```
> Search the file for `lines = ` to find each write site (the apply/snapshot builder). There is typically one primary builder. Do NOT change reads of `lines` (the view/diff consumes the filtered projection).

- [ ] **Step 3: Push the blocked set in from the view**

In `ChatScreen` (`…/Chat/ChatScreen.swift`), where it reads the model + environment, add an observer that copies the BlockStore's ids into the model. Near the other `.onChange`/`.task` modifiers on the chat container, add:
```swift
        // Keep the model's block filter in sync with the active account's
        // BlockStore. `blockStore` is @Observable, so reading `.blockedIds` here
        // re-fires this onChange whenever a block/unblock mutates the set.
        .onChange(of: blockStore?.blockedIds ?? []) { _, ids in
            chatModel.blockedIds = ids
        }
        .task(id: blockStore?.blockedIds) {
            chatModel.blockedIds = blockStore?.blockedIds ?? []   // seed on appear
        }
```
> `ChatScreen` already has `@Environment(\.globalCatalog)` etc. (~line 130); add `@Environment(\.blockStore) private var blockStore` alongside.

- [ ] **Step 4: Build**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 5: Run the existing chat tests (no regressions)**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test 2>&1 | grep -E "Test run with|failed" | tail -3
```
Expected: all pass (BlockFilter + BlockStore + existing reply/diff tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/Chat/TabChatModel.swift Packages/Features/Sources/Features/Chat/ChatScreen.swift
git commit -m "Features: filter chat lines by BlockStore reactively in TabChatModel"
```

---

## Task 5: `ChatRow` Block + Report… items + ChatScreen wiring

**Files:**
- Modify: `Packages/Features/Sources/Features/Chat/ChatRow.swift` (callback props ~line 35–48; `.contextMenu` `if case .message` block ~line 96)
- Modify: `Packages/Features/Sources/Features/Chat/ChatScreen.swift` (each `ChatRow(...)` chat-list call site ~line 515 / 547; add report-confirmation pill state + overlay)

- [ ] **Step 1: Add the callback props to ChatRow**

Near `onDelete` (~line 48) add:
```swift
    /// Called when the user picks "Block" from the long-press menu. nil hides the
    /// item (ChatScreen passes nil for the current user's own messages).
    var onBlock: (() -> Void)? = nil
    /// Called when the user picks a reason from "Report…". Same nil-hides rule.
    var onReport: ((UserBlockReason) -> Void)? = nil
```
> Add `import TwitchKit` at the top of `ChatRow.swift` if not already present (for `UserBlockReason`).

- [ ] **Step 2: Add the menu items**

Inside the `.contextMenu { if case .message = line.kind { … } }`, after the `onDelete` button, add:
```swift
                    if let onBlock {
                        Button(role: .destructive) {
                            onBlock()
                        } label: {
                            Label("Block", systemImage: "hand.raised")
                        }
                    }
                    if let onReport {
                        // Report = block-with-reason (Twitch has no separate
                        // report API). The reasons map to UserBlockReason.
                        Menu {
                            Button("Harassment") { onReport(.harassment) }
                            Button("Spam") { onReport(.spam) }
                        } label: {
                            Label("Report…", systemImage: "exclamationmark.bubble")
                        }
                    }
```

- [ ] **Step 3: Wire ChatScreen — add report-confirmation state**

In `ChatScreen`'s `@State` block (near the connection-pill state), add:
```swift
    /// Brief "Reported & blocked" confirmation; auto-clears after ~2s.
    @State private var showReportConfirmation = false
    @State private var reportConfirmationDismiss: Task<Void, Never>?
```

- [ ] **Step 4: Wire ChatScreen — pass the callbacks (own-message guarded)**

At each `ChatRow(...)` call site that renders live chat-list rows (~line 515 and ~line 547), alongside `onReply:`/`onDelete:`, add:
```swift
                        onBlock: line.authorUserId == account.userId ? nil : {
                            Task {
                                await blockStore?.block(
                                    userId: line.authorUserId,
                                    login: line.authorLogin,
                                    displayName: line.authorDisplayName,
                                    reason: .other
                                )
                            }
                        },
                        onReport: line.authorUserId == account.userId ? nil : { reason in
                            Task {
                                await blockStore?.block(
                                    userId: line.authorUserId,
                                    login: line.authorLogin,
                                    displayName: line.authorDisplayName,
                                    reason: reason
                                )
                                showReportConfirmation = true
                                reportConfirmationDismiss?.cancel()
                                reportConfirmationDismiss = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(2))
                                    guard !Task.isCancelled else { return }
                                    showReportConfirmation = false
                                }
                            }
                        },
```
> `ChatLine` exposes `authorUserId`, `authorDisplayName` (confirmed). For `authorLogin`: if `ChatLine` has no `authorLogin`, pass `line.authorDisplayName` for both `login` and `displayName` (the block list still works by id; the login is only cosmetic in the Profile screen). Verify `ChatLine`'s available author fields and use the login if present, else fall back. `account` is `ChatScreen`'s stored `Account` (so `account.userId` is the current user).

- [ ] **Step 5: Wire ChatScreen — the confirmation pill**

Add a computed view near `connectionPill`:
```swift
    @ViewBuilder
    private var reportConfirmationPill: some View {
        if showReportConfirmation {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield").font(.caption2.weight(.semibold))
                Text("Reported & blocked").font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
```
And overlay it on the chat container (sibling to the connection pill's `.overlay(alignment: .top)`):
```swift
        .overlay(alignment: .top) {
            reportConfirmationPill
                .padding(.top, 8)
                .animation(.snappy, value: showReportConfirmation)
        }
```

- [ ] **Step 6: Build the package + app**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build 2>&1 | tail -5
cd /Users/landy/Dev/chattr && xcodebuild -scheme chattr -destination 'platform=iOS Simulator,id=54AA7091-7412-44AA-8936-015E77324873' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```
Expected: `Build complete!` then `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/Chat/ChatRow.swift Packages/Features/Sources/Features/Chat/ChatScreen.swift
git commit -m "Features: Block + Report context-menu actions wired to BlockStore"
```

---

## Task 6: `BlockedUsersScreen` + Profile link

**Files:**
- Create: `Packages/Features/Sources/Features/Account/BlockedUsersScreen.swift`
- Modify: `Packages/Features/Sources/Features/Account/ProfileScreen.swift` (a Section + NavigationLink, mirroring the `HighlightKeywordsScreen` link ~line 120)

- [ ] **Step 1: Create the screen**

Create `Packages/Features/Sources/Features/Account/BlockedUsersScreen.swift`:
```swift
import SwiftUI

/// Manage the active account's blocked users. The only place to unblock —
/// blocked users' messages are hidden in chat, so there's no row to long-press.
struct BlockedUsersScreen: View {
    @Environment(\.blockStore) private var blockStore

    var body: some View {
        Group {
            if let blockStore, !blockStore.blocked.isEmpty {
                List {
                    ForEach(blockStore.blocked) { user in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName).font(.body)
                                Text("@\(user.login)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unblock") {
                                Task { await blockStore.unblock(userId: user.id) }
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Blocked Users",
                    systemImage: "hand.raised",
                    description: Text("Block someone from a chat message's long-press menu and they'll appear here.")
                )
            }
        }
        .navigationTitle("Blocked Users")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
```

- [ ] **Step 2: Add the Profile link**

In `ProfileScreen.swift`, near the `NavigationLink { HighlightKeywordsScreen() }` (~line 120), add a sibling link (in the same or an adjacent `Section`):
```swift
                NavigationLink {
                    BlockedUsersScreen()
                } label: {
                    Label("Blocked Users", systemImage: "hand.raised")
                }
```
> Match the exact `Label`/row style of the adjacent `HighlightKeywordsScreen` link in that file.

- [ ] **Step 3: Build the package + app**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift build 2>&1 | tail -5
cd /Users/landy/Dev/chattr && xcodebuild -scheme chattr -destination 'platform=iOS Simulator,id=54AA7091-7412-44AA-8936-015E77324873' build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | head
```
Expected: `Build complete!` then `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/landy/Dev/chattr
git add Packages/Features/Sources/Features/Account/BlockedUsersScreen.swift Packages/Features/Sources/Features/Account/ProfileScreen.swift
git commit -m "Features: Blocked Users management screen + Profile link"
```

---

## Task 7: Full verification

**Files:** none.

- [ ] **Step 1: Run the touched-package test suite**

Run:
```bash
cd /Users/landy/Dev/chattr/Packages/Features && swift test 2>&1 | grep -E "Test run with|failed" | tail -3
```
Expected: all pass (incl. `BlockFilter` + `BlockStore`).

- [ ] **Step 2: Manual — block hides immediately**

Launch on a device/simulator, open a busy channel. Long-press another user's message → **Block**. Their message (and any of their other messages/bubbles on screen) vanish immediately; new ones from them never appear.

- [ ] **Step 3: Manual — report**

Long-press a message → **Report… → Harassment**. The user is blocked (messages vanish) and a brief **"Reported & blocked"** glass pill appears at the top, auto-dismissing after ~2s.

- [ ] **Step 4: Manual — own-message guard**

Long-press one of *your own* messages: no Block/Report items appear (only Reply/Thread).

- [ ] **Step 5: Manual — Profile management + persistence**

Profile → **Blocked Users**: the blocked users are listed. **Unblock** one → their future messages show again. Force-quit + relaunch → the still-blocked users remain hidden from the first frame (persisted cache), and the list survives.

---

## Self-Review (completed by plan author)

- **Spec coverage:** `BlockFilter` (kind-agnostic) → Task 1; `BlockStore` (model, persistence, optimistic block/unblock, Twitch-authoritative `load`, env key) → Task 2; RootView own/seed/inject → Task 3; reactive `lines` filtering → Task 4; ChatRow Block + Report… + own-message guard + report confirmation pill → Task 5; `BlockedUsersScreen` + Profile link → Task 6; manual end-to-end → Task 7. EULA/contact is out of scope per the spec and intentionally absent.
- **Type consistency:** `BlockFilter.apply(lines:blockedIds:)`, `BlockedChatter{id,login,displayName}`, `BlockStore.{blocked,blockedIds,isBlocked,load,block,unblock,reconcile}`, `\.blockStore`, `onBlock`/`onReport`, `UserBlockReason.{harassment,spam,other}` — used identically across tasks and match TwitchKit 0.3.0.
- **No placeholders:** every code step shows complete code; run steps show commands + expected output. The one genuinely conditional spot (`ChatLine`'s author-login field name) is flagged with an explicit fallback in Task 5 Step 4, not left vague.
- **Known verify-at-implementation points (flagged inline, not placeholders):** `ChatLine`'s memberwise init in the Task 1 test helper; the exact `lines = ` write sites in Task 4 Step 2; `ChatLine`'s author-login field in Task 5.
