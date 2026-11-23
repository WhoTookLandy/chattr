import SwiftUI
import TwitchKit
import DesignSystem

/// Full-bleed list of live followed streams, reached by tapping "See all" on
/// Search's Live Follows rail or tapping a card in Browse Categories.
///
/// Uses the same monochrome category chips and `Color.chatSurface` canvas as
/// `HomeContent` so Search and Home share one visual language.
struct SearchCategoryStreamsScreen: View {
    let initialCategory: String?
    let onSelectStream: (TwitchStream, URL?, ChatOpenIntent) -> Void

    @Environment(\.followsStore) private var followsStore
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    @State private var selectedCategory: String?

    init(
        initialCategory: String?,
        onSelectStream: @escaping (TwitchStream, URL?, ChatOpenIntent) -> Void
    ) {
        self.initialCategory = initialCategory
        self.onSelectStream = onSelectStream
        self._selectedCategory = State(initialValue: initialCategory)
    }

    private var liveFollows: [TwitchStream] {
        followsStore?.liveStreamsOrdered ?? []
    }

    private var categories: [SearchCategorySummary] {
        SearchBrowseCatalog.categories(from: liveFollows)
    }

    private var activeCategory: String? {
        guard let selectedCategory,
              categories.contains(where: { $0.name == selectedCategory }) else {
            return nil
        }
        return selectedCategory
    }

    private var displayedStreams: [TwitchStream] {
        SearchBrowseCatalog.streams(in: activeCategory, from: liveFollows)
    }

    private var bottomClearance: CGFloat {
        #if os(iOS)
        playback?.isPlaying == true ? 96 : 24
        #else
        24
        #endif
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if categories.count > 1 {
                    categoryChips
                }

                if displayedStreams.isEmpty {
                    ContentUnavailableView(
                        "No live channels",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("None of your followed channels are live here right now.")
                    )
                    .padding(.top, 48)
                } else {
                    ForEach(Array(displayedStreams.enumerated()), id: \.element.userId) { index, stream in
                        let profileURL = followsStore?.profileImageURLs[stream.userId]
                        Button {
                            onSelectStream(stream, profileURL, .implicit)
                        } label: {
                            SearchChannelRow(
                                displayName: stream.userName,
                                login: stream.userLogin,
                                profileImageURL: profileURL,
                                stream: stream
                            )
                        }
                        .buttonStyle(.plain)
                        .channelPreviewMenu(
                            name: stream.userName,
                            profileImageURL: profileURL,
                            stream: stream,
                            open: { intent in onSelectStream(stream, profileURL, intent) }
                        )

                        if index < displayedStreams.count - 1 {
                            Divider()
                                .padding(.leading, 70)
                        }
                    }
                }
            }
            .padding(.bottom, bottomClearance)
        }
        .background(Color.chatSurface.ignoresSafeArea())
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .navigationTitle(activeCategory ?? "Live Follows")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isSelected: activeCategory == nil) {
                    withAnimation(.snappy(duration: 0.2)) { selectedCategory = nil }
                }
                ForEach(categories) { category in
                    chip(title: category.name, isSelected: activeCategory == category.name) {
                        withAnimation(.snappy(duration: 0.2)) { selectedCategory = category.name }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .background(
                    isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary.opacity(0.15)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
