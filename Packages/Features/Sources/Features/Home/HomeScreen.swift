import SwiftUI
import Accounts
import TwitchKit
import DesignSystem
import Nuke
import NukeUI

/// The Home tab — the app's landing surface. Answers "who's live right
/// now?" the moment the app opens, instead of an empty chat screen that
/// points at a sheet.
///
/// Sections, top to bottom:
///   1. **Open chats** — one avatar circle per open chat tab (story-rail
///      style): a red ring + LIVE caption when that channel is live, a
///      "2d ago" last-live caption when it isn't. Tapping resumes that tab
///      (switches to the Chats tab with it active). First because "get back
///      to my chat" is the highest-intent action and must cost zero
///      scrolling.
///   2. **Live now** — category chips (All + each category with someone
///      live, busiest first), then a PREVIEW of followed channels currently
///      streaming: the top `featuredCount` as full-width `LiveStreamCard`s,
///      the rest as compact `LiveStreamRow`s, capped at `liveDisplayCap`.
///      The section header's "See all" pushes the full `ChannelListScreen`
///      (Live segment preselected; its title menu switches to All, and it
///      carries search + sorting).
///
/// Data comes from the environment stores RootView already owns
/// (`FollowsStore`, `ChannelStatusStore`, `ChatTabsModel`). Home's only
/// extra fetch is the open tabs' status (for last-live captions), batched
/// and throttled in `ChannelStatusStore`.
///
/// Split into a thin store-backed wrapper (this type) and the
/// presentational `HomeContent` so previews and future tests can render
/// the layout from plain values without a signed-in account.
public struct HomeScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    /// Injected by AppShell: makes `tab` the active chat tab and switches
    /// the app to the Chats tab. Kept as a closure (not environment) —
    /// only Home needs it, and the tab-selection state lives in AppShell.
    private let onResumeChat: (ChatTab) -> Void

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.chatTabs) private var chatTabs
    @Environment(\.openChannel) private var openChannel

    public init(
        account: Account,
        accountStore: AccountStore,
        onResumeChat: @escaping (ChatTab) -> Void
    ) {
        self.account = account
        self.accountStore = accountStore
        self.onResumeChat = onResumeChat
    }

    private var openChannelIds: [String] {
        (chatTabs?.tabs ?? []).compactMap { $0.channels.first?.channelId }
    }

    public var body: some View {
        NavigationStack {
            HomeContent(
                liveStreams: followsStore?.liveStreamsOrdered ?? [],
                profileImageURLs: followsStore?.profileImageURLs ?? [:],
                liveLoadState: followsStore?.liveLoadState ?? .idle,
                openTabs: chatTabs?.tabs ?? [],
                openTabStatuses: channelStatus?.statuses ?? [:],
                onStreamTap: { stream in
                    let profileURL = followsStore?.profileImageURLs[stream.userId]
                    openChannel?(stream: stream, profileImageURL: profileURL)
                },
                onResumeChat: onResumeChat
            )
            .navigationTitle("Home")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .allFollows:
                    // Live preselected: the push comes from the Live now
                    // header's "See all", so landing on Live is the
                    // continuation the tap promised. The title menu
                    // switches to All from there.
                    ChannelListScreen(
                        account: account,
                        accountStore: accountStore,
                        initialMode: .live
                    )
                }
            }
            .refreshable {
                // Explicit user intent — bypass the staleness throttles.
                // Sequential, not `async let`: `Account` is a non-Sendable
                // SwiftData model and can't cross into child tasks.
                await followsStore?.refreshLive(account: account, accountStore: accountStore, force: true)
                await channelStatus?.refresh(
                    channelIds: openChannelIds, account: account, accountStore: accountStore, force: true
                )
            }
            // Live data whenever Home appears (tab switches included) —
            // same policy as the Following list. Throttled + coalesced in
            // the stores, so a recent refresh makes this a no-op.
            .task {
                guard let store = followsStore else { return }
                await store.refreshLive(account: account, accountStore: accountStore)
            }
            .task(id: openChannelIds) {
                await channelStatus?.refresh(
                    channelIds: openChannelIds, account: account, accountStore: accountStore
                )
            }
        }
    }
}

/// Navigation routes Home can push. An enum (not a bare Bool) so future
/// destinations (a category page, a channel profile) slot in without
/// re-plumbing the `navigationDestination`.
enum HomeRoute: Hashable {
    case allFollows
}

/// Presentational layout for the Home tab. Everything arrives as plain
/// values — no stores, no account — so `#Preview` can drive every state.
struct HomeContent: View {
    let liveStreams: [TwitchStream]
    let profileImageURLs: [String: URL]
    let liveLoadState: FollowsStore.LoadState
    let openTabs: [ChatTab]
    /// Status for open tabs' channels (live for unfollowed channels,
    /// last-live for offline ones). Empty in previews.
    var openTabStatuses: [String: ChannelStatusStore.Status] = [:]
    let onStreamTap: (TwitchStream) -> Void
    let onResumeChat: (ChatTab) -> Void

