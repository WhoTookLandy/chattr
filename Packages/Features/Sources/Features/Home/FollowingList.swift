import SwiftUI
import Accounts
import TwitchKit
import NukeUI
import Nuke

/// Home → Following: every followed channel, live ones first (busiest
/// first), then the rest in follow order. Live rows show viewers +
/// category; offline rows show "Streamed 2 days ago", fetched lazily per
/// row as it scrolls into view (`ChannelStatusStore.ensureLastLive`) — so a
/// big follow list never fans out hundreds of requests up front.
///
/// Search and sorting stay on the full `ChannelListScreen` (Live now →
/// "See all"); this is the at-a-glance roster.
struct FollowingList: View {
    let account: Account
    let accountStore: AccountStore

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.openChannel) private var openChannel

    var body: some View {
        Group {
            if let followsStore, !followsStore.sortedAllChannels.isEmpty {
                // Live / Offline sections. The store already orders live
                // first (busiest first), then the rest in follow order.
                let live = followsStore.sortedAllChannels.filter { followsStore.liveStreams[$0.broadcasterId] != nil }
                let offline = followsStore.sortedAllChannels.filter { followsStore.liveStreams[$0.broadcasterId] == nil }
                List {
                    if !live.isEmpty {
                        Section {
                            ListSectionTitle("Live")
                            rows(live, followsStore: followsStore)
                        }
                    }
                    if !offline.isEmpty {
                        Section {
                            ListSectionTitle("Offline")
                            rows(offline, followsStore: followsStore)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                placeholder
            }
        }
        .task {
            await followsStore?.loadAllIfNeeded(account: account, accountStore: accountStore)
        }
        .refreshable {
            await followsStore?.refreshAll(account: account, accountStore: accountStore)
            await followsStore?.refreshLive(account: account, accountStore: accountStore, force: true)
        }
    }

    private func rows(_ channels: [FollowedChannel], followsStore: FollowsStore) -> some View {
        ForEach(channels, id: \.broadcasterId) { channel in
            FollowingListItem(
                channel: channel,
                account: account,
                accountStore: accountStore,
                followsStore: followsStore,
                channelStatus: channelStatus,
                openChannel: openChannel
            )
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch followsStore?.allLoadState ?? .idle {
        case .idle, .loading:
            ProgressView("Loading channels…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ContentUnavailableView(
                "Not following anyone",
                systemImage: "heart",
                description: Text("Follow channels on twitch.tv and they'll appear here.")
            )
        case .failed:
            ContentUnavailableView(
                "Couldn't load channels",
                systemImage: "exclamationmark.triangle",
                description: Text("Pull to retry.")
            )
        }
    }
}

/// Per-row view isolating `channelStatus?.statuses[id]` observation so each
/// lazy `ensureLastLive` result redraws only its own row instead of re-filtering
/// and re-diffing the entire `FollowingList`.
private struct FollowingListItem: View {
    let channel: FollowedChannel
    let account: Account
    let accountStore: AccountStore
    let followsStore: FollowsStore
    let channelStatus: ChannelStatusStore?
    let openChannel: OpenChannelAction?

    var body: some View {
        let profileURL = followsStore.profileImageURLs[channel.broadcasterId]
        let stream = followsStore.liveStreams[channel.broadcasterId]
        Button {
            openChannel?(channel: channel, profileImageURL: profileURL)
        } label: {
            FollowingRow(
                displayName: channel.broadcasterName,
                login: channel.broadcasterLogin,
                profileImageURL: profileURL,
                stream: stream,
                lastLiveAt: channelStatus?.statuses[channel.broadcasterId]?.lastLiveAt
            )
        }
        .buttonStyle(.plain)
        .channelPreviewMenu(
            name: channel.broadcasterName,
            profileImageURL: profileURL,
            stream: stream,
            open: { intent in openChannel?(channel: channel, profileImageURL: profileURL, intent: intent) }
        )
        .onAppear {
            guard stream == nil else { return }
            channelStatus?.ensureLastLive(
                channelId: channel.broadcasterId, account: account, accountStore: accountStore
            )
        }
    }
}
