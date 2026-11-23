import SwiftUI
import Accounts
import TwitchKit
import Core
import DesignSystem
import Nuke
import NukeUI
import os

private let logger = AppLogger.make("Features.AddChannel")

/// Search tab (and legacy "+ Add Channel" sheet) for finding and opening any
/// Twitch channel — followed or not — via live follows, recent searches,
/// category browse, Helix channel search, or direct `#login` resolution.
///
/// When hosted in `AppShell`'s `Tab(role: .search)`, `showsCancelButton` is
/// false and the system renders the Liquid Glass search bar at the bottom.
struct AddChannelView: View {
    let account: Account
    let accountStore: AccountStore
    /// False when hosted in the Search tab (a persistent destination has
    /// nothing to cancel); true for the modal sheet presentation.
    var showsCancelButton: Bool = true

    private enum SearchRoute: Hashable {
        case category(String?)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    @Environment(\.followsStore) private var followsStore
    #if os(iOS)
    @Environment(\.playback) private var playback
    #endif

    @State private var path: [SearchRoute] = []
    @State private var recentSearches: [RecentSearchItem] = []

    @State private var query: String = ""
    @State private var results: [SearchChannel] = []
    @State private var isSearching = false
    /// Set while a manual "Open #name" resolve is in flight, so the row
    /// shows a spinner and can't be double-tapped.
    @State private var isResolvingManual = false
    @State private var errorMessage: String?

    /// Trimmed, lowercased query — Twitch logins are lowercase. Used for
    /// the manual-entry "Open #login" affordance and dedup against search
    /// results.
    private var manualLogin: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// True when the query looks like a plausible Twitch login (1–25 chars,
    /// alphanumeric + underscore). Gates the manual-entry row so it doesn't
    /// show for partial/invalid input.
    private var manualLoginIsPlausible: Bool {
        let login = manualLogin
        guard (1...25).contains(login.count) else { return false }
        return login.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var liveFollows: [TwitchStream] {
        followsStore?.liveStreamsOrdered ?? []
    }

    private var browseCategories: [SearchCategorySummary] {
        SearchBrowseCatalog.categories(from: liveFollows)
    }

    private var bottomClearance: CGFloat {
        #if os(iOS)
        playback?.isPlaying == true ? 96 : 24
        #else
        24
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if trimmedQuery.isEmpty {
                        hubContent
                    } else {
                        activeSearchContent
                    }
                }
                .padding(.bottom, bottomClearance)
            }
            .background(Color.chatSurface.ignoresSafeArea())
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .navigationTitle(showsCancelButton ? "Add Channel" : "Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(
                text: $query,
                prompt: "Search channels or #login"
            )
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .toolbar {
                if showsCancelButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .navigationDestination(for: SearchRoute.self) { route in
                switch route {
                case .category(let category):
                    SearchCategoryStreamsScreen(initialCategory: category) { stream, profileURL, intent in
                        openStream(stream, profileURL: profileURL, intent: intent)
                    }
                }
            }
            .onAppear {
                recentSearches = SearchHistoryStorage.load(forAccount: account.userId)
            }
            .task(id: account.userId) {
                recentSearches = SearchHistoryStorage.load(forAccount: account.userId)
                await followsStore?.refreshLive(account: account, accountStore: accountStore)
                await followsStore?.loadAllIfNeeded(account: account, accountStore: accountStore)
            }
            // Debounced search: `.task(id: query)` cancels the prior task
            // on each keystroke; the 300ms sleep absorbs rapid typing so
            // we only hit Helix once the user pauses.
            .task(id: query) {
                await runSearch()
            }
        }
    }

    // MARK: - Zero-State Search Hub

