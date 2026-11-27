import Testing
import Foundation
import TwitchKit
@testable import Features

/// What a chat page's header asks of the player (`StreamPlaybackPolicy`):
/// every branch of the decision, and when audio-only is really in effect.
@Suite("Stream playback policy")
struct StreamPlaybackPolicyTests {
    static let reading = Date(timeIntervalSince1970: 1_000)

    private func stream() throws -> TwitchStream {
        let json = """
        {"id":"s1","userId":"1","userLogin":"x","userName":"x","gameId":"1","gameName":"g",\
        "type":"live","title":"t","tags":[],"viewerCount":1,"startedAt":0,"language":"en",\
        "thumbnailUrl":"https://example.com/{width}x{height}.jpg","isMature":false}
        """
        return try JSONDecoder().decode(TwitchStream.self, from: Data(json.utf8))
    }

    /// The active page of a live channel with the video showing, its status
    /// loaded, nothing playing yet, and every preference at its default.
    private func watching() throws -> StreamPlaybackPolicy {
        let live = try stream()
        return StreamPlaybackPolicy(
            isActivePage: true,
            isExpanded: true,
            liveStream: live,
            statusFetchedAt: Self.reading,
            audioOnly: false,
            prefersNativePlayer: false,
            quality: .auto,
            isNativePlaybackEnabled: true,
            nativeFailed: false,
            playing: .nothing
        )
    }

    /// The decision to play `stream()` with these arguments.
    private func play(native: Bool, audioOnly: Bool, quality: PlayerQuality) throws -> StreamPlaybackPolicy.Decision {
        let live = try stream()
        let request = StreamPlaybackPolicy.PlayRequest(
            stream: live, native: native, audioOnly: audioOnly, quality: quality
        )
        return StreamPlaybackPolicy.Decision.play(request)
    }

    // MARK: Play

    @Test("Active, expanded and live: play this stream on the web player")
    func playsLiveStream() throws {
        let policy = try watching()
        let expected = try play(native: false, audioOnly: false, quality: .auto)
        #expect(policy.decision == expected)
    }

    @Test("Play is asked for whatever is loaded, and before the status has")
    func playsWhateverIsLoaded() throws {
        var policy = try watching()
        let expected = try play(native: false, audioOnly: false, quality: .auto)
        policy.playing = .thisChannel
        #expect(policy.decision == expected)
        policy.playing = .anotherChannel
        #expect(policy.decision == expected)
        // Live from the follows list alone, no status entry yet.
        policy.statusFetchedAt = nil
        #expect(policy.decision == expected)
    }

    @Test("The native preference and the quality cap are passed on")
    func passesNativeAndQuality() throws {
        var policy = try watching()
        policy.prefersNativePlayer = true
        policy.quality = .p720
        let expected = try play(native: true, audioOnly: false, quality: .p720)
        #expect(policy.decision == expected)
    }

    @Test("Audio-only asks for the native engine whatever the native preference says")
    func audioOnlyAsksForNative() throws {
        var policy = try watching()
        policy.audioOnly = true
        let expected = try play(native: true, audioOnly: true, quality: .auto)
        #expect(policy.decision == expected)
    }

    @Test("The kill switch and a failed native engine don't change what is asked for: the player applies them")
    func killSwitchAndFailureLeftToThePlayer() throws {
        var policy = try watching()
        policy.audioOnly = true
        policy.prefersNativePlayer = true
        let expected = try play(native: true, audioOnly: true, quality: .auto)
        policy.isNativePlaybackEnabled = false
        #expect(policy.decision == expected)
        policy.isNativePlaybackEnabled = true
        policy.nativeFailed = true
        #expect(policy.decision == expected)
    }

    // MARK: Leave alone

    @Test("A page that isn't the active one never acts")
    func inactivePageLeavesAlone() throws {
        var policy = try watching()
        policy.isActivePage = false
        #expect(policy.decision == .leaveAlone)

        // Not to stop what's playing either: a page being swiped away or
        // popped leaves the stream for the mini player.
        for playing in [StreamPlaybackPolicy.Playing.thisChannel, .anotherChannel] {
            policy.playing = playing
            policy.isExpanded = true
            policy.liveStream = nil
            #expect(policy.decision == .leaveAlone)
            policy.isExpanded = false
            #expect(policy.decision == .leaveAlone)
        }
    }

    @Test("Nothing to play and nothing playing: leave alone")
    func nothingPlayingLeavesAlone() throws {
        var policy = try watching()
        policy.liveStream = nil
        #expect(policy.decision == .leaveAlone)

        policy.liveStream = try stream()
        policy.isExpanded = false
        #expect(policy.decision == .leaveAlone)
    }

