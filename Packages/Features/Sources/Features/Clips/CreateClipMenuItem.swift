import SwiftUI
import TwitchKit

/// "Create Clip" in the chat's More menu — present only while the channel
/// is live (there's nothing to clip otherwise).
///
/// Its own view so the live-status read invalidates just this menu item,
/// not the compose bar around it (whose body would otherwise re-run on
/// every status refresh).
struct CreateClipMenuItem: View {
    let channelId: String
    let action: () -> Void

    @Environment(\.followsStore) private var followsStore
    @Environment(\.channelStatus) private var channelStatus

    private var isLive: Bool {
        ChannelStatusStore.liveStream(for: channelId, status: channelStatus, follows: followsStore) != nil
    }

    var body: some View {
        if isLive {
            Button(action: action) {
                Label("Create Clip", systemImage: "scissors")
            }
        }
    }
}
