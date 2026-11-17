#if os(iOS)
import Testing
import Core
@testable import Features

/// When the chat header collapses and the nav bar carries the stream's
/// controls instead (`CondensedStreamMode.resolve`). The PiP case is driven
/// by AVKit (`isPictureInPictureActive` is set only by the system), so these
/// cover the audio-only path and the gates shared by both.
@MainActor
@Suite("Condensed stream mode")
struct CondensedStreamModeTests {
    @Test("Audio-only on a live, expanded channel is condensed")
    func audioOnly() {
        let center = PlaybackCenter()
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: true, playback: center
        ) == .audioOnly)
    }

    @Test("Video hidden, offline, no channel or no player: nothing condensed")
    func gates() {
        let center = PlaybackCenter()
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: false, audioOnly: true, playback: center
        ) == nil)
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: false, isExpanded: true, audioOnly: true, playback: center
        ) == nil)
        #expect(CondensedStreamMode.resolve(
            channelId: nil, isLive: true, isExpanded: true, audioOnly: true, playback: center
        ) == nil)
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: true, playback: nil
        ) == nil)
    }

    @Test("Watching video normally is not condensed")
    func watchingVideo() {
        let center = PlaybackCenter()
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: false, playback: center
        ) == nil)
    }

    @Test("After the native engine fails, audio-only shows the video, not the condensed header")
    func nativeFailureShowsVideo() {
        let center = PlaybackCenter()
        center.controller.nativeFailed = true
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: true, playback: center
        ) == nil)
    }
}
#endif
