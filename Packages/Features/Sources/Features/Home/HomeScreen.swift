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
///      style), with a red dot when that channel is live. Tapping resumes
///      that tab (switches to the Chats tab with it active). First because
///      "get back to my chat" is the highest-intent action and must cost
///      zero scrolling.
///   2. **Live now** — a PREVIEW of followed channels currently streaming,
///      capped at `liveDisplayCap` rows in Twitch's descending-viewer-count
///      order, followed by a "Show all" row that pushes the full
///      `ChannelListScreen` (Live segment preselected; its title menu
///      switches to All, and it carries search + sorting). Home stays a
///      glanceable landing page; the browse-everything job lives on one
///      dedicated screen instead of being duplicated here.
///
/// Data comes from the environment stores RootView already owns
/// (`FollowsStore`, `ChatTabsModel`) — Home adds no new fetching, it's a
/// new window onto data the app already has.
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

    public var body: some View {
        NavigationStack {
            HomeContent(
                liveStreams: followsStore?.liveStreamsOrdered ?? [],
                profileImageURLs: followsStore?.profileImageURLs ?? [:],
                liveLoadState: followsStore?.liveLoadState ?? .idle,
                openTabs: chatTabs?.tabs ?? [],
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
                    // Live preselected: the push comes from the live
                    // preview's "Show all" row, so landing on Live is the
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
                guard let store = followsStore else { return }
                // Explicit user intent — bypass the staleness throttle.
                await store.refreshLive(account: account, accountStore: accountStore, force: true)
            }
            // Live data whenever Home appears (tab switches included) —
            // same policy as the Following list. Throttled + coalesced in
            // FollowsStore, so a recent refresh makes this a no-op.
            .task {
                guard let store = followsStore else { return }
                await store.refreshLive(account: account, accountStore: accountStore)
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
    let onStreamTap: (TwitchStream) -> Void
    let onResumeChat: (ChatTab) -> Void

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
                      let last = liveStreams.prefix(Self.liveDisplayCap).last else { return }
                try? await Task.sleep(for: .milliseconds(500))
                proxy.scrollTo(last.userId, anchor: .bottom)
            }
            #endif
        }
    }

    /// Rows shown in the Live now preview before the "Show all" row takes
    /// over. Five ≈ one screenful under the chats rail — enough to answer
    /// "anything good on?" without burying the rest of the app.
    private static let liveDisplayCap = 5

    /// Channel ids currently live — drives the red dot on open-chat
    /// avatars. Derived, not stored: `liveStreams` is already the source
    /// of truth.
    private var liveChannelIds: Set<String> {
        Set(liveStreams.map(\.userId))
    }

    // MARK: - Live now

    @ViewBuilder
    private var liveSection: some View {
        Section {
            if liveStreams.isEmpty {
                liveEmptyContent
            } else {
                ForEach(liveStreams.prefix(Self.liveDisplayCap), id: \.userId) { stream in
                    Button {
                        onStreamTap(stream)
                    } label: {
                        LiveStreamRow(
                            stream: stream,
                            profileImageURL: profileImageURLs[stream.userId]
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                showAllRow
            }
        } header: {
            sectionHeader("Live now")
        }
    }

    /// Footer of the live preview: the single gateway to the full browse
    /// screen (Following — Live/All segments, search, sorting). One entry
    /// point instead of the previous heart-toolbar-button + list-row pair.
    private var showAllRow: some View {
        NavigationLink(value: HomeRoute.allFollows) {
            HStack {
                Text(liveStreams.count > Self.liveDisplayCap
                    ? "Show all \(liveStreams.count) live"
                    : "All follows")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                Spacer()
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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
    /// name underneath, plus a red dot when the channel is live. The
    /// avatar carries the recognition load — same visual grammar as the
    /// thumbnails below, unlike the gray text capsules this replaced
    /// (which read as filter chips, not destinations).
    private func openChatCircle(for tab: ChatTab) -> some View {
        let isLive = tab.channels.contains { liveChannelIds.contains($0.channelId) }
        return VStack(spacing: 6) {
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
            .overlay(alignment: .bottomTrailing) {
                if isLive {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        // Background-colored ring separates the dot from
                        // the avatar regardless of its edge colors.
                        .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                }
            }
            Text(tab.displayName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(width: 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isLive ? "\(tab.displayName), live" : tab.displayName)
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
