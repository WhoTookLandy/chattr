import SwiftUI
import Accounts
import TwitchKit
import Core
import DesignSystem
import os

private let logger = AppLogger.make("Features.ChannelList")

/// Top-level Follows tab content.
///
/// Two segmented views:
///   - **Live** (default): currently-streaming channels, refetched per visit
///     and on pull-to-refresh. Backed by `FollowsStore.liveStreamsOrdered`.
///   - **All**: full follow list (live + offline), cached once per account.
///     Backed by `FollowsStore.channels` + `liveStreams` (dict) for badges.
///
/// The two views share `searchText` so typing on Live and switching to All
/// keeps the filter. The selected view is persisted via `@AppStorage` so it
/// survives navigation away and back.
public struct ChannelListScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    @Environment(\.followsStore) private var followsStore
    @Environment(\.openChannel) private var openChannel
    @Environment(\.dismiss) private var dismiss

    @State private var showingSignOutConfirm = false
    @State private var searchText: String = ""
    @State private var errorMessage: String?
    /// Presents the add-channel sheet (search + manual entry) for opening
    /// channels that aren't in the follow list.
    @State private var showingAddChannel = false
    /// Guards the failed-state Sign Out button against double-taps during an
    /// in-flight signout. Mirrors SettingsScreen's same-named state — both
    /// sign-out entry points should behave identically.
    @State private var isSigningOut = false

    @AppStorage("followsViewMode") private var rawViewMode: String = ViewMode.live.rawValue

    /// How the live segment is ordered. Viewer count (Twitch's own order)
    /// is the default; the alternatives answer "what just went live?" and
    /// "find the channel I'm thinking of" respectively. Session-scoped
    /// (`@State`, not `@AppStorage`) — a sort is a momentary lens, and
    /// resetting to the canonical order on the next visit is less
    /// surprising than a sticky obscure sort.
    enum LiveSort: String, CaseIterable {
        case viewers, recentlyStarted, name

        var displayName: String {
            switch self {
            case .viewers:         return "Viewers"
            case .recentlyStarted: return "Recently started"
            case .name:            return "Name"
            }
        }
    }

    @State private var liveSort: LiveSort = .viewers

    public enum ViewMode: String, CaseIterable {
        case live, all

        var displayName: String {
            switch self {
            case .live: return "Live"
            case .all:  return "All"
            }
        }
    }

    /// When non-nil, overrides the persisted segment on first appear —
    /// e.g. Home's "Show all live" row pushes with `.live` so the push is
    /// a continuation of the preview the user tapped, regardless of which
    /// segment they last left this screen on.
    private let initialMode: ViewMode?

    public init(
        account: Account,
        accountStore: AccountStore,
        initialMode: ViewMode? = nil
    ) {
        self.account = account
        self.accountStore = accountStore
        self.initialMode = initialMode
    }

    // MARK: - Convenience accessors

    private var channels: [FollowedChannel] { followsStore?.channels ?? [] }
    private var liveStreamsDict: [String: TwitchStream] { followsStore?.liveStreams ?? [:] }
    private var liveStreamsOrdered: [TwitchStream] { followsStore?.liveStreamsOrdered ?? [] }
    private var profileImageURLs: [String: URL] { followsStore?.profileImageURLs ?? [:] }
    private var allLoadState: FollowsStore.LoadState { followsStore?.allLoadState ?? .idle }
    private var liveLoadState: FollowsStore.LoadState { followsStore?.liveLoadState ?? .idle }
    private var allLoadProgress: Int { followsStore?.allLoadProgress ?? 0 }
    private var totalFollowed: Int? { followsStore?.totalFollowed }
    private var allErrorMessage: String? { followsStore?.allErrorMessage }
    private var liveErrorMessage: String? { followsStore?.liveErrorMessage }

    private var selectedMode: ViewMode {
        ViewMode(rawValue: rawViewMode) ?? .live
    }

    // MARK: - Sorting + filtering

    /// All channels sorted live-first (desc viewer count) with offline ones in
    /// original order. Read from the store's memoized cache rather than
    /// recomputed here — the sort lives in `FollowsStore.sortedAllChannels`
    /// and only updates when `channels` or `liveStreams` actually change,
    /// rather than once per body invocation (which previously meant once per
    /// keystroke in search).
    private var sortedAllChannels: [FollowedChannel] {
        followsStore?.sortedAllChannels ?? []
    }

    /// Filters against `FollowsStore.sortedAllChannelSearchKeys` — lowercased
    /// `"name\nlogin"` keys precomputed with the sort — so a keystroke costs
    /// one `contains` per channel instead of two `lowercased()` allocations.
    private var filteredAllChannels: [FollowedChannel] {
        let sorted = sortedAllChannels
        guard !searchText.isEmpty else { return sorted }
        let query = searchText.lowercased()
        let keys = followsStore?.sortedAllChannelSearchKeys ?? []
        return zip(sorted, keys).compactMap { channel, key in
            key.contains(query) ? channel : nil
        }
    }

    /// Live channels filtered by search, then ordered by the selected sort.
    /// `/streams/followed` already returns descending viewer count, so the
    /// default `.viewers` sort is a no-op passthrough. Search matches the
    /// store's precomputed lowercased name/login/game keys.
    private var filteredLiveStreams: [TwitchStream] {
        var streams = liveStreamsOrdered
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            let keys = followsStore?.liveStreamSearchKeys ?? [:]
            streams = streams.filter { stream in
                keys[stream.userId]?.contains(query) ?? false
            }
        }
        switch liveSort {
        case .viewers:
            return streams
        case .recentlyStarted:
            return streams.sorted { $0.startedAt > $1.startedAt }
        case .name:
            return streams.sorted {
                $0.userName.localizedCaseInsensitiveCompare($1.userName) == .orderedAscending
            }
        }
    }

    // MARK: - Body

    public var body: some View {
        // Segmented picker REMOVED. The Live/All toggle is now driven by
        // the `.toolbarTitleMenu` modifier below — tapping the "Following"
        // title in the nav bar reveals a menu with Live / All options.
        // Matches Twitch's app pattern (and Mail's "filter" menu pattern
        // on iOS), saves a whole row of chrome, and consolidates the
        // page's mode selection in one canonical affordance.
        Group {
            switch selectedMode {
            case .live: liveSegment
            case .all:  allSegment
            }
        }
        // Same background world as Home: transparent rows over the shared
        // flat chat surface, so the Home → Following push doesn't jump between
        // two different backgrounds.
        .scrollContentBackground(.hidden)
        .background(Color.chatSurface.ignoresSafeArea())
        // Soft progressive blur where rows scroll out at the bottom edge —
        // same treatment as the chat transcript's top edge. Applied to the
        // Group so both segments' Lists pick it up. Top edge hard, matching
        // Home — soft lets thumbnails ghost through the bar.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        // "Following" matches the convention every social app uses (Twitter/X,
        // Instagram, Bluesky). Shorter than the previous "@displayName's Follows".
        // The account context is one tap away via the gear → Settings.
        .navigationTitle("Following")
        // `.inlineLarge` displays the title left-aligned in the nav bar
        // at a larger size than `.inline` but without the auto-collapsing
        // big title below the bar. This keeps the title and the gear cog
        // on the SAME ROW (eliminates the "lonely gear floating on a
        // mostly-empty row" problem) and saves ~60pt of vertical space
        // vs the default large-title behavior.
        .toolbarTitleDisplayMode(.inlineLarge)
        // Tappable title with a chevron — iOS picks up the Picker inside
        // and renders it as a checkmark-on-current-mode menu. This is
        // Apple's standard "tap title to filter" pattern (Mail uses it
        // for "Unread", "Flagged", etc.).
        .toolbarTitleMenu {
            Picker("Following mode", selection: Binding(
                get: { selectedMode },
                set: { rawViewMode = $0.rawValue }
            )) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
        // "+" to open a channel that isn't followed (search + manual
        // entry). `.primaryAction` lands trailing on iOS, cross-platform.
        .toolbar {
            // Sort applies only to the live segment (the All list keeps
            // its memoized live-first order), so the menu hides on All —
            // a sort control that silently does nothing erodes trust in
            // the one that works.
            if selectedMode == .live {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort live by", selection: $liveSort) {
                            ForEach(LiveSort.allCases, id: \.self) { sort in
                                Text(sort.displayName).tag(sort)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort live channels")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddChannel = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add a channel")
            }
        }
        // Land on the segment the pushing context promised (see
        // `initialMode`). onAppear, not init: @AppStorage can't be
        // written before the view installs.
        .onAppear {
            if let initialMode {
                rawViewMode = initialMode.rawValue
            }
        }
        .sheet(isPresented: $showingAddChannel) {
            AddChannelView(account: account, accountStore: accountStore)
        }
        .confirmationDialog(
            "Sign out of @\(account.login)?",
            isPresented: $showingSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to authorize chattr with Twitch again to use this account.")
        }
        // Sign-out failures get their own alert. Previously the message was
        // folded into allFailedView's description, which only renders when
        // the *load* state is .failed — a failed sign-out was invisible.
        .alert(
            "Couldn't sign out",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Search applies to whichever view is showing — the filter logic is
        // mode-aware inside `filteredAllChannels` / `filteredLiveStreams`.
        //
        // Native scroll-to-reveal: with default placement, iOS hides the
        // search field when the user scrolls up to read, and reveals it
        // when they pull down. This is the iOS-idiomatic pattern (Mail,
        // Music, Contacts all work this way). Previously we hid the
        // search behind a floating button + `isPresented` binding +
        // scroll-tracking — replaced by ~30 LOC of cuts and one
        // signature change.
        .searchable(text: $searchText, prompt: searchPrompt)
        // Pull-to-refresh routes to the right refresher.
        .refreshable {
            guard let store = followsStore else { return }
            switch selectedMode {
            case .live:
                // Explicit user intent — bypass the staleness throttle.
                await store.refreshLive(account: account, accountStore: accountStore, force: true)
            case .all:
                await store.refreshAll(account: account, accountStore: accountStore)
            }
        }
        // Refresh live data whenever the user visits the Follows tab. The
        // initial load is triggered by RootView's .task on sign-in; this
        // .task fires on every appear (including tab switches). FollowsStore
        // coalesces it with any in-flight refresh and skips it when the
        // live list is younger than `liveStalenessInterval`.
        .task {
            guard let store = followsStore else { return }
            await store.refreshLive(account: account, accountStore: accountStore)
        }
    }

    /// Mode-specific search placeholder.
    private var searchPrompt: String {
        switch selectedMode {
        case .live: return "Search live channels"
        case .all:  return "Search all channels"
        }
    }

    // MARK: - Live segment

    @ViewBuilder
    private var liveSegment: some View {
        let filtered = filteredLiveStreams
        if liveStreamsOrdered.isEmpty {
            switch liveLoadState {
            case .idle, .loading:
                ProgressView("Loading live channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                ContentUnavailableView(
                    "Nobody's live",
                    systemImage: "wifi.slash",
                    description: Text("None of your followed channels are streaming right now. Switch to All to see your full list.")
                )
            case .failed:
                liveFailedView
            }
        } else if filtered.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            // One store read per body; each row gets its resolved URL.
            let avatarURLs = profileImageURLs
            List {
                ForEach(filtered, id: \.userId) { stream in
                    let profileURL = avatarURLs[stream.userId]
                    Button {
                        openChannel?(stream: stream, profileImageURL: profileURL)
                        dismiss()
                    } label: {
                        LiveStreamRow(stream: stream, profileImageURL: profileURL)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var liveFailedView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load live channels",
                systemImage: "exclamationmark.triangle",
                description: Text(liveErrorMessage ?? "Unknown error")
            )
            Button("Retry") {
                guard let store = followsStore else { return }
                Task { await store.refreshLive(account: account, accountStore: accountStore, force: true) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
        }
    }

    // MARK: - All segment

    @ViewBuilder
    private var allSegment: some View {
        if channels.isEmpty {
            switch allLoadState {
            case .idle, .loading:
                initialAllLoadingView
            case .loaded:
                emptyFollowsView
            case .failed:
                allFailedView
            }
        } else {
            allLoadedListView
        }
    }

    @ViewBuilder
    private var initialAllLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            if allLoadProgress > 0 {
                allProgressText
            } else {
                Text("Loading channels…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyFollowsView: some View {
        ContentUnavailableView(
            "No followed channels",
            systemImage: "person.crop.circle.badge.questionmark",
            description: Text("Follow channels on twitch.tv and they'll appear here.")
        )
    }

    @ViewBuilder
    private var allFailedView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't load channels",
                systemImage: "exclamationmark.triangle",
                description: Text(allErrorMessage ?? "Unknown error")
            )
            // Plain retry first — most failures here are transient network
            // errors, same as liveFailedView. Sign-out stays available as
            // the escalation for genuinely broken auth, not the default.
            Button("Retry") {
                guard let store = followsStore else { return }
                Task { await store.refreshAll(account: account, accountStore: accountStore) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            Button("Sign out and try again") {
                showingSignOutConfirm = true
            }
            .buttonStyle(.bordered)
            .disabled(isSigningOut)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var allLoadedListView: some View {
        let filtered = filteredAllChannels
        if filtered.isEmpty && !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            // One store read each per body; each row gets resolved values.
            let avatarURLs = profileImageURLs
            let live = liveStreamsDict
            List {
                ForEach(filtered) { channel in
                    let profileURL = avatarURLs[channel.broadcasterId]
                    Button {
                        openChannel?(channel: channel, profileImageURL: profileURL)
                        dismiss()
                    } label: {
                        ChannelRow(
                            channel: channel,
                            stream: live[channel.broadcasterId],
                            profileImageURL: profileURL
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                allLoadingMoreFooter
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var allLoadingMoreFooter: some View {
        switch allLoadState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.75)
                allProgressText
                Spacer()
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                Text("Couldn't load remaining channels")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    guard let store = followsStore else { return }
                    Task { await store.refreshAll(account: account, accountStore: accountStore) }
                }
                .font(.footnote)
            }
            .padding(.vertical, 4)
            .listRowSeparator(.hidden)
        case .idle, .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private var allProgressText: some View {
        if let total = totalFollowed, total > 0 {
            Text("Loading channels — \(allLoadProgress) of \(total)")
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentTransition(.numericText())
        } else {
            Text("Loading channels — \(allLoadProgress) so far")
                .foregroundStyle(.secondary)
                .font(.callout)
                .contentTransition(.numericText())
        }
    }

    // MARK: - Actions

    @MainActor
    private func signOut() async {
        isSigningOut = true
        defer { isSigningOut = false }
        // Read before removal: the row is deleted once `remove` returns, and
        // touching a deleted SwiftData model's properties traps.
        let login = account.login
        do {
            switch try await accountStore.remove(account: account) {
            case .removed:
                logger.info("Signed out @\(login, privacy: .public)")
            case .superseded:
                logger.notice("Sign-out of @\(login, privacy: .public) yielded to a re-authorization; still signed in")
            }
        } catch {
            logger.error("Sign out had an error: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Sign out: \(error.localizedDescription)"
        }
    }
}

// MARK: - Identifiable conformance

/// Retroactive `Identifiable` conformance for use in `ForEach` over
/// `[FollowedChannel]`. The All view uses this; the Live view uses an
/// explicit `id: \.userId` keyPath because TwitchStream isn't Identifiable
/// out of the box and we don't need that conformance at the top level.
extension FollowedChannel: @retroactive Identifiable {
    public var id: String { broadcasterId }
}
