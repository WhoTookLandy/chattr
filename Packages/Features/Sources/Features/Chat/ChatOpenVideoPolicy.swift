#if os(iOS)
import Foundation

/// Settings → Video & Device → When a Chat Opens. Runs just before a chat comes on
/// screen (`ChatTabsModel.onWillPresent`), so the header mounts already in
/// the chosen state — no frame of the wrong layout, no engine started and
/// immediately torn down.
@MainActor
enum ChatOpenVideoPolicy {
    /// A Wi-Fi autoplay decision waiting for the first network sample
    /// (cold start). It belongs to one opening: the next one cancels it.
    private static var pendingDecision: Task<Void, Never>?

    static func apply(
        opening tab: ChatTab,
        intent: ChatOpenIntent,
        chatTabs: ChatTabsModel?,
        playback: PlaybackCenter?
    ) {
        pendingDecision?.cancel()
        pendingDecision = nil
        guard let playback else { return }

        // Going back to the stream that's playing (from the mini player or
        // PiP) carries on exactly as it was. Any other chat gets the
        // preference, even while a different stream plays.
        if isPlaying(tab, in: playback) { return }
        playback.startNextStreamMuted = false

        // Watch / Listen / Chat Only from the preview menu already set the
        // video state (and audio-only) the user asked for: honour it, with
        // sound, on any network.
        if intent == .explicit { return }

        switch PlaybackPreferences.videoOnOpen {
        case .lastUsed:
            return
        case .closed:
            setVideoOpen(false)
        case .autoplayOnWiFi:
            // Audio-only has no video to autoplay; leave it closed. (With
            // the native engine switched off there is no audio-only: the
            // stream shows as video.)
            if UserDefaults.standard.bool(forKey: PlayerSettings.audioOnlyKey),
               PlayerSettings.isNativePlaybackEnabled {
                setVideoOpen(false)
                return
            }
            if let onWiFi = NetworkReachability.shared.knownIsOnWiFi {
                autoplay(onWiFi, playback: playback)
                return
            }
            // No network sample yet (a chat restored at launch): mount
            // closed and decide once the first sample lands, waiting at most
            // half a second. Only this opening is affected, and only while
            // it's still the chat on screen.
            setVideoOpen(false)
            let tabId = tab.id
            pendingDecision = Task { [weak playback, weak chatTabs] in
                let onWiFi = await NetworkReachability.shared.isOnWiFi(waitingUpTo: .milliseconds(500))
                guard !Task.isCancelled, onWiFi,
                      let playback, let chatTabs,
                      chatTabs.isPresented, chatTabs.activeTabId == tabId,
                      !isPlaying(tab, in: playback)
                else { return }
                autoplay(true, playback: playback)
            }
        }
    }

    private static func isPlaying(_ tab: ChatTab, in playback: PlaybackCenter) -> Bool {
        tab.channels.contains { playback.isPlayingOrPinned($0.channelId) }
    }

    /// Open and muted on an unmetered connection, closed otherwise.
    private static func autoplay(_ onWiFi: Bool, playback: PlaybackCenter) {
        playback.startNextStreamMuted = onWiFi
        setVideoOpen(onWiFi)
    }

    /// Written only on change: `@AppStorage` readers (the header, the
    /// compose bar) re-render on every write.
    private static func setVideoOpen(_ open: Bool) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: StreamHeaderView.expandedKey) != open {
            defaults.set(open, forKey: StreamHeaderView.expandedKey)
        }
    }
}
#endif
