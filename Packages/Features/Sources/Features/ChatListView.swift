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
