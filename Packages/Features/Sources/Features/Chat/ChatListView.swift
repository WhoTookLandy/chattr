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
    /// `ChatTranscriptModel.changeVersion` — a TRIGGER only. Passing the `Int`
    /// (not the `[ChatLine]`) keeps the parent body off the full-array
    /// dependency while still making SwiftUI call `updateUIViewController`
    /// once per model flush. The controller never trusts the value's
    /// arithmetic (SwiftUI may coalesce several flushes into one update); it
    /// pulls everything since its own last version via `changes`.
    let changeVersion: Int
    /// The model's `changes(since:)` — every published change after a
    /// version, or `.overrun`. A closure, not a stored array, so reading it
    /// doesn't register a body dependency.
    let changes: (Int) -> ChatChangeLog.Delta
    /// The model's `transcriptSnapshot()` — the first-mount / log-overrun /
    /// abandoned-backlog fallback. Only invoked when replay can't be used.
    let snapshot: () -> (version: Int, lines: [ChatLine])
    /// Builds a row for one line — the badge lookup and the four per-line
    /// callbacks are assembled by `ChatScreen`, keeping this component
    /// ignorant of the model layer.
    let rowContent: (ChatLine) -> ChatRow
    /// UIKit → SwiftUI: true when tailing the live edge. Drives the pill.
    @Binding var isAtBottom: Bool
    /// UIKit → SwiftUI: messages that arrived while the list was unpinned and
    /// are held back off screen. Drives the pill's "N new".
    @Binding var unreadCount: Int
    /// SwiftUI → UIKit: incremented by the jump-to-bottom pill to request a
    /// scroll to the newest message.
    let scrollToBottomToken: Int
    /// True when the user's Edge-to-Edge Chat setting extends the
    /// transcript under the toolbar pills. Switches the top scroll-edge
    /// effect: `.hard` cutoff when the list stops at the safe-area edge,
    /// system-default soft dissolve when content runs underneath glass.
    var extendsToTop: Bool = false

    func makeUIViewController(context: Context) -> ChatListViewController {
        let vc = ChatListViewController()
        vc.rowContent = rowContent
        vc.onAtBottomChanged = { atBottom in
            // Avoid mutating SwiftUI state during the UIKit layout pass.
            // Task { @MainActor } defers past the current synchronous
            // execution like DispatchQueue.main.async did, but stays in the
            // Swift concurrency model (main actor executor, not a raw GCD
            // enqueue) — one scheduling world instead of two.
            Task { @MainActor in isAtBottom = atBottom }
        }
        vc.onUnreadCountChanged = { count in
            // Same deferral as above — this can fire from inside a SwiftUI
            // update pass or a scroll callback.
            Task { @MainActor in unreadCount = count }
        }
        return vc
    }

    func updateUIViewController(_ vc: ChatListViewController, context: Context) {
        // rowContent captures fresh per-body closures each update — refresh it
        // so cells built after this call use current state.
        vc.rowContent = rowContent
        vc.extendsToTop = extendsToTop
        vc.update(
            changes: changes,
            snapshot: snapshot,
            scrollToBottomToken: scrollToBottomToken
        )
    }
}

/// Collection view that reports every layout pass to its owner. Self-sizing
/// cells (`UIHostingConfiguration` + `.estimated` heights) invalidate layout
/// from INSIDE the collection view as cells materialize and report their real
/// heights — those passes reach `layoutSubviews` here but NOT the view
/// controller's `viewDidLayoutSubviews`, so this hook is the only reliable
/// place to re-assert the bottom pin after each estimate→actual correction.
private final class LayoutCallbackCollectionView: UICollectionView {
    var onDidLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onDidLayout?()
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

    /// UIKit → SwiftUI callback for the held-back message count (set by the
    /// representable). Fired only when the count changes.
    var onUnreadCountChanged: ((Int) -> Void)?

    /// Mirrors `ChatListView.extendsToTop` — applied on change (and once
    /// at viewDidLoad, since the representable sets it before the view
    /// loads). Full-bleed hides the top edge effect entirely so messages
    /// stay fully legible to the physical top (the toolbar items carry
    /// their own glass); the inset layout keeps the crisp `.hard` cutoff.
    var extendsToTop: Bool = false {
        didSet {
            guard isViewLoaded, oldValue != extendsToTop else { return }
            applyTopEdgeTreatment()
        }
    }

