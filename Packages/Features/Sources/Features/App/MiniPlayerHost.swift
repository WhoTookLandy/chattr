import SwiftUI
import Core

#if os(iOS)
/// The floating mini player over every tab. Its own view so the state it
/// depends on (selected tab, chat presented, playing, PiP) is observed here
/// rather than by `AppShell`.
struct MiniPlayerHost: View {
    let navigation: AppNavigation
    let playback: PlaybackCenter

    @AppStorage(PlayerSettings.systemPictureInPictureKey) private var useSystemPictureInPicture = false

    /// A chat is on screen (Chats tab with the pager pushed) — the stream
    /// shows in its header there, so no mini player. Not while the system
    /// PiP window is showing the stream either — the mini player would just
    /// be a black "playing in picture in picture" tile.
    private var showsMiniPlayer: Bool {
        let chatOnScreen = navigation.selectedTab == .chats
            && navigation.chatTabs.isPresented
            && !navigation.chatTabs.tabs.isEmpty
        return playback.isPlaying && !chatOnScreen && !playback.controller.isPictureInPictureActive
    }

    var body: some View {
        ZStack {
            if showsMiniPlayer {
                MiniPlayerOverlay(center: playback) { channel in
                    navigation.openChannel(channel)
                }
            }
        }
        // Scoped to the overlay. On the TabView itself this animated the
        // WHOLE app tree in the transaction where `showsMiniPlayer` flips —
        // which is exactly the chat push / pop — so the navigation
        // transition, toolbar and tab-bar changes all picked up an extra
        // implicit animation.
        .animation(.snappy(duration: 0.3), value: showsMiniPlayer)
        .onChange(of: showsMiniPlayer) { _, shows in
            if shows { handOffToSystemPictureInPicture() }
        }
    }

    /// "Picture in Picture When Leaving Chat": once the mini player has
    /// taken the video, hand it to the system PiP window. PiP can only start
    /// from a player that's on screen, hence going via the mounted tile
    /// rather than straight from the chat header mid-pop. If PiP can't start
    /// (not ready yet, or the web player refuses), the mini player simply
    /// stays — nothing is lost. Audio-only keeps its pill.
    private func handOffToSystemPictureInPicture() {
        guard useSystemPictureInPicture,
              !playback.audioOnly || playback.controller.nativeFailed else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard showsMiniPlayer,
                  playback.controller.canPictureInPicture,
                  !playback.controller.isPictureInPictureActive else { return }
            playback.controller.togglePictureInPicture()
        }
    }
}
#endif
