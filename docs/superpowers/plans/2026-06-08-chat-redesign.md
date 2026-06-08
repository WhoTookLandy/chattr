# Chat Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the second-screen chat surface own the screen — remove the `TabView` + `Chat` title, drive navigation from a toolbar header (avatar → Profile, name → open-chats switcher, grid → Follows), keep native swipe-paging between open chats, and fix message-row wrapping/readability.

**Architecture:** `AppShell` drops the bottom `TabView` and renders the chat surface as the app root. `ChatTabsScreen` keeps its existing native paging (`ScrollView(.horizontal)` + `.scrollTargetBehavior(.paging)`) but replaces the `Chat` title + `ChatTabStrip` with a `.toolbar` header bound to the active page, plus page-dots. A new `ChannelSwitcherView` sheet lists open chats (reorder/close/add). Follows and Profile become sheets. `FlowLayout` gains a testable hanging-indent so wrapped message bodies align under the text instead of the badges.

**Tech Stack:** SwiftUI (iOS 26), Swift Testing, SwiftPM packages (`Packages/Features`). Liquid Glass via `.glassEffect`/`GlassEffectContainer`/`.safeAreaBar`.

**Spec:** `docs/superpowers/specs/2026-06-08-chat-redesign-design.md`

---

## Conventions for this plan

- **Test command (logic tasks):** `swift test --package-path Packages/Features --filter <SuiteOrTest>`
  - If the Features package can't build for the host (iOS-only types), fall back to the app scheme:
    `xcodebuild test -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:FeaturesTests/<Suite>`