    private func applyTopEdgeTreatment() {
        collectionView.topEdgeEffect.isHidden = extendsToTop
        collectionView.topEdgeEffect.style = .hard
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

    /// Last `isAtBottom` value pushed to SwiftUI — we only call the callback on
    /// a flip, never per scroll frame (matches the old onScrollGeometryChange).
    private var lastReportedAtBottom = true

    /// True while the transcript is "tailing" — glued to the newest message.
    ///
    /// While pinned, every collection-view layout pass re-asserts the
    /// bottom-pinned content offset (see `pinToBottomIfNeeded`). This replaces
    /// the old one-shot `scrollToItem(at:.bottom)`: with `.estimated(44)`
    /// self-sizing rows, a one-shot scroll computes its destination from
    /// estimated attributes and lands wrong whenever real heights differ —
    /// the per-pass re-pin absorbs each estimate→actual correction before
    /// it's ever drawn (the "bounce" on new messages, and the pill jump
    /// landing short of the bottom).
    ///
    /// Cleared the moment the user starts dragging; restored when a drag or
    /// deceleration ends near the bottom, or when the jump-to-bottom pill
    /// fires. Starts true — chat opens tailing.
    ///
    /// Also gates data flow: while unpinned, appends / trims / re-keys are
    /// held back by `feed` so the rows being read can't be trimmed out from
    /// under the reader; re-pinning flushes them in one apply.
    private var isPinnedToBottom = true

    /// Last-seen scroll-to-bottom token — the jump-to-bottom pill increments the
    /// value to request a scroll; we act only when it changes.
    private var lastScrollToBottomToken = 0

    /// Consumer of the model's change log: what the data source shows (and
    /// the cell provider's `linesByID` lookup), plus the changes held back
    /// while the user reads scrollback. See `ChatListFeed`.
    private var feed = ChatListFeed()

    /// Latest model accessors, kept so a scroll callback (resuming tailing)
    /// can flush the held-back changes immediately instead of waiting for the
    /// next SwiftUI update — which never comes if the chat has gone quiet.
    private var pullChanges: ((Int) -> ChatChangeLog.Delta)?
    private var pullSnapshot: (() -> (version: Int, lines: [ChatLine]))?

    /// Last unread count pushed to SwiftUI — report on change only.
    private var lastReportedUnread = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        configureCollectionView()
        configureDataSource()
    }

