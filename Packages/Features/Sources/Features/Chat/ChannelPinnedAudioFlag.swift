#if os(iOS)
import SwiftUI

/// "This channel is currently pinned in background audio", observable per
/// channel (`PlaybackCenter.pinnedAudioFlag(for:)`). Written only by
/// `PlaybackCenter`, and only when the value changes, so pinning/unpinning
/// one channel never re-renders pre-mounted pager neighbours or unrelated rows.
@MainActor
@Observable
final class ChannelPinnedAudioFlag {
    var isPinned = false
}

extension View {
    /// Keeps `channelId`'s pinned-audio flag alive while this view is mounted.
    /// Appear / disappear only — no observation, nothing per render.
    func retainsPinnedAudioFlag(for channelId: String, in center: PlaybackCenter?) -> some View {
        onAppear { center?.retainPinnedAudioFlag(for: channelId) }
            .onDisappear { center?.releasePinnedAudioFlag(for: channelId) }
    }
}
#endif