- **Build check (view tasks):** `swift build --package-path Packages/Features` (compiles the SwiftUI without running the app).
- **Visual check (view tasks):** Launch the app in the iOS Simulator and confirm the described behavior. Where a task says "Visual verify," that is the acceptance check in lieu of a unit test (SwiftUI view composition isn't unit-testable).
- **Commit after every task.** Branch is already `feat/chat-redesign`.

---

## File Structure

**Phase A — Shell & navigation restructure**
- Modify `Packages/Features/Sources/Features/Tabs/ChatTabsModel.swift` — add `move(fromOffsets:toOffset:)` reorder + persist.
- Modify `Packages/Features/Sources/Features/App/AppShell.swift` — remove `TabView`; render `ChatTabsScreen` as root; own Profile/Follows/switcher sheet state isn't here (moves to `ChatTabsScreen`). Keep model/persistence wiring + `openChannel`.
- Modify `Packages/Features/Sources/Features/Tabs/ChatTabsScreen.swift` — wrap in one `NavigationStack`; remove `navigationTitle("Chat")` + `ChatTabStrip`; add toolbar header (avatar/principal/grid) bound to active tab; add page-dots; own the switcher + Follows + Profile sheets.

**Phase B — Channel switcher**
- Create `Packages/Features/Sources/Features/Tabs/ChannelSwitcherView.swift` — sheet listing open chats with reorder/close + "Browse Follows."

**Phase C — Row readability**
- Create `Packages/Features/Sources/Features/Shared/FlowLayoutEngine.swift` — pure, testable geometry with hanging-indent.
- Create `Packages/Features/Tests/FeaturesTests/FlowLayoutEngineTests.swift` — unit tests.
- Modify `Packages/Features/Sources/Features/Shared/FlowLayout.swift` — delegate to the engine; expose `hangingIndent`.
- Modify `Packages/Features/Sources/Features/Chat/ChatRow.swift` — pass a hanging indent to the message-body `FlowLayout`; add inter-message vertical rhythm.

**Phase D — Compose bar refinement**
- Modify `Packages/Features/Sources/Features/Chat/ChatScreen.swift` — pin compose via `.safeAreaBar(.bottom)`; wrap the input row in `GlassEffectContainer`.

**Deferred (needs product input — see "Open Questions"):** detection/styling of *bot-posted* event announcements (Fossabot gift/raid text). Genuine EventSub sub/raid/system events already render as styled bubbles (`SubBubbleRow`/`RaidBubbleRow`/`SystemBubbleRow`); bot-posted text is indistinguishable from chat without a fragile per-bot heuristic.

---

## Phase A — Shell & navigation restructure

### Task A1: Add reorder to `ChatTabsModel`

The switcher's drag-to-reorder needs a model method that also persists and keeps `activeTabId` valid.

**Files:**
- Modify: `Packages/Features/Sources/Features/Tabs/ChatTabsModel.swift`
- Test: `Packages/Features/Tests/FeaturesTests/ChatTabsModelMoveTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Tests/FeaturesTests/ChatTabsModelMoveTests.swift`:

```swift
import Testing
import Foundation
@testable import Features

@MainActor
@Suite("ChatTabsModel.move")
struct ChatTabsModelMoveTests {
    private func channel(_ name: String) -> ChannelDescriptor {
        ChannelDescriptor(
            channelId: name, channelLoginName: name,
            channelDisplayName: name, profileImageURL: nil
        )
    }

    @Test("Moving a tab reorders the tabs array")
    func reorders() {
        let model = ChatTabsModel()
        model.open(channel: channel("a"))
        model.open(channel: channel("b"))
        model.open(channel: channel("c"))
        // tabs: a, b, c — move c (index 2) to front (offset 0)
        model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.tabs.map { $0.channels[0].channelLoginName } == ["c", "a", "b"])
    }

    @Test("Reordering preserves the active selection")
    func preservesActive() {
        let model = ChatTabsModel()
        model.open(channel: channel("a"))
        let bId = model.open(channel: channel("b"))
        model.open(channel: channel("c"))
        model.activeTabId = bId
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 3) // a to end
        #expect(model.activeTabId == bId)
        #expect(model.tabs.map { $0.channels[0].channelLoginName } == ["b", "c", "a"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/Features --filter ChatTabsModelMoveTests`
Expected: FAIL — `value of type 'ChatTabsModel' has no member 'move'`.

- [ ] **Step 3: Implement `move`**

In `ChatTabsModel.swift`, add after the `close(tabId:)` method (before the closing brace of the `// MARK: - Close` section):

```swift
    // MARK: - Reorder

    /// Reorders open tabs (drag-to-reorder in the channel switcher). Mirrors
    /// `Array.move(fromOffsets:toOffset:)` semantics so it can back an
    /// `.onMove` in a SwiftUI `List`/`ForEach`. Persists the new order;
    /// `activeTabId` is unaffected because it tracks identity, not index.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
        persistTabs()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/Features --filter ChatTabsModelMoveTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Sources/Features/Tabs/ChatTabsModel.swift Packages/Features/Tests/FeaturesTests/ChatTabsModelMoveTests.swift
git commit -m "feat(tabs): add reorder to ChatTabsModel for channel switcher

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task A2: Remove the `TabView` from `AppShell`

`AppShell` stops being a three-tab container and renders the chat surface as the root. It keeps owning `ChatTabsModel`, the `onOpen`/`onClose`/persistence wiring, and the `openChannel` action. Follows/Profile presentation moves into `ChatTabsScreen` (Task A3), so `AppShell` passes `clientId` down and no longer needs `selectedTab` or the `onAddTab → Follows` hop.

**Files:**
- Modify: `Packages/Features/Sources/Features/App/AppShell.swift`

- [ ] **Step 1: Replace the `body`'s `TabView` with the chat root**

In `AppShell.swift`, replace the `selectedTab` state and the entire `TabView(selection:) { … }` block (the three `Tab(...)` entries) with a single root. Change the stored properties first — delete:

```swift
    @State private var selectedTab: AppTab = .follows
```

and delete the `AppTab` enum (no longer needed):

```swift
    enum AppTab: Hashable, Sendable {
        case follows, chat, profile
    }
```

- [ ] **Step 2: Rewrite `body` to render `ChatTabsScreen` as root**

Replace the `TabView { … }` expression (everything from `TabView(selection: $selectedTab) {` through its closing `}` that precedes `.environment(\.chatTabs, chatTabsModel)`) with:

```swift
        ChatTabsScreen(
            account: account,
            accountStore: accountStore,
            clientId: clientId
        )
```

Then update the `openChannel` action body — it previously set `selectedTab = .chat`. Remove that line (there is no tab to switch to now). The action becomes:

```swift
        .environment(\.openChannel, OpenChannelAction { channelId, login, displayName, profileImageURL in
            let descriptor = ChannelDescriptor(
                channelId: channelId,
                channelLoginName: login,
                channelDisplayName: displayName,
                profileImageURL: profileImageURL
            )
            chatTabsModel.open(channel: descriptor)
        })
```

Leave the `.environment(\.chatTabs, chatTabsModel)` modifier and the entire `.task { … }` (callback wiring + persistence hydration) unchanged.

- [ ] **Step 3: Build**

Run: `swift build --package-path Packages/Features`
Expected: a compile error in `ChatTabsScreen` (its `init` doesn't yet take `clientId`, and `onAddTab` was removed). That's fixed in Task A3 — proceed.

- [ ] **Step 4: Commit (after A3 builds)**

This task does not build standalone because `ChatTabsScreen`'s signature changes in A3. Implement A3 Steps 1–3, then build, then commit A2 + A3 together (see A3 Step 6).

---

### Task A3: Toolbar header + page-dots in `ChatTabsScreen`

Replace the `Chat` title and `ChatTabStrip` with a `.toolbar` header on a single `NavigationStack`. The header reflects the **active** tab (stable items, conditional labels). Add page-dots and own the three sheets (switcher, Follows, Profile). `ChannelSwitcherView` is built in Phase B — for now wire the principal button to a `showSwitcher` state and present a placeholder so this task builds and is visually verifiable.

**Files:**
- Modify: `Packages/Features/Sources/Features/Tabs/ChatTabsScreen.swift`

- [ ] **Step 1: Add `clientId` + sheet state, drop `onAddTab`**

In `ChatTabsScreen`, replace the stored `onAddTab` property and `init` with `clientId` + sheet state. Replace:

```swift
    /// Called when the user taps the "+" button on the tab strip. AppShell
    /// wires this to "switch the TabView selection to Follows."
    private let onAddTab: () -> Void
```

with:

```swift
    /// Twitch client id, forwarded to the Profile sheet's account switcher.
    private let clientId: String

    @State private var showSwitcher = false
    @State private var showFollows = false
    @State private var showProfile = false
```

Replace the `init`:

```swift
    public init(
        account: Account,
        accountStore: AccountStore,
        clientId: String
    ) {
        self.account = account
        self.accountStore = accountStore
        self.clientId = clientId
    }
```

- [ ] **Step 2: Add imports for the sheets**

At the top of the file, add:

```swift
import Channels
```

(The file already imports `SwiftUI` and `Accounts`. `Channels` is needed for `ChannelListScreen`; `ProfileScreen` is in the same `Features` module so needs no import.)

- [ ] **Step 3: Rewrite `body` — NavigationStack + toolbar + page-dots + sheets**

Replace the entire `body` with:

```swift
    public var body: some View {
        NavigationStack {
            Group {
                if let chatTabs, !chatTabs.tabs.isEmpty {
                    VStack(spacing: 0) {
                        pagedChatContent(chatTabs: chatTabs)
                        pageDots(chatTabs: chatTabs)
                    }
                    .onAppear {
                        if let savedId = persistedActiveTabId,
                           let uuid = UUID(uuidString: savedId),
                           chatTabs.tabs.contains(where: { $0.id == uuid }) {
                            chatTabs.activeTabId = uuid
                        }
                    }
                    .onChange(of: chatTabs.activeTabId) { _, newValue in
                        persistedActiveTabId = newValue?.uuidString
                    }
                } else {
                    emptyState
                }
            }
            .toolbar { headerToolbar(chatTabs: chatTabs) }
            .toolbarTitleDisplayMode(.inline)
        }
        // Open-chats switcher (placeholder until Phase B).
        .sheet(isPresented: $showSwitcher) {
            if let chatTabs {
                ChannelSwitcherView(
                    model: chatTabs,
                    onBrowseFollows: {
                        showSwitcher = false
                        showFollows = true
                    }
                )
            }
        }
        // Follows browse — its own NavigationStack inside the sheet.
        .sheet(isPresented: $showFollows) {
            NavigationStack {
                ChannelListScreen(account: account, accountStore: accountStore)
            }
        }
        // Profile / settings — its own NavigationStack inside the sheet.
        .sheet(isPresented: $showProfile) {
            NavigationStack {
                ProfileScreen(account: account, accountStore: accountStore, clientId: clientId)
            }
        }
    }

    /// The toolbar header. Three STABLE items whose labels reflect the
    /// active tab — never inserted/removed conditionally (that would rebuild
    /// the bar and flicker; see axiom toolbars guidance).
    @ToolbarContentBuilder
    private func headerToolbar(chatTabs: ChatTabsModel?) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showProfile = true } label: {
                Image(systemName: "person.crop.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Profile")
        }
        ToolbarItem(placement: .principal) {
            Button { showSwitcher = true } label: {
                HStack(spacing: 5) {
                    Text(activeTabTitle(chatTabs: chatTabs))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Switch channel")
            .disabled(chatTabs?.tabs.isEmpty ?? true)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showFollows = true } label: {
                Image(systemName: "square.grid.2x2")
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("Follows")
        }
    }

    /// Title for the principal item — the active tab's display name, or a
    /// neutral fallback when nothing is open.
    private func activeTabTitle(chatTabs: ChatTabsModel?) -> String {
        guard let chatTabs,
              let activeId = chatTabs.activeTabId,
              let tab = chatTabs.tabs.first(where: { $0.id == activeId })
        else { return "Chat" }
        return tab.displayName
    }

    /// Page-dots under the transcript — one per open tab, active highlighted.
    /// Hidden for a single tab (no switching to indicate).
    @ViewBuilder
    private func pageDots(chatTabs: ChatTabsModel) -> some View {
        if chatTabs.tabs.count > 1 {
            HStack(spacing: 6) {
                ForEach(chatTabs.tabs) { tab in
                    Circle()
                        .fill(tab.id == chatTabs.activeTabId ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityHidden(true)
        }
    }
```

- [ ] **Step 4: Update `emptyState` to open Follows**

Replace the `emptyState`'s button (which called `onAddTab()`):

```swift
            Button("Go to Follows") {
                showFollows = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
```

- [ ] **Step 5: Remove the obsolete `navigationTitle`/strip and the stale doc comment**

Confirm the old `ChatTabStrip(model:onAddTab:)` call and the `.navigationTitle("Chat")` / `.toolbarTitleDisplayMode(.inline)` that lived on the old `Group` are gone (they're replaced by Step 3's body). `ChatTabStrip.swift` itself stays in the repo for now (unused) — removing it is a cleanup left to the end (Task A6).

> **Note:** `ChannelSwitcherView` doesn't exist yet — this task will not build until Phase B Task B1 is done. Implement B1 now, then return to build/commit. (If executing strictly in order, treat A3+B1 as a pair.)

- [ ] **Step 6: Build A2 + A3 + B1 together, then commit**

Run: `swift build --package-path Packages/Features`
Expected: PASS once B1 exists.

Then commit:

```bash
git add Packages/Features/Sources/Features/App/AppShell.swift Packages/Features/Sources/Features/Tabs/ChatTabsScreen.swift
git commit -m "feat(chat): chat-as-home shell with toolbar header + page dots

Removes the Follows/Chat/Profile TabView and the Chat title + tab strip.
Chat is the root; a toolbar header drives nav (avatar -> Profile,
name -> switcher, grid -> Follows); page-dots indicate open chats.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 7: Visual verify**

Launch in the simulator. Confirm: no bottom tab bar; no "Chat" title; header shows avatar (left), channel name + chevron (center), grid (right); tapping avatar opens Profile sheet; tapping grid opens Follows sheet; swiping still switches chats and the header name + active page-dot update.

---

### Task A6: Remove the now-unused `ChatTabStrip` (cleanup)

**Files:**
- Delete: `Packages/Features/Sources/Features/Tabs/ChatTabStrip.swift`

- [ ] **Step 1: Confirm no references**

Run: `grep -rn "ChatTabStrip" Packages/Features/Sources`
Expected: no matches (Task A3 removed the only call site).

- [ ] **Step 2: Delete the file and build**

```bash
git rm Packages/Features/Sources/Features/Tabs/ChatTabStrip.swift
swift build --package-path Packages/Features
```
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore(chat): remove unused ChatTabStrip after header redesign

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase B — Channel switcher

### Task B1: `ChannelSwitcherView`

A sheet listing the open chats (the swipe order) with drag-to-reorder, swipe/close, tap-to-activate, and a "Browse Follows" footer. Uses `ChatTabsModel.move` (A1) and `close`.

**Files:**
- Create: `Packages/Features/Sources/Features/Tabs/ChannelSwitcherView.swift`

- [ ] **Step 1: Create the view**

```swift
import SwiftUI

/// Lightweight switcher over the user's OPEN chats — the horizontal swipe
/// order made explicit and editable. Distinct from Follows (the full browse
/// experience): this lists only what's already open. Reorder here defines
/// the swipe order; ✕ closes a chat; tapping a row activates it and dismisses.
struct ChannelSwitcherView: View {
    @Bindable var model: ChatTabsModel
    /// Invoked by the footer button — the parent dismisses this sheet and
    /// presents the Follows browse sheet.
    let onBrowseFollows: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Open chats") {
                    ForEach(model.tabs) { tab in
                        Button {
                            model.activeTabId = tab.id
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(tab.displayName)
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if tab.id == model.activeTabId {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onMove { source, destination in
                        model.move(fromOffsets: source, toOffset: destination)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            model.close(tabId: model.tabs[index].id)
                        }
                    }
                }
            }
            .navigationTitle("Channels")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onBrowseFollows) {
                    Label("Browse Follows to add a chat", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .padding()
            }
        }
        .presentationDetents([.medium, .large])
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --package-path Packages/Features`
Expected: builds (this is the missing symbol from A3; the whole Phase-A surface now compiles).

- [ ] **Step 3: Commit**

(Committed together with A2/A3 in Task A3 Step 6 if executed as a pair; otherwise:)

```bash
git add Packages/Features/Sources/Features/Tabs/ChannelSwitcherView.swift
git commit -m "feat(chat): open-chats switcher sheet (reorder/close/add)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 4: Visual verify**

Open ≥2 chats. Tap the channel name → switcher appears listing open chats with a checkmark on the active one. Tap a row → it activates and the sheet dismisses (paged view snaps to it). Tap Edit → drag to reorder (swipe order changes) and delete a row (chat closes). Tap "Browse Follows…" → switcher dismisses and Follows opens.

---

## Phase C — Row readability (hanging indent)

### Task C1: Pure `FlowLayoutEngine` with hanging indent (TDD)

Extract `FlowLayout`'s geometry into a pure, testable engine that computes child origins + total size from `[CGSize]`, with a `hangingIndent` applied to every wrapped (non-first) row.

**Files:**
- Create: `Packages/Features/Sources/Features/Shared/FlowLayoutEngine.swift`
- Test: `Packages/Features/Tests/FeaturesTests/FlowLayoutEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Packages/Features/Tests/FeaturesTests/FlowLayoutEngineTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import Features

@Suite("FlowLayoutEngine")
struct FlowLayoutEngineTests {
    @Test("Single row that fits: origins advance by width+spacing, height = tallest")
    func singleRow() {
        let sizes = [CGSize(width: 20, height: 10), CGSize(width: 30, height: 14)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 100, spacing: 4, hangingIndent: 0)
        #expect(r.origins[0].x == 0)
        #expect(r.origins[1].x == 24) // 20 + 4
        #expect(r.size.height == 14)
        #expect(r.origins[0].y == 0)
        #expect(r.origins[1].y == 0)
    }

    @Test("Wrap when an item exceeds the container width")
    func wraps() {
        // Width 50: [40][40] -> second wraps to row 2.
        let sizes = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 10)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 50, spacing: 4, hangingIndent: 0)
        #expect(r.origins[0].y == 0)
        #expect(r.origins[1].y == 14) // 10 + 4 spacing
        #expect(r.origins[1].x == 0)  // no hanging indent
        #expect(r.size.height == 24)  // two rows of 10 + 4 spacing
    }

    @Test("Hanging indent offsets wrapped rows only, not the first row")
    func hangingIndent() {
        let sizes = [CGSize(width: 40, height: 10), CGSize(width: 40, height: 10)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 50, spacing: 4, hangingIndent: 12)
        #expect(r.origins[0].x == 0)   // first row flush
        #expect(r.origins[1].x == 12)  // wrapped row indented
    }

    @Test("A lone over-wide item still places (no infinite wrap)")
    func loneOverwide() {
        let sizes = [CGSize(width: 200, height: 10)]
        let r = FlowLayoutEngine.layout(sizes: sizes, containerWidth: 50, spacing: 4, hangingIndent: 12)
        #expect(r.origins[0].x == 0)
        #expect(r.size.height == 10)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/Features --filter FlowLayoutEngineTests`
Expected: FAIL — `cannot find 'FlowLayoutEngine' in scope`.

- [ ] **Step 3: Implement the engine**

Create `Packages/Features/Sources/Features/Shared/FlowLayoutEngine.swift`:

```swift
import CoreGraphics

/// Pure geometry for `FlowLayout`, extracted so the wrapping math is unit-
/// testable without SwiftUI's `Subviews`/`LayoutSubview`. Computes child
/// origins (top-left, before vertical in-row alignment) and the total size.
///
/// `hangingIndent` shifts every WRAPPED (non-first) row's start x, so a
/// chat message whose body wraps aligns under the text instead of snapping
/// back under the badges.
enum FlowLayoutEngine {
    struct Result {
        var origins: [CGPoint]
        var size: CGSize
    }

    static func layout(
        sizes: [CGSize],
        containerWidth: CGFloat,
        spacing: CGFloat,
        hangingIndent: CGFloat
    ) -> Result {
        var origins: [CGPoint] = []
        origins.reserveCapacity(sizes.count)

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var isFirstRow = true
        var rowStart: CGFloat = 0

        for size in sizes {
            // Wrap if this item overflows AND the row already has content.
            if currentX + size.width > containerWidth, currentX > rowStart {
                currentY += rowHeight + spacing
                rowHeight = 0
                isFirstRow = false
                rowStart = isFirstRow ? 0 : hangingIndent
                currentX = rowStart
            }
            origins.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        let totalHeight = currentY + rowHeight
        return Result(origins: origins, size: CGSize(width: containerWidth, height: totalHeight))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/Features --filter FlowLayoutEngineTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Sources/Features/Shared/FlowLayoutEngine.swift Packages/Features/Tests/FeaturesTests/FlowLayoutEngineTests.swift
git commit -m "feat(layout): pure FlowLayoutEngine with hanging-indent geometry

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C2: Route `FlowLayout` through the engine (behavior-preserving)

Replace `FlowLayout`'s duplicated wrapping math with calls to `FlowLayoutEngine`, keeping `hangingIndent` at 0 so existing rows render identically.

**Files:**
- Modify: `Packages/Features/Sources/Features/Shared/FlowLayout.swift`

- [ ] **Step 1: Add the `hangingIndent` stored property + init param**

Replace the property block + `init`:

```swift
struct FlowLayout: Layout {
    var spacing: CGFloat
    var alignment: VerticalAlignment
    /// Indent applied to every wrapped (non-first) row. 0 = classic flow.
    var hangingIndent: CGFloat
```

```swift
    init(spacing: CGFloat = 4, alignment: VerticalAlignment = .firstTextBaseline, hangingIndent: CGFloat = 0) {
        self.spacing = spacing
        self.alignment = alignment
        self.hangingIndent = hangingIndent
    }
```

- [ ] **Step 2: Replace `sizeThatFits` body to use the engine**

```swift
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        ensureSizes(subviews: subviews, containerWidth: containerWidth, cache: &cache)
        return FlowLayoutEngine.layout(
            sizes: cache.sizes,
            containerWidth: containerWidth,
            spacing: spacing,
            hangingIndent: hangingIndent
        ).size
    }
```

- [ ] **Step 3: Replace `placeSubviews` body to use the engine origins**

```swift
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let containerWidth = bounds.width
        ensureSizes(subviews: subviews, containerWidth: containerWidth, cache: &cache)
        let result = FlowLayoutEngine.layout(
            sizes: cache.sizes,
            containerWidth: containerWidth,
            spacing: spacing,
            hangingIndent: hangingIndent
        )
        // Group origins by row (same y) to apply per-row vertical alignment.
        for (index, subview) in subviews.enumerated() {
            let origin = result.origins[index]
            let size = cache.sizes[index]
            let rowHeight = rowHeightForY(origin.y, origins: result.origins, sizes: cache.sizes)
            let yOffset: CGFloat
            switch alignment {
            case .center: yOffset = (rowHeight - size.height) / 2
            default:      yOffset = rowHeight - size.height // baseline/bottom approx (unchanged)
            }
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y + yOffset),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }

    /// Tallest subview height among those sharing the row at `y`.
    private func rowHeightForY(_ y: CGFloat, origins: [CGPoint], sizes: [CGSize]) -> CGFloat {
        var h: CGFloat = 0
        for (i, o) in origins.enumerated() where o.y == y {
            h = max(h, sizes[i].height)
        }
        return h
    }
```

Delete the now-unused `flushRow`/manual loop that remained in the old `placeSubviews`, and remove the old manual loop in `sizeThatFits` (both replaced above). Keep `makeCache`, `updateCache`, and `ensureSizes` unchanged.

- [ ] **Step 4: Build + run the full Features test suite**

Run: `swift build --package-path Packages/Features`
Run: `swift test --package-path Packages/Features --filter FlowLayoutEngineTests`
Expected: builds; engine tests still PASS.

- [ ] **Step 5: Visual verify (no regression)**

Launch the app. Chat rows render exactly as before (hangingIndent is 0). Multi-line messages still wrap to the left margin (unchanged for now — fixed in C3).

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Sources/Features/Shared/FlowLayout.swift
git commit -m "refactor(layout): route FlowLayout through FlowLayoutEngine

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task C3: Apply hanging indent + vertical rhythm in `ChatRow`

Give the message body a hanging indent so wrapped lines align under the message text, and add a little inter-message spacing for boundary clarity.

**Files:**
- Modify: `Packages/Features/Sources/Features/Chat/ChatRow.swift`
- Modify: `Packages/Features/Sources/Features/Chat/ChatScreen.swift` (legacy `LazyVStack` spacing only)

- [ ] **Step 1: Pass `hangingIndent` to the message-body `FlowLayout`**

In `ChatRow.swift`, in `messageBody`, change the layout constructor:

```swift
        FlowLayout(spacing: 4, alignment: .firstTextBaseline, hangingIndent: 14) {
```

(14pt is roughly one badge-width of indent — enough to visually separate wrapped continuation from the next message's leading edge without a big gutter.)

- [ ] **Step 2: Increase inter-message rhythm**

In `ChatScreen.swift`'s `legacyScrollView`, change the `LazyVStack` spacing from `4` to `6`:

```swift
            LazyVStack(alignment: .leading, spacing: 6) {
```

(The UIKit list path sets its own row spacing in `ChatListView`; if rows there feel tight after this change, mirror the bump in that file — verify visually in Step 3.)

- [ ] **Step 3: Build + visual verify**

Run: `swift build --package-path Packages/Features`
Launch the app, open a busy chat. Confirm: a message long enough to wrap now has its second line **indented** under the body (not flush at the badges), and messages read as distinct blocks. Emote images mid-wrap still align on the row.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/Chat/ChatRow.swift Packages/Features/Sources/Features/Chat/ChatScreen.swift
git commit -m "feat(chat): hanging indent + vertical rhythm for message rows

Wrapped message bodies now align under the text instead of snapping to
the badge margin; slightly more space between messages for clearer
boundaries.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Phase D — Compose bar refinement

### Task D1: `safeAreaBar` compose + `GlassEffectContainer`

Pin the compose bar with iOS 26's `.safeAreaBar(edge: .bottom)` (integrated glass blur) and group its adjacent glass controls in a `GlassEffectContainer`.

**Files:**
- Modify: `Packages/Features/Sources/Features/Chat/ChatScreen.swift`

- [ ] **Step 1: Move the compose bar from the VStack into a `safeAreaBar`**

In `ChatScreen.body`, the current structure is `VStack(spacing: 0) { Group { … content … }; composeBarView }`. Replace it so the content stands alone and the compose bar pins via `safeAreaBar`:

```swift
        Group {
            if let errorMessage {
                errorView(errorMessage)
            } else if chatModel.lines.isEmpty {
                emptyOrConnectingView
            } else {
                chatScrollView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .bottom) {
            composeBarView
        }
```

(Everything attached after the old `VStack` — `.alert`, `.sheet`, the `.task` modifiers — stays attached to this `Group` exactly as before. Only the `VStack` wrapper and the trailing `composeBarView` placement change.)

- [ ] **Step 2: Wrap the compose input row in a `GlassEffectContainer`**

In the `ComposeBar` view's `inputRow`, wrap the `HStack` so the adjacent glass elements (emote `.glass` button, glass text field, `.glassProminent` send) share one container:

```swift
    @ViewBuilder
    private var inputRow: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                // … existing emote button, TextField, send button unchanged …
            }
        }
    }
```

(Leave the contents of the `HStack` exactly as they are — only the `GlassEffectContainer` wrapper is added.)

- [ ] **Step 3: Build + visual verify**

Run: `swift build --package-path Packages/Features`
Launch the app. Confirm: the compose bar still pins to the bottom above the home indicator; content scrolls beneath it with a soft glass blur at the bottom edge; the emote/field/send controls render as a cohesive glass group (no glass-on-glass seams); typing, emote picker, and send all still work; keyboard still pushes the bar up.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/Chat/ChatScreen.swift
git commit -m "feat(chat): pin compose via safeAreaBar + GlassEffectContainer

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification

- [ ] **Run the full Features test suite**

Run: `swift test --package-path Packages/Features`
Expected: all suites pass (including the new `ChatTabsModelMoveTests` and `FlowLayoutEngineTests`).

- [ ] **Full-app smoke test in the simulator**

Confirm end-to-end: open a channel from Follows → lands in chat as home (no tab bar); open a second channel → swipe between them, header name + page-dots track; tap name → switcher reorders/closes/activates; tap avatar → Profile; tap grid → Follows; close all chats → empty state offers Follows; long messages wrap with a hanging indent; compose bar pins with glass and sends.

---

## Open Questions (for the user before/after build)

1. **Bot-posted event styling.** The spec's "make events look like events" (§3.5.2) cleanly covers genuine EventSub sub/raid/system events — those already render as styled bubbles. But the announcements you saw (Fossabot "gifted a Tier 2 sub", Sery_Bot "ad break") arrive as **normal chat messages from bots**. Distinguishing them needs a heuristic (known bot logins + message patterns) that's fragile and channel-specific. Recommend a separate spike to decide whether it's worth it. **Deferred from this plan.**
2. **Page-dots ceiling.** Dots are shown for any count > 1. If users routinely keep many chats open, we may want to cap dots (e.g., collapse to "•••• +3") — easy follow-up if it looks crowded.
3. **`ChatListView` (UIKit path) row spacing.** Task C3 bumps the SwiftUI legacy path; confirm the UIKit collection-view path's inter-item spacing matches after visual review, and mirror if needed.
