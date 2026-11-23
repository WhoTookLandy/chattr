import SwiftUI
import Core

extension ChatTabsModel {
    /// Channel of the page the pager shows: `activeTabId`, falling back to
    /// the first tab before scene restoration runs (matching the pager).
    var visibleChannelId: String? {
        guard let visibleId = activeTabId ?? tabs.first?.id else { return nil }
        return tabs.first(where: { $0.id == visibleId })?.channels.first?.channelId
    }
}

#if os(iOS)

/// The visible chat's stream is playing without its inline video: listen-only
/// (`audioOnly`) or moved into the system PiP window. In both, `StreamHeaderView`
/// collapses to nothing and the stream's controls live in `ChatHeaderBar`.
enum CondensedStreamMode: Equatable {
    case audioOnly
    case pictureInPicture

    var systemImage: String {
        switch self {
        case .audioOnly: "headphones"
        case .pictureInPicture: "pip"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .audioOnly: "Audio only"
        case .pictureInPicture: "Playing in picture in picture"
        }
    }

    /// Mirrors `StreamHeaderView.body`'s choice for the visible page: the
    /// header is expanded and the channel is live, then audio-only wins over
    /// PiP. Audio-only needs the native engine — after a fallback to web, or
    /// with the native path switched off, the header shows the video, so
    /// there's nothing condensed.
    @MainActor
    static func resolve(
        channelId: String?,
        isLive: Bool,
        isExpanded: Bool,
        audioOnly: Bool,
        playback: PlaybackCenter?
    ) -> Self? {
        guard let channelId, isExpanded, isLive, let playback else { return nil }
        if StreamPlaybackPolicy.audioOnlyInEffect(
            audioOnly: audioOnly,
            nativePlaybackEnabled: PlayerSettings.isNativePlaybackEnabled,
            nativeFailed: playback.controller.nativeFailed
        ) {
            return .audioOnly
        }
        if playback.controller.isPictureInPictureActive, playback.isPlaying(channelId) {
            return .pictureInPicture
        }
        return nil
    }
}

#endif
