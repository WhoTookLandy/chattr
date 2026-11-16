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
                List {
                    ForEach(followsStore.sortedAllChannels, id: \.broadcasterId) { channel in
                        let profileURL = followsStore.profileImageURLs[channel.broadcasterId]
                        Button {
                            openChannel?(channel: channel, profileImageURL: profileURL)
                        } label: {
                            FollowingRow(
                                displayName: channel.broadcasterName,
                                login: channel.broadcasterLogin,
                                profileImageURL: profileURL,
                                stream: ChannelStatusStore.liveStream(
                                    for: channel.broadcasterId, status: channelStatus, follows: followsStore
                                ),
                                lastLiveAt: channelStatus?.statuses[channel.broadcasterId]?.lastLiveAt
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .task {
                            guard followsStore.liveStreams[channel.broadcasterId] == nil else { return }
                            await channelStatus?.ensureLastLive(
                                channelId: channel.broadcasterId, account: account, accountStore: accountStore
                            )
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
