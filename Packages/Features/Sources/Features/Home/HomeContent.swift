import SwiftUI
import TwitchKit
import DesignSystem

/// Home → Live. Presentational feed with a top horizontal rail of recently
/// streamed followed channels, category filter chips, and a consistent
/// full-bleed edge-to-edge live stream feed whose focused card plays a muted
/// live HLS video preview as you scroll.
struct HomeContent: View {
    let liveStreams: [TwitchStream]
    let profileImageURLs: [String: URL]
    let liveLoadState: FollowsStore.LoadState
    var recentChannels: [RecentChannelItem] = []
    /// Whether Home → Live is currently the visible foreground destination.
    /// Drives live video previews so leaving Home stops playback at once.
    var isActive: Bool = true
    /// The stream card was tapped (`.implicit`) or a quick-menu action chose
    /// how to watch (`.explicit`).
    let onStreamTap: (TwitchStream, ChatOpenIntent) -> Void
    var onRecentChannelTap: (RecentChannelItem, ChatOpenIntent) -> Void = { _, _ in }
    var onRecentChannelAppear: (String) -> Void = { _ in }

    /// Category chip selection; nil = All.
    @State private var selectedCategory: String?

    #if os(iOS)
    @Environment(\.playback) private var playback
    @AppStorage(PlaybackPreferences.homePreviewKey) private var homePreviewMode: HomePreviewMode = .wiFiOnly
    @State private var previewController = HomeFeedPreviewController()

    private nonisolated static let feedCoordinateSpace = "homeLiveFeed"

    /// A floating video mini player already owns a live video decoder; keep
    /// the inline feed on static thumbnails while it's showing. An audio-only
    /// mini player does NOT block muted visual previews (matching Twitch).
    private var hasActiveVideoMiniPlayer: Bool {
        guard let playback, playback.isPlaying else { return false }
        return !playback.audioOnly || playback.controller.nativeFailed
    }
    #endif

    var body: some View {
        let feed = liveFeed
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !recentChannels.isEmpty {
                        RecentChannelsRail(
                            items: recentChannels,
                            onTap: { item, intent in
                                #if os(iOS)
                                previewController.stop()
                                #endif
                                onRecentChannelTap(item, intent)
                            },
                            onCardAppear: onRecentChannelAppear
                        )
                    }

                    if !feed.categories.isEmpty {
                        categoryChips(feed)
                    }

                    if liveStreams.isEmpty {
                        liveEmptyContent
                    } else {
                        ForEach(feed.displayedStreams, id: \.userId) { stream in
                            liveCard(for: stream)
                                .id(stream.userId)
                        }
                    }
                }
                // Extra breathing room above the floating tab bar / mini player.
                .padding(.bottom, 24)
            }
            .background(Color.chatSurface.ignoresSafeArea())
            // Hard top edge: a defined boundary under the section bar so
            // scrolled video frames never ghost behind the tabs.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #if os(iOS)
            .coordinateSpace(.named(Self.feedCoordinateSpace))
            .onGeometryChange(for: CGFloat.self) { geo in
                geo.size.height
            } action: { height in
                previewController.updateViewportHeight(height)
            }
            .onAppear {
                previewController.attach(playback: playback)
                previewController.setVideoMiniPlayerActive(hasActiveVideoMiniPlayer)
                previewController.updateStreams(feed.displayedStreams)
                previewController.setSurfaceActive(isActive)
            }
            .onDisappear {
                previewController.setSurfaceActive(false)
            }
            .onChange(of: isActive) { _, active in
                previewController.setSurfaceActive(active)
            }
            .onChange(of: hasActiveVideoMiniPlayer) { _, videoActive in
                previewController.setVideoMiniPlayerActive(videoActive)
            }
            .onChange(of: homePreviewMode) { _, _ in
                previewController.refreshPolicy()
            }
            .onChange(of: feed.displayedStreams.map(\.userId)) { _, _ in
                previewController.updateStreams(feed.displayedStreams)
            }
            #endif
            #if DEBUG
            // `-uiPreviewScrolled` jumps the feed to the bottom so the
            // design-review harness can screenshot the scrolled-state top
            // edge without driving the UI.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-uiPreviewScrolled"),
                      let last = feed.displayedStreams.last else { return }
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(last.userId, anchor: .bottom)
            }
            #endif
        }
    }

    @ViewBuilder
    private func liveCard(for stream: TwitchStream) -> some View {
        let handleOpen: (ChatOpenIntent) -> Void = { intent in
            #if os(iOS)
            previewController.stop()
            #endif
            onStreamTap(stream, intent)
        }

        #if os(iOS)
        LiveStreamCard(
            stream: stream,
            profileImageURL: profileImageURLs[stream.userId],
            onOpen: handleOpen,
            previewController: previewController
        )
        .channelPreviewMenu(
            name: stream.userName,
            profileImageURL: profileImageURLs[stream.userId],
            stream: stream,
            open: handleOpen
        )
        .onGeometryChange(for: CGRect.self) { geo in
            geo.frame(in: .named(Self.feedCoordinateSpace))
        } action: { frame in
            previewController.reportCardFrame(streamID: stream.userId, minY: frame.minY, maxY: frame.maxY)
        }
        .onDisappear {
            previewController.clearCardFrame(streamID: stream.userId)
        }
        #else
        LiveStreamCard(
            stream: stream,
            profileImageURL: profileImageURLs[stream.userId],
            onOpen: handleOpen
        )
        .channelPreviewMenu(
            name: stream.userName,
            profileImageURL: profileImageURLs[stream.userId],
            stream: stream,
            open: handleOpen
        )
        #endif
    }

    // MARK: - Categories

    /// What one body pass shows, derived from `liveStreams` and the chip
    /// selection.
    private struct LiveFeed {
        /// Categories with at least one live followed channel, busiest
        /// (total viewers) first. Chips only appear when there are two or
        /// more — one chip would filter nothing.
        let categories: [String]
        /// The selection, ignored once its category has nobody live.
        let activeCategory: String?
        /// Every live followed channel (in the selected category).
        let displayedStreams: [TwitchStream]
    }

    private var liveFeed: LiveFeed {
        var totals: [String: Int] = [:]
        for stream in liveStreams where !stream.gameName.isEmpty {
            totals[stream.gameName, default: 0] += stream.viewerCount
        }
        let categories = totals.count >= 2
            ? totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            : []
        var activeCategory: String?
        if let selectedCategory, categories.contains(selectedCategory) {
            activeCategory = selectedCategory
        }
        var displayedStreams = liveStreams
        if let activeCategory {
            displayedStreams = liveStreams.filter { $0.gameName == activeCategory }
        }
        return LiveFeed(
            categories: categories,
            activeCategory: activeCategory,
            displayedStreams: displayedStreams
        )
    }

    /// All / per-category filter chips ("All · Just Chatting · IRL").
    private func categoryChips(_ feed: LiveFeed) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: feed.activeCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(feed.categories, id: \.self) { category in
                    chip(category, isSelected: feed.activeCategory == category) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
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

    /// Inline placeholder for the Live feed's loading / quiet / failed states.
    @ViewBuilder
    private var liveEmptyContent: some View {
        Group {
            switch liveLoadState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking who's live…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            case .loaded:
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .foregroundStyle(.secondary)
                    Text("Nobody you follow is live right now.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            case .failed:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text("Couldn't load live channels. Pull to retry.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }
}
