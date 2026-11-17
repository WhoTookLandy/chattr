#if os(iOS)
import Foundation

/// Settings → Video → When a Chat Opens. Runs just before the chat pager is
/// presented (`ChatTabsModel.onWillPresent`), so the header mounts already
/// in the chosen state — no frame of the wrong layout, no engine started
/// and immediately torn down.
@MainActor
enum ChatOpenVideoPolicy {
    static func apply(playback: PlaybackCenter?) {
        // A stream that's already playing (back from the mini player or
        // PiP) carries on exactly as it was.
        if playback?.isPlaying == true { return }
        playback?.startNextStreamMuted = false

        let defaults = UserDefaults.standard
        let videoOpen: Bool
        switch PlaybackPreferences.videoOnOpen {
        case .lastUsed:
            return
        case .closed:
            videoOpen = false
        case .autoplayOnWiFi:
            // Audio-only has no video to autoplay; leave it closed.
            let audioOnly = defaults.bool(forKey: PlayerSettings.audioOnlyKey)
            videoOpen = !audioOnly && NetworkReachability.shared.isOnWiFi
            playback?.startNextStreamMuted = videoOpen
        }
        // Written only on change: `@AppStorage` readers (the header, the
        // compose bar) re-render on every write.
        if defaults.bool(forKey: StreamHeaderView.expandedKey) != videoOpen {
            defaults.set(videoOpen, forKey: StreamHeaderView.expandedKey)
        }
    }
}
#endif
