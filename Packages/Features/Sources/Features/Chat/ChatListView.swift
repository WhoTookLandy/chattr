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
            DispatchQueue.main.async { isAtBottom = atBottom }
        }
        return vc
    }

    func updateUIViewController(_ vc: ChatListViewController, context: Context) {
        // rowContent captures fresh per-body closures each update — refresh it
        // so cells built after this call use current state.
        vc.rowContent = rowContent
        vc.extendsToTop = extendsToTop
        vc.update(lines: lines, scrollToBottomToken: scrollToBottomToken)
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
    private var isPinnedToBottom = true

    /// Last-seen scroll-to-bottom token — the jump-to-bottom pill increments the
    /// value to request a scroll; we act only when it changes.
    private var lastScrollToBottomToken = 0

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
        // Bottom inset tighter than top: the compose bar's own padding
        // already provides breathing room below the last message.
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16)
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

    /// Diff the new lines against the last-applied set, apply the structural
    /// snapshot (insert/delete/move derived from the id order), then explicitly
    /// reconfigure cells whose `ChatLine` value changed but whose id did not.
    func update(lines newLines: [ChatLine], scrollToBottomToken: Int) {
        let delta = ChatListDiff.compute(old: lastLines, new: newLines)

        // Jump-to-bottom pill fired — enter tailing mode BEFORE the snapshot
        // applies so the pin below (and every subsequent layout pass) lands
        // this same update. The per-pass re-pin is what makes the jump
        // converge on the true bottom even when every row between here and
        // there still has only its estimated height.
        if scrollToBottomToken != lastScrollToBottomToken {
            lastScrollToBottomToken = scrollToBottomToken
            isPinnedToBottom = true
        }

        // Only needed when scrolled up AND rows are leaving above us.
        let anchor: (id: String, distanceFromTop: CGFloat)? =
            (!isPinnedToBottom && !delta.removed.isEmpty) ? currentTopAnchor() : nil

        lastLines = newLines
        linesByID = newLines.reduce(into: [:]) { $0[$1.id] = $1 }

        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(delta.orderedIDs, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)

        if !delta.reconfigured.isEmpty {
            var reconfig = dataSource.snapshot()
            reconfig.reconfigureItems(delta.reconfigured)
            dataSource.apply(reconfig, animatingDifferences: false)
        }

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

    /// Status-bar tap scrolls to the top — that's an explicit "leave the
    /// live edge", so unpin before the system scroll starts.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        isPinnedToBottom = false
        return true
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
        pinToBottomIfNeeded()
    }
}
#endif