    private func configureCollectionView() {
        let layoutCallbackView = LayoutCallbackCollectionView(frame: view.bounds, collectionViewLayout: Self.makeLayout())
        // Re-pin after EVERY layout pass while tailing — this is what keeps
        // the bottom glued through self-sizing corrections, front-trims, and
        // keyboard/inset changes. The offset-delta guard inside
        // pinToBottomIfNeeded breaks the layout→pin→layout recursion once
        // the geometry converges.
        layoutCallbackView.onDidLayout = { [weak self] in self?.pinToBottomIfNeeded() }
        collectionView = layoutCallbackView
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        // Top scroll-edge treatment — `.hard` cutoff for the inset layout,
        // hidden entirely when Edge-to-Edge Chat runs the transcript under
        // the free-standing toolbar items (the UIKit equivalent of
        // SwiftUI's `.scrollEdgeEffectStyle(_:for: .top)`).
        applyTopEdgeTreatment()
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    /// Learned average chat-row height, used as the self-sizing ESTIMATE for
    /// the compositional layout (refined in `refineEstimatedRowHeight`).
    ///
    /// Why it matters for swipe feel: with `.estimated` cells the collection
    /// view computes total content height from this value BEFORE it measures
    /// off-screen cells. For a bottom-pinned transcript, a stale estimate means
    /// the initial bottom offset is wrong by `lineCount × per-row-error`, so a
    /// freshly-mounted page (every swipe to a new chat) thrashes through
    /// estimate→actual corrections to settle — the dominant cost in swipe
    /// profiling. Seeded at a single-line guess and refined from the real
    /// heights of laid-out cells on each mount. Process-wide (`static`) so
    /// every page you swipe to inherits heights the previous pages measured,
    /// instead of every page re-learning from 44pt.
    ///
    /// Main-thread only (every touch is from a UIKit method on this VC), hence
    /// `@MainActor` rather than any locking.
    @MainActor private static var estimatedRowHeight: CGFloat = 44

    /// Full-width, self-sizing rows (`.estimated`), 4pt inter-row spacing, and
    /// horizontal insets matching `ChatScreen`'s former `.padding(.horizontal)`.
    /// A custom compositional layout (not a list config) avoids the list's
    /// default separators/insets fighting the bubble rows.
    @MainActor private static func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(estimatedRowHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 4
        // Bottom inset tighter than top: the compose bar's own padding
        // already provides breathing room below the last message.
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let line = self.feed.linesByID[id], let rowContent = self.rowContent else { return }
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
    /// top as before — cancels the jump an edit above the viewport would
    /// otherwise cause. Forces a layout pass, so it runs only for edits that
    /// land while unpinned (in-place edits and resets; trims are held back).
    private func restoreTopAnchor(_ anchor: (id: String, distanceFromTop: CGFloat)) {
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: anchor.id),
              let attrs = collectionView.layoutAttributesForItem(at: indexPath) else { return }
        var offset = collectionView.contentOffset
        offset.y = attrs.frame.minY - anchor.distanceFromTop
        collectionView.setContentOffset(offset, animated: false)
    }

    /// Re-assert the bottom-pinned content offset if tailing. Called from the
    /// collection view's `layoutSubviews` (every pass) and from `update` right
    /// after a snapshot applies.
    ///
    /// No animation — under burst traffic queued animations stutter (the same
    /// reason `ChatScreen` snapped instantly), and `setContentOffset(animated:
    /// false)` also kills any in-flight deceleration so a pill tap mid-fling
    /// doesn't fight the momentum.
    private func pinToBottomIfNeeded() {
        guard isPinnedToBottom else { return }
        let target = ScrollAnchor.bottomPinnedOffsetY(
            contentHeight: collectionView.contentSize.height,
            containerHeight: collectionView.bounds.height,
            topInset: collectionView.adjustedContentInset.top,
            bottomInset: collectionView.adjustedContentInset.bottom
        )
        // Sub-point deltas are layout noise, not drift — skipping them is
        // what terminates the layout→pin→layout recursion.
        guard abs(collectionView.contentOffset.y - target) > 0.5 else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: target),
            animated: false
        )
    }

    /// SwiftUI update (a model flush, or anything else that re-ran the parent
    /// body): remember the model accessors, honor the jump-to-bottom pill,
    /// then pull and apply everything new.
    ///
    /// There is no version arithmetic here. SwiftUI may fold several model
    /// flushes into one update; the feed asks the model for every change
    /// since the version IT last consumed, so nothing is skipped, and a
    /// wholesale reset happens only on first mount or when the model's
    /// bounded log no longer reaches back that far.
    func update(
        changes: @escaping (Int) -> ChatChangeLog.Delta,
        snapshot: @escaping () -> (version: Int, lines: [ChatLine]),
        scrollToBottomToken: Int
    ) {
        pullChanges = changes
        pullSnapshot = snapshot

        let jumpRequested = scrollToBottomToken != lastScrollToBottomToken
        if jumpRequested {
            lastScrollToBottomToken = scrollToBottomToken
            // Jump-to-bottom pill: re-enter tailing BEFORE pulling, so the
            // backlog held back while reading flushes in this same apply. The
            // per-pass pinToBottomIfNeeded (and the explicit pin in `apply`)
            // glue the offset to the live edge from here — same mechanism as
            // resumeTailingIfNearBottom.
            isPinnedToBottom = true
        }
        refresh()
        if jumpRequested { pinToBottomIfNeeded() }
    }

    /// Pulls everything the model published since the feed's last version and
    /// applies it as one data-source edit. Pinned: all of it (held-back
    /// backlog first). Unpinned: only in-place edits of on-screen rows and
    /// wholesale resets; appends / trims / re-keys wait (see `ChatListFeed`).
    private func refresh(reconfigureAll: Bool = false) {
        guard let pullChanges, let pullSnapshot else { return }
        let edit = feed.update(
            pinned: isPinnedToBottom,
            reconfigureAll: reconfigureAll,
            changes: pullChanges,
            snapshot: pullSnapshot
        )
        apply(edit)
        reportUnreadCountIfChanged()
    }

    private func reportUnreadCountIfChanged() {
        let count = feed.unreadCount
        guard count != lastReportedUnread else { return }
        lastReportedUnread = count
        onUnreadCountChanged?(count)
    }

    /// Folds one `ChatListEdit` into the diffable data source with a SINGLE
    /// `apply` — structural steps and reconfigures on the same snapshot, no
    /// whole-list `Set` rebuild (the feed tracks live ids incrementally).
    /// Then keeps the viewport where it belongs: glued to the live edge when
    /// pinned, otherwise holding the reading position.
    private func apply(_ edit: ChatListEdit) {
        guard !edit.isEmpty else { return }

        // Pinned state — not the geometric `lastReportedAtBottom` — decides.
        // Mid-drag near the bottom the pin is already released while the
        // geometry still reads "at bottom"; keying off geometry skipped the
        // anchor there and let the edit shove the content under the finger.
        // Unpinned edits are rare (structural changes are held back), so
        // anchoring every one is cheap, and it also absorbs height changes
        // from in-place edits above the viewport (a delete flipping a row to
        // its placeholder).
        let anchor: (id: String, distanceFromTop: CGFloat)? =
            isPinnedToBottom ? nil : currentTopAnchor()

        var snapshot: NSDiffableDataSourceSnapshot<Section, String>
        if let resetIds = edit.resetIds {
            snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(resetIds, toSection: .main)
        } else {
            snapshot = dataSource.snapshot()
            if snapshot.numberOfSections == 0 { snapshot.appendSections([.main]) }
        }
        for step in edit.steps {
            switch step {
            case .delete(let ids):
                snapshot.deleteItems(ids)
            case .append(let ids):
                snapshot.appendItems(ids, toSection: .main)
            case .replace(let from, let to):
                // Optimistic row upgraded to its server id: the delivered row
                // takes the dimmed one's slot.
                snapshot.insertItems([to], beforeItem: from)
                snapshot.deleteItems([from])
            }
        }
        // Same snapshot, same apply. `ChatListEdit` guarantees each of these
        // ids was in the data source before this edit and still is, so none
        // is an insert (fresh cells read `feed.linesByID` anyway).
        if !edit.reconfigure.isEmpty {
            snapshot.reconfigureItems(edit.reconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        if isPinnedToBottom {
            // Force the post-snapshot layout now, then pin. layoutIfNeeded
            // runs the collection view's layoutSubviews, whose onDidLayout
            // already pins — the explicit call after it is a cheap no-op
            // guard for the path where layout was already clean.
            // setContentOffset fires scrollViewDidScroll synchronously; the
            // flip-only guard there prevents any feedback loop.
            collectionView.layoutIfNeeded()
            pinToBottomIfNeeded()
        } else if let anchor {
            restoreTopAnchor(anchor)
        }

        // A reset is a mount / wholesale reload — the swipe-in path. The
        // cells are laid out now (the pin/anchor blocks above forced layout),
        // so this is the cheapest moment to learn the real row height for the
        // NEXT page's layout. Gated on reset so the per-flush append path
        // never pays for it.
        if edit.resetIds != nil { Self.refineEstimatedRowHeight(from: collectionView) }
    }

    /// Refine the process-wide row-height estimate from the cells that are
    /// actually laid out right now. O(visible cells) — a dozen-ish `bounds`
    /// reads — and only ever called on reset/mount, never per message.
    /// Exponential smoothing keeps one atypical screenful (e.g. an all-emote
    /// raid) from whipsawing the estimate, and the clamp stops a glitchy
    /// layout pass from poisoning every future page's layout.
    @MainActor
    private static func refineEstimatedRowHeight(from collectionView: UICollectionView) {
        let heights = collectionView.visibleCells.map(\.bounds.height).filter { $0 > 1 }
        guard !heights.isEmpty else { return }
        let average = heights.reduce(0, +) / CGFloat(heights.count)
        let smoothed = estimatedRowHeight * 0.6 + average * 0.4
        estimatedRowHeight = min(max(smoothed, 24), 240)
    }
}

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

    /// A finger on the transcript always wins over tailing — unpin
    /// immediately so a layout pass mid-drag can't yank the offset back
    /// to the bottom while the user is reading scrollback.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isPinnedToBottom = false
    }

    /// Drag released without momentum — resume tailing if it ended near
    /// the bottom (within the same 44pt the pill logic uses).
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resumeTailingIfNearBottom(scrollView) }
    }

    /// Momentum settled — same near-bottom check as the direct release.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        resumeTailingIfNearBottom(scrollView)
    }

    /// Refuse the status-bar-tap scroll-to-top gesture: the quick-switcher
    /// pill sits just below the status bar, so near-miss taps were yanking
    /// the transcript to the oldest line instead of opening the switcher.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        false
    }

    /// Re-enter tailing mode when a user-initiated scroll settles near the
    /// bottom, and snap the remaining ≤44pt so "near the bottom" and
    /// "tailing" can't drift apart (the pin keeps asserting the exact
    /// bottom from here on).
    private func resumeTailingIfNearBottom(_ scrollView: UIScrollView) {
        guard ScrollAnchor.isNearBottom(
            contentHeight: scrollView.contentSize.height,
            offsetY: scrollView.contentOffset.y,
            containerHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom
        ) else { return }
        isPinnedToBottom = true
        // Back at the live edge: flush everything held back while reading
        // right now — the next model publish may be a while away on a quiet
        // channel — then glue the offset to the (new) bottom.
        refresh()
        pinToBottomIfNeeded()
    }
}
#endif
