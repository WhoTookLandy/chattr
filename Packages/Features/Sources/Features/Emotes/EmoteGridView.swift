import SwiftUI
import EmoteSources
import Nuke

#if canImport(UIKit)
import UIKit

/// High-performance `UICollectionView`-backed emote grid for iOS.
///
/// ## Why UIKit instead of SwiftUI `LazyVStack` + `LazyVGrid`
///
/// Nesting `LazyVGrid` inside `LazyVStack(pinnedViews: [.sectionHeaders])`
/// with 1,500–3,000 emotes defeats SwiftUI's laziness, materializes huge view
/// subtrees on open, and creates 60+ `LazyImage` / `AnimatedImageView`
/// hierarchies during scroll. A native `UICollectionView` gives us:
///   1. True O(visible cells) cell reuse with bare `UIImageView`s.
///   2. Synchronous Nuke RAM-cache hits (`caches: [.memory]`) in microseconds
///      with zero SwiftUI body churn and zero placeholder flash.
///   3. `UICollectionViewDataSourcePrefetching` warming upcoming rows ahead of
///      the user's finger.
///   4. Accurate, stutter-free section jumping and active-section tracking for
///      the category / subscribed-channel jump rail.
struct EmoteGridView: UIViewControllerRepresentable {
    let sections: [EmoteSection]
    /// Incremented whenever the user taps a pill in the quick-jump rail.
    let scrollTarget: ScrollTarget?
    let onSelect: (PickerEmote) -> Void
    let onInspect: (PickerEmote) -> Void
    let onActiveSectionChanged: (String) -> Void

    struct ScrollTarget: Equatable {
        let sectionId: String
        let token: Int
    }

    func makeUIViewController(context: Context) -> EmoteGridViewController {
        let vc = EmoteGridViewController()
        vc.onSelect = onSelect
        vc.onInspect = onInspect
        vc.onActiveSectionChanged = onActiveSectionChanged
        return vc
    }

    func updateUIViewController(_ vc: EmoteGridViewController, context: Context) {
        vc.onSelect = onSelect
        vc.onInspect = onInspect
        vc.onActiveSectionChanged = onActiveSectionChanged
        vc.update(sections: sections, scrollTarget: scrollTarget)
    }
}

// MARK: - View Controller

final class EmoteGridViewController: UIViewController {

    /// Unique across sections so the same emote appearing in both "Recently Used"
    /// and its home section never collides in `NSDiffableDataSourceSnapshot`.
    private struct ItemID: Hashable, Sendable {
        let sectionId: String
        let emoteId: String
    }

    var onSelect: ((PickerEmote) -> Void)?
    var onInspect: ((PickerEmote) -> Void)?
    var onActiveSectionChanged: ((String) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, ItemID>!
    private let prefetcher: ImagePrefetcher = {
        let p = ImagePrefetcher(destination: .memoryCache, maxConcurrentRequestCount: 6)
        p.priority = .high
        return p
    }()

    private var sections: [EmoteSection] = []
    private var sectionById: [String: EmoteSection] = [:]
    private var emoteByItemId: [ItemID: PickerEmote] = [:]
    private var lastScrollTargetToken: Int = -1
    private var currentActiveSectionId: String?
    private var isProgrammaticScrolling = false
    private let impactGenerator = UIImpactFeedbackGenerator(style: .light)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureCollectionView()
        configureDataSource()
        impactGenerator.prepare()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        prefetcher.stopPrefetching()
    }

    private func configureCollectionView() {
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: Self.makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        view.addSubview(collectionView)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.32
        collectionView.addGestureRecognizer(longPress)
    }

