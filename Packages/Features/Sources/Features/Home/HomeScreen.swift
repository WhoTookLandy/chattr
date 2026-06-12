import SwiftUI
import Accounts
import TwitchKit
import DesignSystem

/// The Home tab — the app's landing surface. Answers "who's live right
/// now?" the moment the app opens, instead of an empty chat screen that
/// points at a sheet.
///
/// Sections, top to bottom:
///   1. **Live now** — followed channels currently streaming, in Twitch's
///      descending-viewer-count order. Reuses `LiveStreamRow` (the same
///      component the full Following list uses) so Live-on-Home reads as
///      the same content at a different zoom level.
///   2. **Open chats** — one pill per open chat tab. Tapping resumes that
///      tab (switches to the Chats tab with it active).
///   3. **All follows** — pushes the full `ChannelListScreen` (Live/All
///      segments, search) as a navigation push, not a sheet.
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
                userProfiles: followsStore?.userProfiles ?? [:],
                liveLoadState: followsStore?.liveLoadState ?? .idle,
                openTabs: chatTabs?.tabs ?? [],
                followCount: followsStore?.totalFollowed,
                onStreamTap: { stream in
                    let profileURL = followsStore?.userProfiles[stream.userId]
                        .flatMap { URL(string: $0.profileImageUrl) }
                    openChannel?(stream: stream, profileImageURL: profileURL)
                },
                onResumeChat: onResumeChat
            )
            .navigationTitle("Home")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .allFollows:
                    ChannelListScreen(account: account, accountStore: accountStore)
                }
            }
            .refreshable {
                guard let store = followsStore else { return }
                await store.refreshLive(account: account, accountStore: accountStore)
            }
            // Fresh live data every time Home appears (tab switches
            // included) — same policy as the Following list.
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
    let userProfiles: [String: TwitchUser]
    let liveLoadState: FollowsStore.LoadState
    let openTabs: [ChatTab]
    /// Total follow count for the "All follows" row's badge; nil until the
    /// full list has loaded (the row just omits the number).
    let followCount: Int?
    let onStreamTap: (TwitchStream) -> Void
    let onResumeChat: (ChatTab) -> Void

    var body: some View {
        List {
            liveSection
            if !openTabs.isEmpty {
                openChatsSection
            }
            allFollowsSection
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    // MARK: - Live now

    @ViewBuilder
    private var liveSection: some View {
        Section {
            if liveStreams.isEmpty {
                liveEmptyContent
            } else {
                ForEach(liveStreams, id: \.userId) { stream in
                    Button {
                        onStreamTap(stream)
                    } label: {
                        LiveStreamRow(
                            stream: stream,
                            profile: userProfiles[stream.userId]
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            sectionHeader(liveStreams.isEmpty
                ? "Live now"
                : "Live now · \(liveStreams.count)")
        }
    }

    /// Inline placeholder for the Live section's loading / quiet / failed
    /// states. Compact rows (not full-screen `ContentUnavailableView`) —
    /// Home still has the chats + follows sections below doing useful work.
    @ViewBuilder
    private var liveEmptyContent: some View {
        switch liveLoadState {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking who's live…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        case .loaded:
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(.secondary)
                Text("Nobody you follow is live right now.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                Text("Couldn't load live channels. Pull to retry.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden)
        }
    }

    // MARK: - Open chats

    @ViewBuilder
    private var openChatsSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(openTabs) { tab in
                        Button {
                            onResumeChat(tab)
                        } label: {
                            Text(tab.displayName)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.fill.tertiary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .listRowSeparator(.hidden)
        } header: {
            sectionHeader("Open chats")
        }
    }

    // MARK: - All follows

    @ViewBuilder
    private var allFollowsSection: some View {
        Section {
            NavigationLink(value: HomeRoute.allFollows) {
                HStack {
                    Label("All follows", systemImage: "heart")
                    Spacer()
                    if let followCount {
                        Text("\(followCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
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
