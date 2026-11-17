import SwiftUI
import Accounts
import TwitchKit
import Core
import Nuke
import NukeUI
import os

private let logger = AppLogger.make("Features.AddChannel")

/// Sheet for opening a channel that isn't in your follow list — via
/// Twitch channel search OR by typing an exact channel name.
///
/// Presented from `ChannelListScreen`'s toolbar "+" button. On selecting
/// a result (or resolving a manual entry), it calls the `openChannel`
/// environment action — the same path the Follows list uses — which adds
/// a chat tab and switches to the Chat tab. Opening a non-followed
/// channel works end-to-end because EventSub chat subscriptions don't
/// require a follow relationship.
struct AddChannelView: View {
    let account: Account
    let accountStore: AccountStore
    /// False when hosted in the Search tab (a persistent destination has
    /// nothing to cancel); true for the legacy sheet presentation.
    var showsCancelButton: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    @Environment(\.followsStore) private var followsStore

    /// Before typing: filters the "Live from your follows" list.
    @State private var browseCategory: String?

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

    /// True when the query looks like a plausible Twitch login (4-25
    /// chars, alphanumeric + underscore). Gates the manual-entry row so
    /// it doesn't show for partial/invalid input.
    private var manualLoginIsPlausible: Bool {
        let login = manualLogin
        guard (1...25).contains(login.count) else { return false }
        return login.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    var body: some View {
        NavigationStack {
            List {
                // Nothing typed yet: something useful instead of a blank
                // page — who you follow that's live, by category.
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browseSection
                } else {
                    followingMatchesSection
                }

                // Manual-entry affordance: open the exact typed channel.
                // Shows when the query is a plausible login AND isn't
                // already the first search result (avoid a redundant row).
                if manualLoginIsPlausible,
                   results.first?.broadcasterLogin.lowercased() != manualLogin {
                    Section {
                        Button {
                            Task { await openManual() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "number")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, height: 36)
                                Text("Open #\(manualLogin)")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isResolvingManual {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isResolvingManual)
                    } header: {
                        Text("Direct")
                    }
                }

                if !results.isEmpty {
                    Section {
                        ForEach(results, id: \.id) { channel in
                            Button {
                                open(channel)
                            } label: {
                                SearchResultRow(channel: channel)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Search Results")
                    }
                } else if isSearching {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Searching…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !manualLogin.isEmpty && !manualLoginIsPlausible {
                    // Typed something that can't be a login and no results.
                    Section {
                        ContentUnavailableView.search(text: query)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(showsCancelButton ? "Add Channel" : "Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(
                text: $query,
                prompt: "Search channels or type a name"
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
            // Debounced search: `.task(id: query)` cancels the prior task
            // on each keystroke; the 300ms sleep absorbs rapid typing so
            // we only hit Helix once the user pauses.
            .task(id: query) {
                await runSearch()
            }
        }
    }

    // MARK: - Browse (empty query)

    private var liveFollows: [TwitchStream] {
        followsStore?.liveStreamsOrdered ?? []
    }

    /// Categories your live follows are in, busiest first.
    private var browseCategories: [String] {
        var totals: [String: Int] = [:]
        for stream in liveFollows where !stream.gameName.isEmpty {
            totals[stream.gameName, default: 0] += stream.viewerCount
        }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    @ViewBuilder
    private var browseSection: some View {
        if !liveFollows.isEmpty {
            Section {
                if browseCategories.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            categoryChip(nil, title: "All")
                            ForEach(browseCategories, id: \.self) { category in
                                categoryChip(category, title: category)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                    .listRowSeparator(.hidden)
                }
                ForEach(liveFollows.filter { browseCategory == nil || $0.gameName == browseCategory }, id: \.userId) { stream in
                    let profileURL = followsStore?.profileImageURLs[stream.userId]
                    Button {
                        openChannel?(stream: stream, profileImageURL: profileURL)
                        dismiss()
                    } label: {
                        FollowingRow(
                            displayName: stream.userName,
                            login: stream.userLogin,
                            profileImageURL: profileURL,
                            stream: stream,
                            lastLiveAt: nil
                        )
                    }
                    .buttonStyle(.plain)
                    .channelPreviewMenu(
                        name: stream.userName,
                        profileImageURL: profileURL,
                        stream: stream,
                        open: { intent in
                            openChannel?(stream: stream, profileImageURL: profileURL, intent: intent)
                            dismiss()
                        }
                    )
                }
            } header: {
                Text("Live from your follows")
            }
        }
    }

    private func categoryChip(_ category: String?, title: String) -> some View {
        let selected = browseCategory == category
        return Button {
            withAnimation(.snappy(duration: 0.2)) { browseCategory = category }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// While typing: followed channels that match, ahead of the network
    /// search (instant, and usually what you meant).
    @ViewBuilder
    private var followingMatchesSection: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches: [FollowedChannel] = {
            guard let followsStore, !needle.isEmpty else { return [] }
            let channels = followsStore.sortedAllChannels
            let keys = followsStore.sortedAllChannelSearchKeys
            var found: [FollowedChannel] = []
            for (index, key) in keys.enumerated() where index < channels.count && key.contains(needle) {
                found.append(channels[index])
                if found.count == 6 { break }
            }
            return found
        }()
        if !matches.isEmpty {
            Section {
                ForEach(matches, id: \.broadcasterId) { channel in
                    let profileURL = followsStore?.profileImageURLs[channel.broadcasterId]
                    Button {
                        openChannel?(channel: channel, profileImageURL: profileURL)
                        dismiss()
                    } label: {
                        FollowingRow(
                            displayName: channel.broadcasterName,
                            login: channel.broadcasterLogin,
                            profileImageURL: profileURL,
                            stream: followsStore?.liveStreams[channel.broadcasterId],
                            lastLiveAt: nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Following")
            }
        }
    }

    // MARK: - Search

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            logger.warning("Channel search failed: \(error.localizedDescription)")
            errorMessage = "Search failed: \(error.localizedDescription)"
            results = []
        }
    }

    // MARK: - Open

    /// Open a search result. thumbnailUrl on SearchChannel is the
    /// broadcaster's profile image (per Twitch docs), so it doubles as
    /// the tab-strip avatar.
    private func open(_ channel: SearchChannel) {
        openChannel?(ChannelDescriptor(
            platform: .twitch,
            channelId: channel.id,
            channelLoginName: channel.broadcasterLogin,
            channelDisplayName: channel.displayName,
            profileImageURL: URL(string: channel.thumbnailUrl)
        ))
        dismiss()
    }

    /// Resolve a manually-typed login via Helix `fetchUser(login:)`, then
    /// open it. Surfaces a friendly error if the channel doesn't exist.
    private func openManual() async {
        guard !isResolvingManual else { return }
        isResolvingManual = true
        errorMessage = nil
        defer { isResolvingManual = false }

        let login = manualLogin
        let client = accountStore.client(for: account)
        do {
            let user = try await accountStore.withTokenRefresh(for: account) { [login] in
                try await client.api.fetchUser(login: login)
            }
            openChannel?(ChannelDescriptor(
                platform: .twitch,
                channelId: user.id,
                channelLoginName: user.login,
                channelDisplayName: user.displayName,
                profileImageURL: URL(string: user.profileImageUrl)
            ))
            dismiss()
        } catch {
            logger.warning("Manual channel resolve failed for \(login, privacy: .public): \(error.localizedDescription)")
            errorMessage = "Couldn't find a channel named \"\(login)\"."
        }
    }
}

// MARK: - Result row

/// One channel search result: avatar + display name + @login, with a
/// live indicator + stream title when the channel is broadcasting.
private struct SearchResultRow: View {
    let channel: SearchChannel

    var body: some View {
        HStack(spacing: 12) {
            LazyImage(request: ImageRequest.avatar(url: URL(string: channel.thumbnailUrl), side: 40)) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .contentShape(Rectangle())
    }
}
