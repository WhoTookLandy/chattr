#if os(iOS)
import SwiftUI

/// "This channel's stream is in the PiP window", observable per channel
/// (`PlaybackCenter.pictureInPictureFlag(for:)`). Written only by
/// `PlaybackCenter`, and only when the value changes.
@MainActor
@Observable
final class ChannelPictureInPictureFlag {
    var isActive = false
}

extension View {
    /// Keeps `channelId`'s PiP flag (`PlaybackCenter.pictureInPictureFlag(for:)`)
    /// alive while this view is mounted. Appear / disappear only — no
    /// observation, nothing per render.
    func retainsPictureInPictureFlag(for channelId: String, in center: PlaybackCenter?) -> some View {
        onAppear { center?.retainPictureInPictureFlag(for: channelId) }
            .onDisappear { center?.releasePictureInPictureFlag(for: channelId) }
    }
}
#endif
