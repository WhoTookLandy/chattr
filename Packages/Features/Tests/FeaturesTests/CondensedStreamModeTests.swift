#if os(iOS)
import Testing
import Core
@testable import Features

/// When the chat header collapses and the nav bar carries the stream's
/// controls instead (`CondensedStreamMode.resolve`): the audio-only path,
/// the gates shared by both, and PiP as the controller reports it (the
/// system's part, AVKit telling the controller, isn't driven here).
@MainActor
@Suite("Condensed stream mode")
struct CondensedStreamModeTests {
    @Test("Audio-only on a live, expanded channel is condensed")
    func audioOnly() {
        let center = FakeStreamEngines().center()
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: true, playback: center
        ) == .audioOnly)
    }

    @Test("Video hidden, offline, no channel or no player: nothing condensed")
    func gates() {
        let center = FakeStreamEngines().center()
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
        let center = FakeStreamEngines().center()
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: false, playback: center
        ) == nil)
    }

    @Test("After the native engine fails, audio-only shows the video, not the condensed header")
    func nativeFailureShowsVideo() {
        let center = FakeStreamEngines().center()
        center.controller.nativeFailed = true
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: true, playback: center
        ) == nil)
    }

    @Test("The playing channel's stream in picture in picture is condensed; audio-only wins over it")
    func pictureInPicture() {
        let center = FakeStreamEngines().center()
        center.play(
            ChannelDescriptor(
                channelId: "1", channelLoginName: "x",
                channelDisplayName: "x", profileImageURL: nil
            ),
            title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        defer { center.stop() }
        center.controller.pictureInPictureDidStart()

        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: false, playback: center
        ) == .pictureInPicture)
        // Another chat's page isn't the one in the PiP window.
        #expect(CondensedStreamMode.resolve(
            channelId: "2", isLive: true, isExpanded: true, audioOnly: false, playback: center
        ) == nil)
        #expect(CondensedStreamMode.resolve(
            channelId: "1", isLive: true, isExpanded: true, audioOnly: true, playback: center
        ) == .audioOnly)
    }
}
#endif