    private static func makeLayout() -> UICollectionViewLayout {
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.interSectionSpacing = 12

        return UICollectionViewCompositionalLayout(sectionProvider: { _, environment in
            let containerWidth = environment.container.effectiveContentSize.width
            let horizontalInset: CGFloat = 12
            let spacing: CGFloat = 6
            let usableWidth = max(200, containerWidth - horizontalInset * 2)
            // ~56pt target tile width → 6 columns on standard iPhones, 5 on SE,
            // 9–12 on iPad. Slightly wider than tall (56×50) gives wide 7TV
            // emotes breathing room without breaking uniform grid alignment.
            let columns = max(5, Int((usableWidth + spacing) / (56 + spacing)))

            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
                heightDimension: .absolute(50)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(50)
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize,
                repeatingSubitem: item,
                count: columns
            )
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 6, leading: horizontalInset, bottom: 8, trailing: horizontalInset
            )

            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(36)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            header.pinToVisibleBounds = true
            section.boundarySupplementaryItems = [header]
            return section
        }, configuration: configuration)
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<EmoteGridCell, ItemID> { [weak self] cell, _, itemId in
            guard let self, let emote = self.emoteByItemId[itemId] else { return }
            cell.configure(with: emote)
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<EmoteSectionHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let self, self.sections.indices.contains(indexPath.section) else { return }
            header.configure(with: self.sections[indexPath.section])
        }

        dataSource = UICollectionViewDiffableDataSource<String, ItemID>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemId in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: itemId)
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else { return nil }
            return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    func update(sections newSections: [EmoteSection], scrollTarget: EmoteGridView.ScrollTarget?) {
        loadViewIfNeeded()

        // Only rebuild & apply snapshot when the section list actually changed.
        if newSections != sections {
            let previousSectionsById = sectionById
            let previousEmoteByItemId = emoteByItemId

            sections = newSections
            var newSectionById: [String: EmoteSection] = [:]
            newSectionById.reserveCapacity(newSections.count)
            var newEmoteByItemId: [ItemID: PickerEmote] = [:]
            var changedItemIds: [ItemID] = []

            var snapshot = NSDiffableDataSourceSnapshot<String, ItemID>()
            for section in newSections {
                guard newSectionById[section.id] == nil else { continue }
                newSectionById[section.id] = section
                snapshot.appendSections([section.id])

                var seenInSection: Set<String> = []
                var itemIds: [ItemID] = []
                itemIds.reserveCapacity(section.emotes.count)
                for emote in section.emotes where seenInSection.insert(emote.id).inserted {
                    let itemId = ItemID(sectionId: section.id, emoteId: emote.id)
                    newEmoteByItemId[itemId] = emote
                    itemIds.append(itemId)
                    if let previous = previousEmoteByItemId[itemId], previous != emote {
                        changedItemIds.append(itemId)
                    }
                }
                snapshot.appendItems(itemIds, toSection: section.id)
            }

            if !changedItemIds.isEmpty {
                snapshot.reconfigureItems(changedItemIds)
            }

            sectionById = newSectionById
            emoteByItemId = newEmoteByItemId
            dataSource.apply(snapshot, animatingDifferences: false)

            // Refresh any visible section header whose metadata (title, badge,
            // avatar, or emote count) changed without its section ID changing.
            for (sectionIndex, section) in newSections.enumerated() {
                if let previous = previousSectionsById[section.id],
                   previous.title != section.title
                    || previous.badge != section.badge
                    || previous.avatarURL != section.avatarURL
                    || previous.emotes.count != section.emotes.count,
                   let header = collectionView.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader,
                    at: IndexPath(item: 0, section: sectionIndex)
                   ) as? EmoteSectionHeaderView {
                    header.configure(with: section)
                }
            }

            // Seed the first screenful into Nuke's memory cache immediately.
            prefetchLeadingEmotes(from: newSections)

            if let firstId = newSections.first?.id,
               currentActiveSectionId == nil || newSectionById[currentActiveSectionId!] == nil {
                currentActiveSectionId = firstId
            }
        }

        if let scrollTarget, scrollTarget.token != lastScrollTargetToken {
            lastScrollTargetToken = scrollTarget.token
            scrollToSection(id: scrollTarget.sectionId)
        }
    }

    private func prefetchLeadingEmotes(from sections: [EmoteSection]) {
        var urls: [URL] = []
        urls.reserveCapacity(48)
        for section in sections {
            for emote in section.emotes {
                guard !emote.isAnimated, let url = emote.imageURL else { continue }
                urls.append(url)
                if urls.count >= 48 {
                    prefetcher.startPrefetching(with: urls)
                    return
                }
            }
        }
        if !urls.isEmpty {
            prefetcher.startPrefetching(with: urls)
        }
    }

    private func scrollToSection(id sectionId: String) {
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        collectionView.layoutIfNeeded()
        let headerIndexPath = IndexPath(item: 0, section: sectionIndex)
        let targetY: CGFloat
        if let attrs = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: headerIndexPath
        ) {
            targetY = attrs.frame.minY - collectionView.adjustedContentInset.top
        } else if collectionView.numberOfItems(inSection: sectionIndex) > 0,
                  let attrs = collectionView.layoutAttributesForItem(at: headerIndexPath) {
            targetY = attrs.frame.minY - 36 - collectionView.adjustedContentInset.top
        } else {
            return
        }

        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(
            minY,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let clampedY = min(max(targetY, minY), maxY)
        currentActiveSectionId = sectionId
        if abs(collectionView.contentOffset.y - clampedY) > 1 {
            isProgrammaticScrolling = true
            collectionView.setContentOffset(CGPoint(x: 0, y: clampedY), animated: true)
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let itemId = dataSource.itemIdentifier(for: indexPath),
              let emote = emoteByItemId[itemId] else { return }
        if UserDefaults.standard.object(forKey: HapticSettings.enabledKey) as? Bool ?? true {
            impactGenerator.impactOccurred(intensity: 0.7)
        }
        onInspect?(emote)
    }

    private func updateActiveSectionFromScroll() {
        guard !isProgrammaticScrolling, !sections.isEmpty else { return }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top + 40
        let visiblePaths = collectionView.indexPathsForVisibleItems
        guard !visiblePaths.isEmpty else { return }

        var bestSection: Int?
        var bestY: CGFloat = .greatestFiniteMagnitude
        for path in visiblePaths {
            guard let attrs = collectionView.layoutAttributesForItem(at: path) else { continue }
            if attrs.frame.maxY >= visibleTop, attrs.frame.minY < bestY {
                bestY = attrs.frame.minY
                bestSection = path.section
            }
        }
        let chosen = bestSection ?? visiblePaths.min()?.section
        guard let sectionIndex = chosen, sections.indices.contains(sectionIndex) else { return }
        let sectionId = sections[sectionIndex].id
        guard sectionId != currentActiveSectionId else { return }
        currentActiveSectionId = sectionId
        onActiveSectionChanged?(sectionId)
    }
}

