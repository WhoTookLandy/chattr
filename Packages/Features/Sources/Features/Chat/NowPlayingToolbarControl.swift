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
/// (`audioOnly`), pinned in background audio (`pinnedAudio`), or moved into
/// the system PiP window (`pictureInPicture`). In all three, `StreamHeaderView`
/// collapses to nothing and the stream's controls live in `ChatHeaderBar`.
enum CondensedStreamMode: Equatable {
    case audioOnly
    case pinnedAudio
    case pictureInPicture

    var systemImage: String {
        switch self {
        case .audioOnly, .pinnedAudio: "headphones"
        case .pictureInPicture: "pip"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .audioOnly: "Audio only"
        case .pinnedAudio: "Pinned in background audio"
        case .pictureInPicture: "Playing in picture in picture"
        }
    }

    /// Mirrors `StreamHeaderView.body`'s choice for the visible page:
    /// - If this channel is pinned in background audio (`pinnedAudioFlag`),
    ///   it is always condensed regardless of `isExpanded` / `audioOnly`.
    /// - Otherwise, when expanded and live, audio-only wins over PiP.
    @MainActor
    static func resolve(
        channelId: String?,
        isLive: Bool,
        isExpanded: Bool,
        audioOnly: Bool,
        playback: PlaybackCenter?
    ) -> Self? {
        guard let channelId, let playback else { return nil }
        if playback.pinnedAudioFlag(for: channelId).isPinned {
            return .pinnedAudio
        }
        guard isExpanded, isLive else { return nil }
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