    /// Category chip selection; nil = All.
    @State private var selectedCategory: String?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if !openTabs.isEmpty {
                    openChatsSection
                }
                liveSection
            }
            .listStyle(.plain)
            // Rows stay transparent so the shared chat surface reads through;
            // the surface itself is drawn behind the list below. Same flat
            // `Color.chatSurface` the chat screen uses, so Home and Chats share
            // one background world instead of Home wearing a tinted gradient.
            .scrollContentBackground(.hidden)
            .background(Color.chatSurface.ignoresSafeArea())
            // Hard top edge: a defined boundary under the title. The soft
            // style let scrolled thumbnails ghost through the bar area,
            // which read as smudge over a media-heavy feed. Bottom stays
            // soft — content fading toward the tab bar is fine.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            #if DEBUG
            // `-uiPreviewScrolled` jumps the list to the bottom so the
            // design-review harness can screenshot the scrolled-state top
            // edge without driving the UI. Same pattern as
            // `-uiPreviewChatOpen` in UIPreviewRoot.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-uiPreviewScrolled"),
                      let last = displayedStreams.last else { return }
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(last.userId, anchor: .bottom)
            }
            #endif
        }
    }

    /// Streams shown in the Live now preview, after the featured cards.
    /// Six ≈ two cards + four rows — enough to answer "anything good on?"
    /// without burying the rest of the app.
    private static let liveDisplayCap = 6

    /// Leading streams that get the full-width card treatment.
    private static let featuredCount = 2

    /// Channel ids currently live — followed streams plus any open tab the
    /// status store has seen live (e.g. opened from search, not followed).
    private var liveChannelIds: Set<String> {
        var ids = Set(liveStreams.map(\.userId))
        for (id, status) in openTabStatuses where status.isLive { ids.insert(id) }
        return ids
    }

    // MARK: - Categories

    /// Categories with at least one live followed channel, busiest (total
    /// viewers) first. Chips only appear when there are two or more —
    /// one chip would filter nothing.
    private var categories: [String] {
        var totals: [String: Int] = [:]
        for stream in liveStreams where !stream.gameName.isEmpty {
            totals[stream.gameName, default: 0] += stream.viewerCount
        }
        guard totals.count >= 2 else { return [] }
        return totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// The selection, ignored once its category has nobody live.
    private var activeCategory: String? {
        guard let selectedCategory, categories.contains(selectedCategory) else { return nil }
        return selectedCategory
    }

    private var filteredStreams: [TwitchStream] {
        guard let activeCategory else { return liveStreams }
        return liveStreams.filter { $0.gameName == activeCategory }
    }

    private var displayedStreams: ArraySlice<TwitchStream> {
        filteredStreams.prefix(Self.liveDisplayCap)
    }

    // MARK: - Live now

    @ViewBuilder
    private var liveSection: some View {
        Section {
            if liveStreams.isEmpty {
                liveEmptyContent
            } else {
                if !categories.isEmpty {
                    categoryChips
                }
                let shown = Array(displayedStreams)
                ForEach(Array(shown.enumerated()), id: \.element.userId) { index, stream in
                    Button {
                        onStreamTap(stream)
                    } label: {
                        if index < Self.featuredCount {
                            LiveStreamCard(
                                stream: stream,
                                profileImageURL: profileImageURLs[stream.userId]
                            )
                        } else {
                            LiveStreamRow(
                                stream: stream,
                                profileImageURL: profileImageURLs[stream.userId]
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(index < Self.featuredCount ? .hidden : .automatic)
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader("Live now")
                Spacer()
                // The single gateway to the full browse screen (Following —
                // Live/All segments, search, sorting). A header link, the
                // standard iOS "See all" placement, instead of a trailing
                // list row that read as just another stream.
                NavigationLink(value: HomeRoute.allFollows) {
                    HStack(spacing: 2) {
                        Text(liveStreams.count > Self.liveDisplayCap
                             ? "See all \(liveStreams.count)"
                             : "See all")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .textCase(nil)
            }
        }
    }

    /// All / per-category filter chips (Twitch Home's "All · Just Chatting
    /// · IRL" row), scoped to the Live now preview.
    private var categoryChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", isSelected: activeCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(categories, id: \.self) { category in
                    chip(category, isSelected: activeCategory == category) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
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

    /// Inline placeholder for the Live section's loading / quiet / failed
    /// states. Compact rows (not full-screen `ContentUnavailableView`) —
    /// Home still has the chats + follows sections below doing useful work.
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
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    // MARK: - Open chats

    @ViewBuilder
    private var openChatsSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(openTabs) { tab in
                        Button {
                            onResumeChat(tab)
                        } label: {
                            openChatCircle(for: tab)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } header: {
            sectionHeader("Open chats")
        }
    }

    /// Story-rail entry for one open chat tab: a large avatar with the
    /// name underneath, a red ring + "LIVE" caption when the channel is
    /// live, and a "2d ago" last-live caption when it isn't (Twitch's
    /// "Streamed 2 days ago").
    private func openChatCircle(for tab: ChatTab) -> some View {
        let channelId = tab.channels.first?.channelId
        let isLive = tab.channels.contains { liveChannelIds.contains($0.channelId) }
        let lastLive = channelId.flatMap { openTabStatuses[$0]?.lastLiveAt }
        return VStack(spacing: 4) {
            LazyImage(request: ImageRequest.avatar(url: tab.profileImageURL, side: 56)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(Circle())
            .padding(3)
            .overlay {
                if isLive {
                    Circle().strokeBorder(.red, lineWidth: 2.5)
                }
            }
            Text(tab.displayName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Group {
                if isLive {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                } else if let lastLive {
                    Text(StreamFormatting.lastLiveShort(lastLive))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    // Reserve the caption line so names stay aligned.
                    Text(" ").font(.caption2)
                }
            }
            .lineLimit(1)
        }
        .frame(width: 68)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: tab, isLive: isLive, lastLive: lastLive))
    }

    private func accessibilityLabel(for tab: ChatTab, isLive: Bool, lastLive: Date?) -> String {
        if isLive { return "\(tab.displayName), live" }
        if let lastLive { return "\(tab.displayName), offline, \(StreamFormatting.lastLive(lastLive))" }
        return tab.displayName
    }

    // MARK: - Shared

    /// Plain-List section headers default to uppercased caption text;
    /// this keeps them sentence-case and slightly larger, matching the
    /// inlineLarge title's tone.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}