// MARK: - UICollectionViewDelegate & Prefetching

extension EmoteGridViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let itemId = dataSource.itemIdentifier(for: indexPath),
              let emote = emoteByItemId[itemId] else { return }
        if UserDefaults.standard.object(forKey: HapticSettings.enabledKey) as? Bool ?? true {
            impactGenerator.impactOccurred(intensity: 0.55)
        }
        if let cell = collectionView.cellForItem(at: indexPath) as? EmoteGridCell {
            cell.playTapPulse()
        }
        onSelect?(emote)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isProgrammaticScrolling = false
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateActiveSectionFromScroll()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isProgrammaticScrolling = false
        updateActiveSectionFromScroll()
    }
}

extension EmoteGridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let urls = staticURLs(for: indexPaths)
        guard !urls.isEmpty else { return }
        prefetcher.startPrefetching(with: urls)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let urls = staticURLs(for: indexPaths)
        guard !urls.isEmpty else { return }
        prefetcher.stopPrefetching(with: urls)
    }

    private func staticURLs(for indexPaths: [IndexPath]) -> [URL] {
        indexPaths.compactMap { path in
            guard let itemId = dataSource.itemIdentifier(for: path),
                  let emote = emoteByItemId[itemId],
                  !emote.isAnimated else { return nil }
            return emote.imageURL
        }
    }
}

// MARK: - EmoteGridCell

