import SwiftUI
import Core

#if os(iOS)
/// The floating mini player over every tab. Its own view so the state it
/// depends on (selected tab, chat presented, playing, pinned audio, PiP) is
/// observed here rather than by `AppShell`.
struct MiniPlayerHost: View {
    let navigation: AppNavigation
    let playback: PlaybackCenter

    @AppStorage(PlayerSettings.systemPictureInPictureKey) private var useSystemPictureInPicture = false

    /// A chat is on screen (Chats tab with the pager pushed) — the stream
    /// shows in its header / pinned-audio bar there, so no mini player.
    /// System PiP hides ONLY the primary video tile (`showsPrimaryVideoTile`),
    /// never the pinned background-audio dock (`audioDockSlots`).
    private var showsMiniPlayer: Bool {
        let chatOnScreen = navigation.selectedTab == .chats
            && navigation.chatTabs.isPresented
            && !navigation.chatTabs.tabs.isEmpty
        guard !chatOnScreen else { return false }
        return playback.showsPrimaryVideoTile || !playback.audioDockSlots.isEmpty
    }

    /// True while Home has auto-hidden the bottom tab bar on downward scroll,
    /// letting the mini player settle closer to the bottom edge.
    private var isTabBarHidden: Bool {
        navigation.selectedTab == .home && navigation.isHomeTabBarHidden
    }

    var body: some View {
        ZStack {
            if showsMiniPlayer {
                MiniPlayerOverlay(center: playback, isTabBarHidden: isTabBarHidden) { channel in
                    navigation.openChannel(channel)
                }
            }
        }
        .animation(.snappy(duration: 0.3), value: showsMiniPlayer)
        .onChange(of: showsMiniPlayer) { _, shows in
            if shows { handOffToSystemPictureInPicture() }
        }
    }

    /// "Picture in Picture When Leaving Chat": once the mini player has
    /// taken the video, hand it to the system PiP window. Audio-only and
    /// pinned audio streams keep their bottom dock.
    private func handOffToSystemPictureInPicture() {
        guard useSystemPictureInPicture, playback.showsPrimaryVideoTile else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard showsMiniPlayer,
                  playback.showsPrimaryVideoTile,
                  playback.controller.canPictureInPicture,
                  !playback.controller.isPictureInPictureActive else { return }
            playback.controller.togglePictureInPicture()
        }
    }
}
#endif
