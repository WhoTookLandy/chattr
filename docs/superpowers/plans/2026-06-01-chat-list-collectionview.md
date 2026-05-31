# Chat list: UICollectionView-backed transcript — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ChatScreen`'s `ScrollView`+`LazyVStack` transcript with a recycling `UICollectionView` (diffable data source, `UIHostingConfiguration` cells hosting the existing `ChatRow`), preserving full behavior parity.

**Architecture:** Non-inverted collection view. Two pure, platform-agnostic helpers (`ChatListDiff`, `ScrollAnchor`) carry the testable logic and compile/test on macOS. The `UIViewControllerRepresentable` bridge + `UICollectionViewController` live behind `#if canImport(UIKit)`. `ChatScreen` selects the new list on UIKit platforms and keeps the existing `LazyVStack` as the non-UIKit fallback so the package still builds on macOS (required for `swift test`).

**Tech Stack:** Swift 6 (language mode v6), iOS/macOS 26, SwiftUI, UIKit (`UICollectionViewCompositionalLayout`, `NSDiffableDataSourceSnapshot`, `UIHostingConfiguration`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-01-chat-list-collectionview-design.md`

---

## File structure

| File | Responsibility |
|---|---|
| `Packages/Features/Sources/Features/ScrollAnchor.swift` | **New, pure.** `isNearBottom(...)` threshold math. No UIKit import. |
| `Packages/Features/Sources/Features/ChatListDiff.swift` | **New, pure.** `compute(old:new:) -> Delta` (inserted / removed / reconfigured / ordered ids). No UIKit import. |
| `Packages/Features/Sources/Features/ChatListView.swift` | **New, UIKit-only** (`#if canImport(UIKit)`). `ChatListView` representable + `ChatListViewController` (layout, diffable data source, hosting cells, scroll delegate, anchoring, edge effect). |
| `Packages/Features/Sources/Features/ChatScreen.swift` | **Modify.** `chatScrollView` selects `ChatListView` on UIKit, legacy `LazyVStack` under `#else`; keep the pill overlay + `isAtBottom`; add `scrollToBottomToken`. |
| `Packages/Features/Tests/FeaturesTests/ScrollAnchorTests.swift` | **New.** Unit tests for `ScrollAnchor`. |
| `Packages/Features/Tests/FeaturesTests/ChatListDiffTests.swift` | **New.** Unit tests for `ChatListDiff`. |

**Commands used throughout**
- Pure-type tests (compile Features-for-macOS, exclude UIKit code): `swift test --package-path Packages/Features --filter <name>`
- iOS compile/visual check: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` (confirm the scheme with `xcodebuild -list -project chattr.xcodeproj` first; adjust simulator name to one from `xcrun simctl list devices available`).

---

## Task 1: `ScrollAnchor.isNearBottom`

**Files:**
- Create: `Packages/Features/Sources/Features/ScrollAnchor.swift`
- Test: `Packages/Features/Tests/FeaturesTests/ScrollAnchorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Tests/FeaturesTests/ScrollAnchorTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import Features

@Suite("ScrollAnchor.isNearBottom")
struct ScrollAnchorTests {

    // distance = contentHeight - offsetY - containerHeight + bottomInset

    @Test("Exactly at the bottom is near-bottom")
    func atBottom() {
        // content 1000, container 600, offset 400 → distance 0
        #expect(ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 400, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Scrolled well up is not near-bottom")
    func scrolledUp() {
        // offset 0 → distance 400
        #expect(!ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 0, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Within the 44pt threshold counts as near-bottom")
    func withinThreshold() {
        // offset 360 → distance 40 (≤ 44)
        #expect(ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 360, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Just past the threshold is not near-bottom")
    func pastThreshold() {
        // offset 355 → distance 45 (> 44)
        #expect(!ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 355, containerHeight: 600, bottomInset: 0
        ))
    }

    @Test("Bottom inset is added back into the distance")
    func bottomInsetCounted() {
        // distance = 1000 - 380 - 600 + 20 = 40 → near-bottom
        #expect(ScrollAnchor.isNearBottom(
            contentHeight: 1000, offsetY: 380, containerHeight: 600, bottomInset: 20
        ))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/Features --filter ScrollAnchorTests`
Expected: FAIL — "cannot find 'ScrollAnchor' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Packages/Features/Sources/Features/ScrollAnchor.swift`:

```swift
import CoreGraphics

/// Pure scroll-geometry helpers for the chat list. Kept UIKit-free so it
/// compiles and unit-tests on every platform (the UICollectionView code in
/// `ChatListView.swift` is iOS-only behind `#if canImport(UIKit)`).
enum ScrollAnchor {

    /// Distance below which the scroll is considered "tailing" the live edge.
    /// 44pt absorbs the small offset jitter during rapid appends so the
    /// jump-to-bottom pill doesn't flicker at the exact bottom. Mirrors the
    /// value `ChatScreen` used with `.onScrollGeometryChange`.
    static let nearBottomThreshold: CGFloat = 44

    /// True when the viewport is at (or within `threshold` of) the bottom of
    /// the content. The arithmetic matches the geometry `ChatScreen` computed
    /// inline: `contentHeight - offsetY - containerHeight + bottomInset`.
    static func isNearBottom(
        contentHeight: CGFloat,
        offsetY: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        threshold: CGFloat = nearBottomThreshold
    ) -> Bool {
        let distanceFromBottom = contentHeight - offsetY - containerHeight + bottomInset
        return distanceFromBottom <= threshold
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/Features --filter ScrollAnchorTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Sources/Features/ScrollAnchor.swift Packages/Features/Tests/FeaturesTests/ScrollAnchorTests.swift
git commit -m "Add ScrollAnchor.isNearBottom pure helper + tests"
```

---

## Task 2: `ChatListDiff.compute`

**Files:**
- Create: `Packages/Features/Sources/Features/ChatListDiff.swift`
- Test: `Packages/Features/Tests/FeaturesTests/ChatListDiffTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Tests/FeaturesTests/ChatListDiffTests.swift`:

```swift
import Testing
import Foundation
import ChatModel
@testable import Features

@Suite("ChatListDiff.compute")
struct ChatListDiffTests {

    /// Minimal delivered message line with a given id + body.
    private func line(_ id: String, _ body: String = "hi") -> ChatLine {
        ChatLine(id: id, authorDisplayName: "u", runs: [.text(body)])
    }

    @Test("Appending one line reports it inserted, nothing removed/reconfigured")
    func append() {
        let old = [line("a"), line("b")]
        let new = [line("a"), line("b"), line("c")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.inserted == ["c"])
        #expect(delta.removed.isEmpty)
        #expect(delta.reconfigured.isEmpty)
        #expect(delta.orderedIDs == ["a", "b", "c"])
    }

    @Test("Front-trim reports the dropped ids removed")
    func frontTrim() {
        let old = [line("a"), line("b"), line("c")]
        let new = [line("b"), line("c"), line("d")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.removed == ["a"])
        #expect(delta.inserted == ["d"])
        #expect(delta.reconfigured.isEmpty)
        #expect(delta.orderedIDs == ["b", "c", "d"])
    }

    @Test("Same id with a changed value is reconfigured, not re-inserted")
    func inPlaceChange() {
        let old = [line("a", "sending")]
        // Same id, different body — e.g. optimistic→delivered upgrade.
        let new = [line("a", "delivered")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.reconfigured == ["a"])
        #expect(delta.inserted.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("Identical input produces an empty delta")
    func noChange() {
        let same = [line("a"), line("b")]
        let delta = ChatListDiff.compute(old: same, new: same)
        #expect(delta.inserted.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.reconfigured.isEmpty)
        #expect(delta.orderedIDs == ["a", "b"])
    }

    @Test("chatCleared-style flip reconfigures every changed line")
    func clearAll() {
        let old = [line("a"), line("b"), line("c")]
        // Every line flips to a deleted placeholder (value changes, ids stay).
        let new = old.map { $0.withDeletedPlaceholder() }
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.reconfigured == ["a", "b", "c"])
        #expect(delta.inserted.isEmpty)
        #expect(delta.removed.isEmpty)
    }

    @Test("Retry remove reports the failed id removed")
    func retryRemove() {
        let old = [line("a"), line("pending-x"), line("b")]
        let new = [line("a"), line("b")]
        let delta = ChatListDiff.compute(old: old, new: new)
        #expect(delta.removed == ["pending-x"])
        #expect(delta.inserted.isEmpty)
        #expect(delta.orderedIDs == ["a", "b"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/Features --filter ChatListDiffTests`
Expected: FAIL — "cannot find 'ChatListDiff' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Packages/Features/Sources/Features/ChatListDiff.swift`:

```swift
import ChatModel

/// Pure diff between two `ChatLine` arrays. The chat list applies the
/// `orderedIDs` as a diffable snapshot (the data source derives
/// insert/delete/move from the id order) and then explicitly
/// `reconfigureItems(reconfigured)` — because a diffable snapshot whose item
/// identifiers are unchanged will NOT re-render a cell whose underlying
/// `ChatLine` value changed (the optimistic→delivered upgrade, `markFailed`,
/// and `deletedPlaceholder` flips all keep the same id).
///
/// UIKit-free on purpose: this is the testable core and must compile on
/// macOS (where the `UICollectionView` code is excluded by `#if canImport`).
enum ChatListDiff {

    struct Delta: Equatable {
        /// Ids present in `new` but not `old`.
        var inserted: [String]
        /// Ids present in `old` but not `new`.
        var removed: [String]
        /// Ids present in both whose `ChatLine` value changed.
        var reconfigured: [String]
        /// The full new id order — becomes the snapshot's item identifiers.
        var orderedIDs: [String]
    }

    static func compute(old: [ChatLine], new: [ChatLine]) -> Delta {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })

        var inserted: [String] = []
        var reconfigured: [String] = []
        // Walk `new` in order so the result arrays are deterministic
        // (id order follows display order — nice for tests + logging).
        for line in new {
            if let prior = oldByID[line.id] {
                if prior != line { reconfigured.append(line.id) }
            } else {
                inserted.append(line.id)
            }
        }
        let removed = old.compactMap { newByID[$0.id] == nil ? $0.id : nil }

        return Delta(
            inserted: inserted,
            removed: removed,
            reconfigured: reconfigured,
            orderedIDs: new.map(\.id)
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Packages/Features --filter ChatListDiffTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Sources/Features/ChatListDiff.swift Packages/Features/Tests/FeaturesTests/ChatListDiffTests.swift
git commit -m "Add ChatListDiff.compute pure diff + tests"
```

---

## Task 3: De-risking spike — hosting cells self-size + context menu works

This task builds the representable + view controller with **just enough** to put
`ChatRow`s on screen in `UIHostingConfiguration` cells. It deliberately stops
before diffing/anchoring so we validate the two bridging unknowns (self-sizing
with estimated heights; SwiftUI `.contextMenu` inside a hosting cell) before
investing further. Verification is visual in the simulator — there is no unit
test for UIKit layout.

**Files:**
- Create: `Packages/Features/Sources/Features/ChatListView.swift`

- [ ] **Step 1: Create the representable + view controller skeleton**

Create `Packages/Features/Sources/Features/ChatListView.swift`:

```swift
#if canImport(UIKit)
import SwiftUI
import UIKit
import ChatModel

/// SwiftUI bridge to a recycling `UICollectionView` chat transcript. Hosts the
/// existing `ChatRow` verbatim via `UIHostingConfiguration`, so all of ChatRow's
/// SwiftUI behavior (context menu, highlighted backplate, bubble rows) is
/// preserved while the collection view provides cell recycling and native
/// scroll anchoring.
///
/// Non-inverted (natural orientation) — see the design spec for why the
/// inverted-transform approach was rejected (it degrades the per-row context
/// menu previews).
struct ChatListView: UIViewControllerRepresentable {
    /// Display-ready lines, passed from `ChatScreen.body`.
    let lines: [ChatLine]
    /// Builds a row for one line — the badge lookup and the four per-line
    /// callbacks are assembled by `ChatScreen`, keeping this component
    /// ignorant of the model layer.
    let rowContent: (ChatLine) -> ChatRow
    /// UIKit → SwiftUI: true when tailing the live edge. Drives the pill.
    @Binding var isAtBottom: Bool
    /// SwiftUI → UIKit: incremented by the jump-to-bottom pill to request a
    /// scroll to the newest message.
    let scrollToBottomToken: Int

    func makeUIViewController(context: Context) -> ChatListViewController {
        let vc = ChatListViewController()
        vc.rowContent = rowContent
        vc.onAtBottomChanged = { atBottom in
            // Avoid mutating SwiftUI state during the UIKit layout pass.
            DispatchQueue.main.async { isAtBottom = atBottom }
        }
        return vc
    }

    func updateUIViewController(_ vc: ChatListViewController, context: Context) {
        // rowContent captures fresh per-body closures each update — refresh it
        // so cells built after this call use current state.
        vc.rowContent = rowContent
        vc.update(lines: lines, scrollToBottomToken: scrollToBottomToken)
    }
}

/// Owns the collection view, its compositional layout, the diffable data
/// source, and (added in later tasks) the scroll delegate + anchoring.
final class ChatListViewController: UIViewController {

    /// Single section — chat is one flat list.
    private enum Section { case main }

    var rowContent: ((ChatLine) -> ChatRow)?

    /// UIKit → SwiftUI callback for tailing state (set by the representable).
    var onAtBottomChanged: ((Bool) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

    /// Last-applied lines, keyed by id for the cell provider's O(1) lookup.
    private var linesByID: [String: ChatLine] = [:]
    /// Last-applied lines in order — the `old` side of the next diff.
    private(set) var lastLines: [ChatLine] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
    }

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: Self.makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        view.addSubview(collectionView)
    }

    /// Full-width, self-sizing rows (`.estimated`), 4pt inter-row spacing, and
    /// horizontal insets matching `ChatScreen`'s former `.padding(.horizontal)`.
    /// A custom compositional layout (not a list config) avoids the list's
    /// default separators/insets fighting the bubble rows.
    private static func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(44)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 4
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let line = self.linesByID[id], let rowContent = self.rowContent else { return }
            cell.contentConfiguration = UIHostingConfiguration { rowContent(line) }
                .margins(.all, 0)   // ChatRow + section insets own the spacing
            cell.backgroundConfiguration = .clear()
        }
        dataSource = UICollectionViewDiffableDataSource<Section, String>(
            collectionView: collectionView
        ) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    /// SPIKE version: rebuild the whole snapshot every update. Replaced by the
    /// diff-based path in Task 4.
    func update(lines newLines: [ChatLine], scrollToBottomToken: Int) {
        lastLines = newLines
        linesByID = Dictionary(uniqueKeysWithValues: newLines.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newLines.map(\.id), toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
#endif
```

- [ ] **Step 2: Temporarily mount the spike in ChatScreen**

In `Packages/Features/Sources/Features/ChatScreen.swift`, inside `chatScrollView`,
temporarily replace the `ScrollView { ... }` body with the spike so it renders on
device. Wrap it so macOS still builds:

```swift
    @ViewBuilder
    private var chatScrollView: some View {
        #if canImport(UIKit)
        ChatListView(
            lines: chatModel.lines,
            rowContent: { line in chatRow(for: line) },
            isAtBottom: $isAtBottom,
            scrollToBottomToken: 0
        )
        #else
        legacyScrollView
        #endif
    }
```

Add a `chatRow(for:)` helper that returns the same `ChatRow` the `ForEach`
builds today (extract the existing closure bodies verbatim):

```swift
    /// Builds the row for one line — same badge lookup + callbacks the
    /// `ForEach` used, lifted into a helper so both the collection-view cell
    /// provider and the legacy `LazyVStack` can call it.
    private func chatRow(for line: ChatLine) -> ChatRow {
        ChatRow(
            line: line,
            badgeEntries: badgeStore?.entries(for: line.originalBadges) ?? [],
            onRetry: { Task { await chatModel.retry(failedLineId: line.id) } },
            onReply: { chatModel.beginReply(to: line) },
            onViewThread: {
                viewingThreadRootId = ThreadRootID(id: TabChatModel.threadRoot(of: line))
            },
            onDelete: (chatModel.currentUserCanModerate
                       && line.authorUserId != account.userId)
                ? { Task { await chatModel.deleteMessage(line.id) } }
                : nil
        )
    }
```

Rename the existing `ScrollView { ... }`-based property to `legacyScrollView`
(keep it intact for the `#else` branch and as the reference for parity).

- [ ] **Step 3: Build for the simulator**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
Expected: BUILD SUCCEEDED. (Confirm the scheme name with `xcodebuild -list -project chattr.xcodeproj`.)

- [ ] **Step 4: Visual verification (manual)**

Run the app in the simulator, open a busy channel, and confirm:
1. Rows render at correct, varied heights — multi-line messages and bubble rows
   are **not clipped** (estimated self-sizing works).
2. Long-pressing a message opens `ChatRow`'s context menu and the preview
   animates correctly from the cell.
3. Highlighted (`@me`) rows show their accent backplate.

If clipping occurs, the fix is to keep `.estimated` dimensions (never fixed) and
verify `ChatRow` reports an intrinsic height — do not proceed until rows size
correctly.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Sources/Features/ChatListView.swift Packages/Features/Sources/Features/ChatScreen.swift
git commit -m "Spike: UICollectionView chat list hosting ChatRow (self-size + context menu verified)"
```

---

## Task 4: Diff-based updates with reconfigure

Replace the spike's full-rebuild `update(...)` with the `ChatListDiff`-driven
path so only changed cells re-render.

**Files:**
- Modify: `Packages/Features/Sources/Features/ChatListView.swift`

- [ ] **Step 1: Replace `update(lines:scrollToBottomToken:)`**

In `ChatListViewController`, replace the spike `update(...)` with:

```swift
    /// Diff the new lines against the last-applied set, apply the structural
    /// snapshot (insert/delete/move derived from the id order), then explicitly
    /// reconfigure cells whose `ChatLine` value changed but whose id did not.
    func update(lines newLines: [ChatLine], scrollToBottomToken: Int) {
        let delta = ChatListDiff.compute(old: lastLines, new: newLines)

        lastLines = newLines
        linesByID = Dictionary(uniqueKeysWithValues: newLines.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(delta.orderedIDs, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)

        if !delta.reconfigured.isEmpty {
            var reconfig = dataSource.snapshot()
            reconfig.reconfigureItems(delta.reconfigured)
            dataSource.apply(reconfig, animatingDifferences: false)
        }
    }
```

- [ ] **Step 2: Build for the simulator**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Visual verification (manual)**

In the simulator: send a message and watch the optimistic row (dimmed) upgrade to
delivered **in place** without the row flickering or the list jumping. Have a mod
delete a message and confirm it flips to the struck-through placeholder in place.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/ChatListView.swift
git commit -m "Diff-based snapshot updates with explicit reconfigure"
```

---

## Task 5: Scroll delegate — `isAtBottom` on flip + auto-tail

**Files:**
- Modify: `Packages/Features/Sources/Features/ChatListView.swift`

- [ ] **Step 1: Add the scroll delegate + auto-tail**

In `ChatListViewController`, add stored state near the other properties:

```swift
    /// Last `isAtBottom` value pushed to SwiftUI — we only call the callback on
    /// a flip, never per scroll frame (matches the old onScrollGeometryChange).
    private var lastReportedAtBottom = true
```

Set the delegate in `configureCollectionView()` (after creating `collectionView`):

```swift
        collectionView.delegate = self
```

Add the delegate conformance and the auto-tail call. First, extend the class:

```swift
extension ChatListViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let atBottom = ScrollAnchor.isNearBottom(
            contentHeight: scrollView.contentSize.height,
            offsetY: scrollView.contentOffset.y,
            containerHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
        guard atBottom != lastReportedAtBottom else { return }
        lastReportedAtBottom = atBottom
        onAtBottomChanged?(atBottom)
    }
}
```

Then, in `update(lines:scrollToBottomToken:)`, capture tailing state before the
apply and auto-scroll after. Change the method's body so the top reads:

```swift
        let delta = ChatListDiff.compute(old: lastLines, new: newLines)
        let wasAtBottom = lastReportedAtBottom
```

and add, after the reconfigure block:

```swift
        if wasAtBottom {
            scrollToBottom(animated: false)
        }
```

Add the scroll helper:

```swift
    /// Scroll the newest message to the bottom edge. No animation — under burst
    /// traffic queued animations stutter (the same reason `ChatScreen` snapped
    /// instantly).
    private func scrollToBottom(animated: Bool) {
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else { return }
        let indexPath = IndexPath(item: count - 1, section: 0)
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }
```

- [ ] **Step 2: Build for the simulator**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Visual verification (manual)**

In the simulator: while tailing, new messages auto-scroll the newest into view.
Scroll up — new messages stop snapping (you stay put). The first appearance opens
pinned at the bottom (since `lastReportedAtBottom` defaults true and the first
`update` auto-scrolls).

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/ChatListView.swift
git commit -m "Scroll delegate: publish isAtBottom on flip + auto-tail on append"
```

---

## Task 6: Anchor-offset preservation on front-trim

Keep the viewport visually stable when the 500-line ring buffer drops rows above
the viewport while the user is scrolled up.

**Files:**
- Modify: `Packages/Features/Sources/Features/ChatListView.swift`

- [ ] **Step 1: Add anchor capture/restore + wire into `update`**

Add these helpers to `ChatListViewController`:

```swift
    /// The topmost visible item's id and its offset from the viewport top —
    /// captured before a data change so we can restore the same reading
    /// position afterward.
    private func currentTopAnchor() -> (id: String, distanceFromTop: CGFloat)? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        guard let top = visible.first,
              let id = dataSource.itemIdentifier(for: top),
              let attrs = collectionView.layoutAttributesForItem(at: top) else { return nil }
        return (id, attrs.frame.minY - collectionView.contentOffset.y)
    }

    /// Restore the viewport so `anchor.id` sits at the same distance from the
    /// top as before — cancels the jump a front-trim would otherwise cause.
    private func restoreTopAnchor(_ anchor: (id: String, distanceFromTop: CGFloat)) {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: anchor.id),
              let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        var offset = collectionView.contentOffset
        offset.y = attrs.frame.minY - anchor.distanceFromTop
        collectionView.setContentOffset(offset, animated: false)
    }
```

In `update(lines:scrollToBottomToken:)`, capture the anchor when scrolled up and a
removal is happening, and restore it after the apply. The method becomes:

```swift
    func update(lines newLines: [ChatLine], scrollToBottomToken: Int) {
        let delta = ChatListDiff.compute(old: lastLines, new: newLines)
        let wasAtBottom = lastReportedAtBottom

        // Only needed when scrolled up AND rows are leaving above us.
        let anchor: (id: String, distanceFromTop: CGFloat)? =
            (!wasAtBottom && !delta.removed.isEmpty) ? currentTopAnchor() : nil

        lastLines = newLines
        linesByID = Dictionary(uniqueKeysWithValues: newLines.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(delta.orderedIDs, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)

        if !delta.reconfigured.isEmpty {
            var reconfig = dataSource.snapshot()
            reconfig.reconfigureItems(delta.reconfigured)
            dataSource.apply(reconfig, animatingDifferences: false)
        }

        if wasAtBottom {
            scrollToBottom(animated: false)
        } else if let anchor {
            restoreTopAnchor(anchor)
        }
    }
```

- [ ] **Step 2: Build for the simulator**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Visual verification (manual)**

Scroll up into history in a fast channel and let messages keep arriving past the
500 cap so the buffer trims from the top. The content you are reading should stay
put (no upward jump) as old rows drop off the top.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Sources/Features/ChatListView.swift
git commit -m "Preserve reading position across front-trim via top-anchor offset"
```

---

## Task 7: Edge effect, keyboard dismiss, and scroll-to-bottom token

**Files:**
- Modify: `Packages/Features/Sources/Features/ChatListView.swift`

- [ ] **Step 1: Hard top edge effect + token-driven scroll**

In `configureCollectionView()`, after setting `keyboardDismissMode`, add the hard
top edge effect (the UIKit equivalent of `.scrollEdgeEffectStyle(.hard, for: .top)`,
confirmed via Apple's UIKit Liquid Glass doc):

```swift
        collectionView.topEdgeEffect.style = .hard
```

Add token tracking near the other stored state:

```swift
    /// Last-seen scroll-to-bottom token — the pill increments the value to
    /// request a scroll; we act only when it changes.
    private var lastScrollToBottomToken = 0
```

At the end of `update(lines:scrollToBottomToken:)`, handle the token:

```swift
        if scrollToBottomToken != lastScrollToBottomToken {
            lastScrollToBottomToken = scrollToBottomToken
            scrollToBottom(animated: false)
        }
```

- [ ] **Step 2: Build for the simulator**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Sources/Features/ChatListView.swift
git commit -m "Hard top edge effect + token-driven scroll-to-bottom"
```

---

## Task 8: Integrate into `ChatScreen` (pill, unread, fallback)

Finalize the `ChatScreen` wiring: drive the jump-to-bottom pill from the bridged
`isAtBottom`, increment the token on tap, and keep the legacy `LazyVStack` under
`#else` for macOS.

**Files:**
- Modify: `Packages/Features/Sources/Features/ChatScreen.swift`

- [ ] **Step 1: Add the token state**

Near the other `@State` in `ChatScreen` (by `scrolledMessageId`), add:

```swift
    /// Incremented to ask the UIKit chat list to scroll to the newest message
    /// (jump-to-bottom pill). The collection view acts on each change.
    @State private var scrollToBottomToken = 0
```

- [ ] **Step 2: Finalize `chatScrollView`**

Replace `chatScrollView` so the UIKit path carries the pill overlay + unread
plumbing and the token, and the legacy path stays for non-UIKit:

```swift
    @ViewBuilder
    private var chatScrollView: some View {
        #if canImport(UIKit)
        ChatListView(
            lines: chatModel.lines,
            rowContent: { line in chatRow(for: line) },
            isAtBottom: $isAtBottom,
            scrollToBottomToken: scrollToBottomToken
        )
        // New messages while scrolled up tally into the unread pill; while
        // tailing, the collection view auto-scrolls and we reset the count.
        .onChange(of: chatModel.lines.count) { oldCount, newCount in
            if isAtBottom {
                unreadWhileScrolledUp = 0
            } else if newCount > oldCount {
                unreadWhileScrolledUp += (newCount - oldCount)
            }
        }
        .onChange(of: isAtBottom) { _, atBottom in
            if atBottom { unreadWhileScrolledUp = 0 }
        }
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                jumpToBottomPill
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
        #else
        legacyScrollView
        #endif
    }
```

- [ ] **Step 3: Point the pill at a platform-dispatched helper**

The pill is shared by both the UIKit and legacy paths, so its action must do the
right thing per platform — bump the token on UIKit, write `scrolledMessageId` on
macOS. Add this helper to `ChatScreen`:

```swift
    /// Jump the transcript to the newest message. On UIKit the collection view
    /// owns scrolling (token bump); on other platforms the legacy ScrollView
    /// scrolls via `scrolledMessageId`.
    private func jumpToLatest() {
        #if canImport(UIKit)
        scrollToBottomToken += 1
        #else
        if let last = chatModel.lines.last { scrolledMessageId = last.id }
        #endif
    }
```

In `jumpToBottomPill`, replace the `scrolledMessageId = …` action with:

```swift
        Button {
            jumpToLatest()
        } label: {
```

(The rest of `jumpToBottomPill` is unchanged. `scrolledMessageId` stays declared —
the `#else` legacy path still uses it.)

- [ ] **Step 4: Build both platforms**

Run: `xcodebuild build -project chattr.xcodeproj -scheme chattr -destination 'platform=iOS Simulator,name=iPhone 16 Pro'`
Expected: BUILD SUCCEEDED.

Run: `swift build --package-path Packages/Features`
Expected: BUILD SUCCEEDED (macOS path compiles `legacyScrollView`, excludes the UIKit code).

- [ ] **Step 5: Visual verification (manual)**

Full parity sweep in the simulator:
1. Fresh channel join opens pinned at the bottom.
2. Scroll up → pill appears; new messages increment "N new messages".
3. Tap pill → snaps to newest, pill hides, count resets.
4. Drag the transcript down → keyboard dismisses interactively.
5. The glass tab strip above shows the hard scroll-edge dissolve.
6. Optimistic send → in-place upgrade; failed send → red footer + retry.

- [ ] **Step 6: Run the unit suite**

Run: `swift test --package-path Packages/Features`
Expected: PASS (existing tests + `ScrollAnchorTests` + `ChatListDiffTests`).

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Sources/Features/ChatScreen.swift
git commit -m "Integrate UICollectionView chat list into ChatScreen with pill + unread parity"
```

---

## Task 9: Measurement gate (Instruments)

The production-decision evidence. No code — a profiling comparison.

- [ ] **Step 1: Baseline the current build**

Check out `main` (the pre-migration `LazyVStack`), build Release, and profile with
Instruments 26 (SwiftUI + Time Profiler + Hangs & Hitches template) on a real
device while replaying a 50-200 msg/sec burst. Record:
- **Long View Body Updates** — `ChatRow` eval volume/duration.
- **Hangs & Hitches** — scroll hitch count during the burst.

- [ ] **Step 2: Profile the new build**

Repeat on the `chat-list-collectionview` branch. Record the same lanes plus:
- **Long Representable Updates** — confirm `updateUIViewController` (diff +
  snapshot apply) is **not** a new bottleneck.

- [ ] **Step 3: Compare and record**

Confirm `ChatRow` eval volume and scroll hitches drop versus the
post-`Equatable`, iOS-26 baseline, and that the representable lane stays clean.
Note the numbers in the PR description. If the representable lane shows long
updates, investigate the diff/reconfigure path before merging.

---

## Self-review notes

- **Spec coverage:** architecture/components → Tasks 1-7; data flow + diffing →
  Tasks 2, 4; scroll anchoring (tail / append / front-trim) → Tasks 5, 6;
  parity checklist (pill, unread, keyboard, edge effect, initial scroll,
  VoiceOver) → Tasks 5-8; de-risking checkpoint → Task 3; testing + measurement
  → Tasks 1, 2, 9. ThreadView deferral and model-stays-scroll-ignorant are
  honored (no `TabChatModel` edits).
- **Types are consistent across tasks:** `ChatListDiff.Delta` fields
  (`inserted`/`removed`/`reconfigured`/`orderedIDs`), `ScrollAnchor.isNearBottom`
  signature, `ChatListViewController.update(lines:scrollToBottomToken:)`,
  `chatRow(for:)`, and `scrollToBottomToken` are used identically wherever they
  appear.
- **No placeholders:** every code step shows complete code; every run step shows
  the command + expected result.