    @Test("Until the status has loaded, what's playing isn't stopped")
    func waitsForStatusBeforeStopping() throws {
        var policy = try watching()
        policy.liveStream = nil
        policy.statusFetchedAt = nil
        for playing in [StreamPlaybackPolicy.Playing.thisChannel, .anotherChannel] {
            policy.playing = playing
            policy.isExpanded = true
            #expect(policy.decision == .leaveAlone)
            policy.isExpanded = false
            #expect(policy.decision == .leaveAlone)
        }
    }

    // MARK: Stop

    @Test("This page's playing stream left out of a reading: stop only once the reading is confirmed")
    func offlineReadingOfPlayingStream() throws {
        var policy = try watching()
        policy.liveStream = nil
        policy.playing = .thisChannel
        #expect(policy.decision == .stopIfOfflineConfirmed(readingAt: Self.reading))

        let later = Self.reading.addingTimeInterval(60)
        policy.statusFetchedAt = later
        #expect(policy.decision == .stopIfOfflineConfirmed(readingAt: later))
    }

    @Test("This channel is offline while another chat's stream plays: stop it at once")
    func offlineChannelStopsAnotherStream() throws {
        var policy = try watching()
        policy.liveStream = nil
        policy.playing = .anotherChannel
        #expect(policy.decision == .stop)
    }

    @Test("Swiping onto a channel pinned in background audio stops non-PiP primary video without duplicating")
    func pinnedChannelStopsNonPiPPrimary() throws {
        var policy = try watching()
        policy.playing = .pinnedAudio
        policy.hasOtherPrimaryPlaying = true
        policy.isPrimaryInPictureInPicture = false
        #expect(policy.decision == .stop)

        // With nothing else playing in primary, leave the pinned stream alone.
        policy.hasOtherPrimaryPlaying = false
        #expect(policy.decision == .leaveAlone)

        // When another primary is floating in system PiP, preserve the PiP window.
        policy.hasOtherPrimaryPlaying = true
        policy.isPrimaryInPictureInPicture = true
        #expect(policy.decision == .leaveAlone)
    }

    @Test("Video hidden here: whatever is playing stops, live or not")
    func hiddenVideoStops() throws {
        var policy = try watching()
        policy.isExpanded = false
        for playing in [StreamPlaybackPolicy.Playing.thisChannel, .anotherChannel] {
            policy.playing = playing
            policy.liveStream = try stream()
            #expect(policy.decision == .stop)
            policy.liveStream = nil
            #expect(policy.decision == .stop)
        }
    }

    // MARK: Audio-only in effect

    @Test("Audio-only is in effect only with the preference on, the native path enabled and the native engine working")
    func audioOnlyInEffect() throws {
        var policy = try watching()
        #expect(!policy.isAudioOnlyInEffect)

        policy.audioOnly = true
        #expect(policy.isAudioOnlyInEffect)

        policy.isNativePlaybackEnabled = false
        #expect(!policy.isAudioOnlyInEffect)

        policy.isNativePlaybackEnabled = true
        policy.nativeFailed = true
        #expect(!policy.isAudioOnlyInEffect)

        // The failure alone, without the preference, isn't audio-only.
        policy.audioOnly = false
        #expect(!policy.isAudioOnlyInEffect)
    }

    @Test("The kill switch and the engine's state are read only as far as needed")
    func audioOnlyReadsLazily() {
        var reads: [String] = []
        func enabled(_ value: Bool) -> Bool {
            reads.append("enabled")
            return value
        }
        func failed(_ value: Bool) -> Bool {
            reads.append("failed")
            return value
        }

        let off = StreamPlaybackPolicy.audioOnlyInEffect(
            audioOnly: false, nativePlaybackEnabled: enabled(true), nativeFailed: failed(false)
        )
        #expect(!off)
        #expect(reads.isEmpty)

        let disabled = StreamPlaybackPolicy.audioOnlyInEffect(
            audioOnly: true, nativePlaybackEnabled: enabled(false), nativeFailed: failed(false)
        )
        #expect(!disabled)
        #expect(reads == ["enabled"])

        reads.removeAll()
        let on = StreamPlaybackPolicy.audioOnlyInEffect(
            audioOnly: true, nativePlaybackEnabled: enabled(true), nativeFailed: failed(false)
        )
        #expect(on)
        #expect(reads == ["enabled", "failed"])
    }
}
