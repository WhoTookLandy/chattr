#if os(iOS)
import SwiftUI
import Accounts

/// Keeps `ChannelStatusStore` refreshing any pinned background-audio channels
/// (including channels pinned from Home with no open chat tab) while the app
/// is in the foreground, and feeds confirmed offline readings back to
/// `PlaybackCenter.reconcilePinnedStatuses`.
///
/// Extracted as a standalone empty view so observing `playback.pinnedAudio`
/// never invalidates `AppShell.body`.
struct PinnedAudioStatusCoordinator: View {
    let account: Account
    let accountStore: AccountStore
    let playback: PlaybackCenter

    @Environment(\.channelStatus) private var channelStatus
    @Environment(\.followsStore) private var followsStore
    @Environment(\.scenePhase) private var scenePhase

    private struct PollKey: Equatable {
        let pinnedIds: [String]
        let inForeground: Bool
    }

    private var pinnedChannelIds: [String] {
        playback.pinnedAudio.map(\.channel.channelId)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: PollKey(pinnedIds: pinnedChannelIds, inForeground: scenePhase != .background)) {
                guard let channelStatus, !pinnedChannelIds.isEmpty, scenePhase != .background else { return }
                while !Task.isCancelled {
                    await channelStatus.refresh(
                        channelIds: pinnedChannelIds,
                        account: account,
                        accountStore: accountStore,
                        includeLastLive: false
                    )
                    guard !Task.isCancelled else { return }
                    playback.reconcilePinnedStatuses(statusStore: channelStatus, follows: followsStore)
                    try? await Task.sleep(for: .seconds(60))
                }
            }
    }
}
#endif