    @ViewBuilder
    private var hubContent: some View {
        if liveFollows.isEmpty && recentSearches.isEmpty {
            ContentUnavailableView(
                "Search Twitch",
                systemImage: "magnifyingglass",
                description: Text("Find any live or offline channel by name, or jump straight to #login.")
            )
            .padding(.top, 72)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if !liveFollows.isEmpty {
                    liveFollowsSection
                }

                if !recentSearches.isEmpty {
                    recentSearchesSection
                }

                if !browseCategories.isEmpty {
                    browseCategoriesSection
                }
            }
            .padding(.top, 8)
        }
    }

    private var liveFollowsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                title: "Live Follows",
                actionTitle: "See all (\(liveFollows.count))"
            ) {
                path.append(.category(nil))
            }

            SearchLiveFollowsRail(
                streams: liveFollows,
                profileImageURLs: followsStore?.profileImageURLs ?? [:],
                onSelect: { stream, intent in
                    let profileURL = followsStore?.profileImageURLs[stream.userId]
                    openStream(stream, profileURL: profileURL, intent: intent)
                }
            )
        }
    }

    private var recentSearchesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(title: "Recent Searches", actionTitle: "Clear", actionTone: .secondary) {
                withAnimation(.snappy(duration: 0.2)) {
                    SearchHistoryStorage.clear(forAccount: account.userId)
                    recentSearches = []
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(recentSearches.enumerated()), id: \.element.id) { index, item in
                    recentRow(item)
                    if index < recentSearches.count - 1 {
                        Divider()
                            .padding(.leading, 54)
                    }
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .padding(.horizontal, 16)
        }
    }

    private func recentRow(_ item: RecentSearchItem) -> some View {
        let liveStream = item.channelId.flatMap { followsStore?.liveStreams[$0] }
        let profileURL = item.channelId.flatMap { followsStore?.profileImageURLs[$0] }
            ?? item.profileImageURL.flatMap(URL.init(string:))

        return HStack(spacing: 10) {
            Button {
                openRecent(item)
            } label: {
                HStack(spacing: 10) {
                    recentLeadingIcon(item: item, profileURL: profileURL, isLive: liveStream != nil)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let liveStream {
                            HStack(spacing: 4) {
                                Circle().fill(.red).frame(width: 5, height: 5)
                                Text("Live · \(StreamFormatting.viewers(liveStream.viewerCount))")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(item.kind == .category ? "Category" : "Channel")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    recentSearches = SearchHistoryStorage.remove(id: item.id, forAccount: account.userId)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item.title) from recent searches")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func recentLeadingIcon(item: RecentSearchItem, profileURL: URL?, isLive: Bool) -> some View {
        switch item.kind {
        case .channel:
            if let profileURL {
                LazyImage(request: ImageRequest.avatar(url: profileURL, side: 32)) { state in
                    if let image = state.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.06))
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
                .padding(isLive ? 1.5 : 0)
                .overlay {
                    if isLive {
                        Circle().strokeBorder(.red, lineWidth: 1.5)
                    }
                }
            } else {
                Image(systemName: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
        case .category:
            Image(systemName: "square.grid.2x2")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.06), in: Circle())
        }
    }

    private var browseCategoriesSection: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Browse Categories", actionTitle: "All Live") {
                path.append(.category(nil))
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(browseCategories) { category in
                    Button {
                        if let recent = RecentSearchItem.category(category.name) {
                            recentSearches = SearchHistoryStorage.record(recent, forAccount: account.userId)
                        }
                        path.append(.category(category.name))
                    } label: {
                        categoryCard(category)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryCard(_ category: SearchCategorySummary) -> some View {
        let tint = Self.categoryTint(for: category.name)
        let followLabel = category.liveFollowCount == 1 ? "1 follow" : "\(category.liveFollowCount) follows"
        return VStack(alignment: .leading, spacing: 6) {
            Text(category.name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("\(StreamFormatting.viewers(category.viewerCount)) · \(followLabel)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.24), tint.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.name), \(StreamFormatting.viewers(category.viewerCount)) viewers across \(followLabel)")
    }

    private enum SectionActionTone {
        case accent
        case secondary
    }

    private func sectionHeader(
        title: String,
        actionTitle: String? = nil,
        actionTone: SectionActionTone = .accent,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(actionTone == .accent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Active Search Results

    @ViewBuilder
    private var activeSearchContent: some View {
        let followingMatches = matchingFollowedChannels

        // Manual-entry affordance: open the exact typed channel.
        // Shows when the query is a plausible login AND isn't
        // already the first search result (avoid a redundant row).
        if manualLoginIsPlausible,
           results.first?.broadcasterLogin.lowercased() != manualLogin {
            searchSectionTitle("Direct")
            Button {
                Task { await openManual(login: manualLogin) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "number")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, height: 42)
                        .background(Color.primary.opacity(0.07), in: Circle())
                    Text("Open #\(manualLogin)")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    if isResolvingManual {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isResolvingManual)
        }

        if !followingMatches.isEmpty {
            searchSectionTitle("Following")
            ForEach(Array(followingMatches.enumerated()), id: \.element.broadcasterId) { index, channel in
                let profileURL = followsStore?.profileImageURLs[channel.broadcasterId]
                let stream = followsStore?.liveStreams[channel.broadcasterId]
                Button {
                    openFollowed(channel, profileURL: profileURL, intent: .implicit)
                } label: {
                    SearchChannelRow(
                        displayName: channel.broadcasterName,
                        login: channel.broadcasterLogin,
                        profileImageURL: profileURL,
                        stream: stream
                    )
                }
                .buttonStyle(.plain)
                .channelPreviewMenu(
                    name: channel.broadcasterName,
                    profileImageURL: profileURL,
                    stream: stream,
                    open: { intent in openFollowed(channel, profileURL: profileURL, intent: intent) }
                )

                if index < followingMatches.count - 1 {
                    Divider()
                        .padding(.leading, 70)
                }
            }
        }

        if !results.isEmpty {
            searchSectionTitle("Search Results")
            ForEach(Array(results.enumerated()), id: \.element.id) { index, channel in
                Button {
                    open(channel)
                } label: {
                    SearchResultRow(channel: channel)
                }
                .buttonStyle(.plain)

                if index < results.count - 1 {
                    Divider()
                        .padding(.leading, 70)
                }
            }
        } else if isSearching {
            HStack(spacing: 10) {
                ProgressView()
                Text("Searching…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        } else if !manualLogin.isEmpty && !manualLoginIsPlausible && followingMatches.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 48)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.top, 12)
        }
    }

    private func searchSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// While typing: followed channels that match, ahead of the network
    /// search (instant, and usually what you meant).
    private var matchingFollowedChannels: [FollowedChannel] {
        let needle = trimmedQuery.lowercased()
        guard let followsStore, !needle.isEmpty else { return [] }
        let channels = followsStore.sortedAllChannels
        let keys = followsStore.sortedAllChannelSearchKeys
        var found: [FollowedChannel] = []
        for (index, key) in keys.enumerated() where index < channels.count && key.contains(needle) {
            found.append(channels[index])
            if found.count == 6 { break }
        }
        return found
    }

    // MARK: - Search

    private func runSearch() async {
        let trimmed = trimmedQuery
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            // A failure message from a longer query shouldn't outlive the
            // query that produced it (e.g. backspacing to one character,
            // or a restored sheet re-running with a stale draft query).
            errorMessage = nil
            return
        }
        // Debounce — if the user keeps typing, this task is cancelled and
        // the sleep throws before we hit the network.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return  // cancelled by the next keystroke
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        let client = accountStore.client(for: account)
        do {
            let page = try await accountStore.withTokenRefresh(for: account) { [trimmed] in
                try await client.api.fetchSearchChannelsPage(query: trimmed, first: 20)
            }
            // Guard against a stale response landing after the query moved
            // on (the .task(id:) cancellation usually prevents this, but
            // the network call can complete during the gap).
            guard !Task.isCancelled else { return }
            results = page.data
        } catch is CancellationError {
            // Superseded by a newer query — ignore.
        } catch {
            logger.warning("Channel search failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Search failed: \(error.localizedDescription)"
            results = []
        }
    }

    // MARK: - Open & Recents

    private func recordRecentChannel(
        id: String,
        login: String,
        displayName: String,
        profileImageURL: URL?
    ) {
        guard let item = RecentSearchItem.channel(
            id: id,
            login: login,
            displayName: displayName,
            profileImageURL: profileImageURL
        ) else { return }
        recentSearches = SearchHistoryStorage.record(item, forAccount: account.userId)
    }

    private func openStream(_ stream: TwitchStream, profileURL: URL?, intent: ChatOpenIntent) {
        recordRecentChannel(
            id: stream.userId,
            login: stream.userLogin,
            displayName: stream.userName,
            profileImageURL: profileURL
        )
        openChannel?(stream: stream, profileImageURL: profileURL, intent: intent)
        if showsCancelButton { dismiss() }
    }

    private func openFollowed(_ channel: FollowedChannel, profileURL: URL?, intent: ChatOpenIntent) {
        recordRecentChannel(
            id: channel.broadcasterId,
            login: channel.broadcasterLogin,
            displayName: channel.broadcasterName,
            profileImageURL: profileURL
        )
        openChannel?(channel: channel, profileImageURL: profileURL, intent: intent)
        if showsCancelButton { dismiss() }
    }

    private func openRecent(_ item: RecentSearchItem) {
        switch item.kind {
        case .category:
            recentSearches = SearchHistoryStorage.record(item, forAccount: account.userId)
            path.append(.category(item.title))
        case .channel:
            guard let login = item.login else { return }
            if let channelId = item.channelId {
                let profileURL = followsStore?.profileImageURLs[channelId]
                    ?? item.profileImageURL.flatMap(URL.init(string:))
                recordRecentChannel(
                    id: channelId,
                    login: login,
                    displayName: item.title,
                    profileImageURL: profileURL
                )
                openChannel?(ChannelDescriptor(
                    platform: .twitch,
                    channelId: channelId,
                    channelLoginName: login,
                    channelDisplayName: item.title,
                    profileImageURL: profileURL
                ))
                if showsCancelButton { dismiss() }
            } else {
                Task { await openManual(login: login) }
            }
        }
    }

    /// Open a search result. thumbnailUrl on SearchChannel is the
    /// broadcaster's profile image (per Twitch docs), so it doubles as
    /// the tab-strip avatar.
    private func open(_ channel: SearchChannel) {
        let profileURL = URL(string: channel.thumbnailUrl)
        recordRecentChannel(
            id: channel.id,
            login: channel.broadcasterLogin,
            displayName: channel.displayName,
            profileImageURL: profileURL
        )
        openChannel?(ChannelDescriptor(
            platform: .twitch,
            channelId: channel.id,
            channelLoginName: channel.broadcasterLogin,
            channelDisplayName: channel.displayName,
            profileImageURL: profileURL
        ))
        if showsCancelButton { dismiss() }
    }

    /// Resolve a manually-typed login via Helix `fetchUser(login:)`, then
    /// open it. Surfaces a friendly error if the channel doesn't exist.
    private func openManual(login: String) async {
        guard !isResolvingManual else { return }
        isResolvingManual = true
        errorMessage = nil
        defer { isResolvingManual = false }

        let client = accountStore.client(for: account)
        do {
            let user = try await accountStore.withTokenRefresh(for: account) { [login] in
                try await client.api.fetchUser(login: login)
            }
            let profileURL = URL(string: user.profileImageUrl)
            recordRecentChannel(
                id: user.id,
                login: user.login,
                displayName: user.displayName,
                profileImageURL: profileURL
            )
            openChannel?(ChannelDescriptor(
                platform: .twitch,
                channelId: user.id,
                channelLoginName: user.login,
                channelDisplayName: user.displayName,
                profileImageURL: profileURL
            ))
            if showsCancelButton { dismiss() }
        } catch {
            logger.warning("Manual channel resolve failed for \(login, privacy: .public): \(error.localizedDescription)")
            errorMessage = "Couldn't find a channel named \"\(login)\"."
        }
    }

    /// Stable, process-independent tint for a category card so each game keeps
    /// a consistent subtle jewel tone across launches.
    private static func categoryTint(for name: String) -> Color {
        let palette: [Color] = [.purple, .blue, .teal, .indigo, .pink, .orange]
        var hash: UInt64 = 14695981039346656037
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Result row

/// One channel search result: avatar (with live ring when broadcasting) +
/// display name + LIVE pill, with the stream title when live or `@login`
/// when offline.
private struct SearchResultRow: View {
    let channel: SearchChannel

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(request: ImageRequest.avatar(url: URL(string: channel.thumbnailUrl), side: 42)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())
            .padding(channel.isLive ? 2 : 0)
            .overlay {
                if channel.isLive {
                    Circle().strokeBorder(.red, lineWidth: 2)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if channel.isLive {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                    }
                }
                // Live → stream title; offline → @login.
                Text(channel.isLive && !channel.title.isEmpty ? channel.title : "@\(channel.broadcasterLogin)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