private final class EmoteGridCell: UICollectionViewCell {
    private let tileView = UIView()
    private let imageView = UIImageView()
    private let placeholderView = UIView()
    private let fallbackLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var currentURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        tileView.layer.cornerRadius = 10
        tileView.layer.cornerCurve = .continuous
        tileView.backgroundColor = .clear
        tileView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tileView)

        placeholderView.layer.cornerRadius = 8
        placeholderView.layer.cornerCurve = .continuous
        placeholderView.backgroundColor = UIColor.tertiarySystemFill
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        tileView.addSubview(placeholderView)

        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
        imageView.translatesAutoresizingMaskIntoConstraints = false
        tileView.addSubview(imageView)

        fallbackLabel.font = .systemFont(ofSize: 9, weight: .medium)
        fallbackLabel.textColor = .tertiaryLabel
        fallbackLabel.textAlignment = .center
        fallbackLabel.lineBreakMode = .byTruncatingTail
        fallbackLabel.isHidden = true
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        tileView.addSubview(fallbackLabel)

        NSLayoutConstraint.activate([
            tileView.topAnchor.constraint(equalTo: contentView.topAnchor),
            tileView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tileView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tileView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            placeholderView.centerXAnchor.constraint(equalTo: tileView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: tileView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 36),
            placeholderView.heightAnchor.constraint(equalToConstant: 36),

            imageView.topAnchor.constraint(equalTo: tileView.topAnchor, constant: 4),
            imageView.bottomAnchor.constraint(equalTo: tileView.bottomAnchor, constant: -4),
            imageView.leadingAnchor.constraint(equalTo: tileView.leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: tileView.trailingAnchor, constant: -4),

            fallbackLabel.centerYAnchor.constraint(equalTo: tileView.centerYAnchor),
            fallbackLabel.leadingAnchor.constraint(equalTo: tileView.leadingAnchor, constant: 3),
            fallbackLabel.trailingAnchor.constraint(equalTo: tileView.trailingAnchor, constant: -3),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.tileView.transform = self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.88, y: 0.88)
                    : .identity
                self.tileView.backgroundColor = self.isHighlighted
                    ? UIColor.secondarySystemFill
                    : .clear
            }
        }
    }

    func playTapPulse() {
        UIView.animate(withDuration: 0.08, delay: 0, options: [.allowUserInteraction]) {
            self.tileView.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
            self.tileView.backgroundColor = UIColor.secondarySystemFill
        } completion: { _ in
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                usingSpringWithDamping: 0.6,
                initialSpringVelocity: 0.8,
                options: [.allowUserInteraction]
            ) {
                self.tileView.transform = .identity
                self.tileView.backgroundColor = .clear
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        currentURL = nil
        imageView.image = nil
        placeholderView.isHidden = false
        fallbackLabel.isHidden = true
        tileView.transform = .identity
        tileView.backgroundColor = .clear
    }

    func configure(with emote: PickerEmote) {
        accessibilityLabel = emote.name
        fallbackLabel.text = emote.name

        guard let url = emote.imageURL else {
            loadTask?.cancel()
            loadTask = nil
            currentURL = nil
            imageView.image = nil
            placeholderView.isHidden = true
            fallbackLabel.isHidden = false
            return
        }

        // Same URL already loaded into this cell → keep it untouched.
        if currentURL == url, imageView.image != nil {
            placeholderView.isHidden = true
            fallbackLabel.isHidden = true
            return
        }

        loadTask?.cancel()
        currentURL = url

        if !emote.isAnimated {
            // Fast path (~95%+ of emotes: Twitch static, 7TV static_name, FFZ static, BTTV PNG).
            // Synchronous RAM-only lookup avoids disk I/O on the main thread
            // and renders immediately with zero placeholder flash.
            let request = ImageRequest(url: url)
            if let cached = ImagePipeline.shared.cache.cachedImage(for: request, caches: [.memory])?.image {
                imageView.image = cached
                placeholderView.isHidden = true
                fallbackLabel.isHidden = true
                return
            }

            imageView.image = nil
            placeholderView.isHidden = false
            fallbackLabel.isHidden = true

            loadTask = Task { @MainActor [weak self] in
                do {
                    let image = try await ImagePipeline.shared.image(for: request)
                    guard let self, !Task.isCancelled, self.currentURL == url else { return }
                    self.imageView.image = image
                    self.placeholderView.isHidden = true
                    self.fallbackLabel.isHidden = true
                } catch {
                    guard let self, !Task.isCancelled, self.currentURL == url else { return }
                    self.placeholderView.isHidden = true
                    self.fallbackLabel.isHidden = false
                }
            }
        } else {
            // Fallback for animated emotes with no separate static CDN file
            // (e.g. BTTV animated GIFs): decode poster frame only.
            let scale = max(traitCollection.displayScale, 2)
            let maxPixels = AnimatedEmoteDecoder.maxPixelSize(
                for: CGSize(width: 48, height: 42),
                scale: scale
            )
            let cache = DecodedAnimationCache.shared
            if let cached = cache.decoded(for: url, maxPixelSize: maxPixels, posterOnly: true)
                ?? cache.decoded(for: url, maxPixelSize: maxPixels, posterOnly: false) {
                imageView.image = UIImage(cgImage: cached.posterFrame)
                placeholderView.isHidden = true
                fallbackLabel.isHidden = true
                return
            }

            imageView.image = nil
            placeholderView.isHidden = false
            fallbackLabel.isHidden = true

            loadTask = Task { @MainActor [weak self] in
                do {
                    let decoded = try await AnimatedEmoteDecoder.shared.animation(
                        for: url,
                        maxPixelSize: maxPixels,
                        posterOnly: true
                    )
                    guard let self, !Task.isCancelled, self.currentURL == url else { return }
                    if let decoded {
                        self.imageView.image = UIImage(cgImage: decoded.posterFrame)
                        self.placeholderView.isHidden = true
                        self.fallbackLabel.isHidden = true
                    } else {
                        self.placeholderView.isHidden = true
                        self.fallbackLabel.isHidden = false
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.currentURL == url else { return }
                    self.placeholderView.isHidden = true
                    self.fallbackLabel.isHidden = false
                }
            }
        }
    }
}

// MARK: - Sticky Section Header

private final class EmoteSectionHeaderView: UICollectionReusableView {
    private let backdropView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let avatarView = UIImageView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let countLabel = UILabel()
    private let hairline = UIView()

    private var avatarTask: Task<Void, Never>?
    private var currentAvatarURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdropView)

        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 11
        avatarView.backgroundColor = UIColor.tertiarySystemFill
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: 22).isActive = true

        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        titleLabel.font = .systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .semibold
        )
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .secondaryLabel
        badgeLabel.backgroundColor = UIColor.tertiarySystemFill
        badgeLabel.layer.cornerRadius = 5
        badgeLabel.layer.cornerCurve = .continuous
        badgeLabel.clipsToBounds = true
        badgeLabel.textAlignment = .center
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .tertiaryLabel
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [avatarView, iconView, titleLabel, badgeLabel, UIView(), countLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdropView.contentView.addSubview(stack)

        hairline.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        backdropView.contentView.addSubview(hairline)

        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: backdropView.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: backdropView.contentView.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: backdropView.contentView.centerYAnchor),

            badgeLabel.heightAnchor.constraint(equalToConstant: 18),

            hairline.leadingAnchor.constraint(equalTo: backdropView.contentView.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: backdropView.contentView.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: backdropView.contentView.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        currentAvatarURL = nil
        avatarView.image = nil
    }

    func configure(with section: EmoteSection) {
        titleLabel.text = section.title
        countLabel.text = "\(section.emotes.count)"

        if let badge = section.badge, !badge.isEmpty {
            badgeLabel.text = "  \(badge)  "
            badgeLabel.isHidden = false
            applyBadgeTint(for: section.kind)
        } else {
            badgeLabel.isHidden = true
        }

        if let avatarURL = section.avatarURL,
           let request = ImageRequest.avatar(url: avatarURL, side: 22) {
            avatarView.isHidden = false
            iconView.isHidden = true
            loadAvatar(url: avatarURL, request: request)
        } else {
            avatarTask?.cancel()
            avatarTask = nil
            currentAvatarURL = nil
            avatarView.isHidden = true
            iconView.isHidden = false
            configureSymbol(for: section.kind)
        }
    }

    private func loadAvatar(url: URL, request: ImageRequest) {
        if currentAvatarURL == url, avatarView.image != nil { return }
        avatarTask?.cancel()
        currentAvatarURL = url
        if let cached = ImagePipeline.shared.cache.cachedImage(for: request, caches: [.memory])?.image {
            avatarView.image = cached
            return
        }
        avatarView.image = nil
        avatarTask = Task { @MainActor [weak self] in
            if let image = try? await ImagePipeline.shared.image(for: request) {
                guard let self, !Task.isCancelled, self.currentAvatarURL == url else { return }
                self.avatarView.image = image
            }
        }
    }

    private func configureSymbol(for kind: EmoteSection.Kind) {
        switch kind {
        case .recent:
            iconView.image = UIImage(systemName: "clock.fill")
            iconView.tintColor = .secondaryLabel
        case .currentChannelTwitch, .subscribedChannel:
            iconView.image = UIImage(systemName: "star.fill")
            iconView.tintColor = UIColor(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255, alpha: 1)
        case .twitchUnlocked:
            iconView.image = UIImage(systemName: "sparkles")
            iconView.tintColor = UIColor(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255, alpha: 1)
        case .twitchGlobal:
            iconView.image = UIImage(systemName: "globe")
            iconView.tintColor = UIColor(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255, alpha: 1)
        case .channelThirdParty(let source), .globalThirdParty(let source):
            iconView.image = UIImage(systemName: "face.smiling")
            iconView.tintColor = Self.tintColor(for: source)
        }
    }

    private func applyBadgeTint(for kind: EmoteSection.Kind) {
        let tint: UIColor
        switch kind {
        case .currentChannelTwitch, .subscribedChannel, .twitchUnlocked, .twitchGlobal:
            tint = UIColor(red: 0x91 / 255, green: 0x46 / 255, blue: 0xFF / 255, alpha: 1)
        case .channelThirdParty(let source), .globalThirdParty(let source):
            tint = Self.tintColor(for: source)
        case .recent:
            tint = .secondaryLabel
        }
        badgeLabel.textColor = tint
        badgeLabel.backgroundColor = tint.withAlphaComponent(0.14)
    }

    private static func tintColor(for source: Emote.Source) -> UIColor {
        switch source {
        case .sevenTV: return UIColor(red: 0x29 / 255, green: 0xB6 / 255, blue: 0xF6 / 255, alpha: 1)
        case .bttv:    return UIColor(red: 0xD5 / 255, green: 0x00 / 255, blue: 0x1C / 255, alpha: 1)
        case .ffz:     return UIColor(red: 0x76 / 255, green: 0x76 / 255, blue: 0xFF / 255, alpha: 1)
        }
    }
}

#else

/// macOS SwiftUI fallback grid with `ScrollViewReader` section jumping.
struct EmoteGridView: View {
    let sections: [EmoteSection]
    let scrollTarget: ScrollTarget?
    let onSelect: (PickerEmote) -> Void
    let onInspect: (PickerEmote) -> Void
    let onActiveSectionChanged: (String) -> Void

    struct ScrollTarget: Equatable {
        let sectionId: String
        let token: Int
    }

    private let columns = [GridItem(.adaptive(minimum: 54), spacing: 6)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(section.emotes) { emote in
                                    Button {
                                        onSelect(emote)
                                    } label: {
                                        EmoteCell(emote: emote, size: 42)
                                            .frame(width: 54, height: 48)
                                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .help(emote.name)
                                    .contextMenu {
                                        Button("Insert") { onSelect(emote) }
                                        Button("Inspect") { onInspect(emote) }
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        } header: {
                            HStack(spacing: 6) {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(section.emotes.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(.bar)
                            .id(section.id)
                            .onAppear {
                                onActiveSectionChanged(section.id)
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(target.sectionId, anchor: .top)
                }
            }
        }
    }
}

#endif
