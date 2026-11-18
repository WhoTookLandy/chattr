#if os(iOS)
import Testing
import Foundation
import Core
import TwitchKit
@testable import Features

/// A resolver that never answers: the native engine stays "resolving its
/// playlist" for the length of a test, with no network and no AVPlayer.
private struct PendingResolver: StreamPlaylistResolving {
    func playlist(login: String, audioOnly: Bool) async throws -> StreamPlaylist {
        try await Task.sleep(for: .seconds(3600))
        throw StreamPlaylistError.unavailable
    }
}

/// `PlaybackCenter`'s own decisions — what keeps the screen awake, when an
/// offline reading stops the stream, and the long-pause unload — driven
/// on a `FakeStreamEngine` (a native engine still loading), so only the
/// bookkeeping runs.
@MainActor
@Suite("Playback center policy")
struct PlaybackCenterPolicyTests {
    static let channel = ChannelDescriptor(
        channelId: "1", channelLoginName: "x",
        channelDisplayName: "x", profileImageURL: nil
    )

    private func playingCenter() -> PlaybackCenter {
        playingCenter(FakeStreamEngines())
    }

    private func playingCenter(_ engines: FakeStreamEngines) -> PlaybackCenter {
        let center = engines.center()
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        return center
    }

    private func stream(userId: String) throws -> TwitchStream {
        let json = """
        {"id":"s1","userId":"\(userId)","userLogin":"x","userName":"x","gameId":"1","gameName":"g",\
        "type":"live","title":"t","tags":[],"viewerCount":1,"startedAt":0,"language":"en",\
        "thumbnailUrl":"https://example.com/{width}x{height}.jpg","isMature":false}
        """
        return try JSONDecoder().decode(TwitchStream.self, from: Data(json.utf8))
    }

    @Test("The screen is held awake only while a stream is loaded and not paused")
    func holdsScreenAwake() {
        #expect(!FakeStreamEngines().center().holdsScreenAwake)

        let center = playingCenter()
        defer { center.stop() }
        #expect(center.holdsScreenAwake)

        center.controller.togglePlay()
        #expect(center.controller.isPaused)
        #expect(!center.holdsScreenAwake)

        center.controller.togglePlay()
        #expect(center.holdsScreenAwake)

        center.stop()
        #expect(!center.holdsScreenAwake)
    }

    @Test("One offline reading keeps the stream playing and on screen; a second one stops it")
    func offlineNeedsTwoReadings() throws {
        let center = playingCenter()
        defer { center.stop() }
        let live = try stream(userId: Self.channel.channelId)
        let firstReading = Date(timeIntervalSince1970: 1_000)

        // The poll drops the stream.
        center.noteWentOffline(live)
        #expect(center.stream(for: Self.channel.channelId, live: nil) == live)
        #expect(!center.offlineReadingConfirmed(at: firstReading))
        // The same reading asked about again (the page re-syncing) changes nothing.
        #expect(!center.offlineReadingConfirmed(at: firstReading))
        // The next poll still says offline.
        #expect(center.offlineReadingConfirmed(at: firstReading.addingTimeInterval(60)))
    }

    @Test("An offline reading judged before the drop was reported still keeps the stream up")
    func offlineReadingBeforeDropReported() throws {
        let center = playingCenter()
        defer { center.stop() }
        let live = try stream(userId: Self.channel.channelId)
        let firstReading = Date(timeIntervalSince1970: 1_000)
        // The header played it…
        center.noteLive(live)

        // …and its playback task saw the drop before its `onChange` did.
        #expect(!center.offlineReadingConfirmed(at: firstReading))
        #expect(center.stream(for: Self.channel.channelId, live: nil) == live)
        #expect(center.offlineReadingConfirmed(at: firstReading.addingTimeInterval(60)))
    }

    @Test("The stream showing up again clears the offline reading")
    func liveAgainClearsOfflineReading() throws {
        let center = playingCenter()
        defer { center.stop() }
        let live = try stream(userId: Self.channel.channelId)
        let firstReading = Date(timeIntervalSince1970: 1_000)

        center.noteWentOffline(live)
        #expect(!center.offlineReadingConfirmed(at: firstReading))
        // Live in the next poll: the header asks to play it again.
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        #expect(center.stream(for: Self.channel.channelId, live: nil) == nil)

        // A later drop starts over: its first reading doesn't stop either.
        center.noteWentOffline(live)
        #expect(!center.offlineReadingConfirmed(at: firstReading.addingTimeInterval(600)))
    }

    @Test("Another channel's offline reading isn't softened")
    func otherChannelOfflineStopsAtOnce() throws {
        let center = playingCenter()
        defer { center.stop() }
        let other = try stream(userId: "2")
        center.noteWentOffline(other)
        #expect(center.stream(for: "2", live: nil) == nil)
        #expect(center.offlineReadingConfirmed(at: Date(timeIntervalSince1970: 1_000)))
    }

    @Test("A long pause unloads the engine but keeps the stream; play builds it again")
    func longPauseUnloadsAndPlayRestores() {
        let engines = FakeStreamEngines()
        let center = playingCenter(engines)
        defer { center.stop() }
        let controller = center.controller

        // Not paused: nothing to unload.
        center.unloadAfterLongPause()
        #expect(center.engine != nil)
        #expect(engines.built.first?.teardownCount == 0)

        controller.togglePlay()
        #expect(controller.isPaused)
        center.unloadAfterLongPause()
        #expect(center.engine == nil)
        #expect(engines.built.first?.teardownCount == 1)
        #expect(center.isPlaying(Self.channel.channelId))
        #expect(controller.isPaused)

        // The header asking for the same stream again doesn't rebuild it.
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        #expect(center.engine == nil)
        #expect(engines.built.count == 1)

        // Play.
        controller.togglePlay()
        #expect(center.engine != nil)
        #expect(engines.built.count == 2)
        #expect(engines.built.last?.kind == .native)
        #expect(controller.wantsPlayback)
        #expect(!controller.isPaused)
    }

    @Test("Handed no factory, the center builds the real engine")
    func defaultFactoryBuildsRealEngine() {
        // The one test here on a real engine: a `NativeStreamEngine` whose
        // playlist never resolves, so no `AVPlayer` is made.
        let center = PlaybackCenter(playlistResolver: PendingResolver())
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        defer { center.stop() }
        #expect(center.engine is NativeStreamEngine)
        #expect(center.engine?.kind == .native)
        #expect(!center.controller.isNative)
        // What `FakeStreamEngine` stands in for, checked on the real one
        // (as `pauseThenPlayWhileNativeLoads` did before it moved to the
        // fake): still resolving, it reports no page and no pause, and a
        // tap flips intent and the control.
        let controller = center.controller
        #expect(!controller.isAwaitingWebEngine)
        #expect(!controller.isPaused)
        controller.togglePlay()
        #expect(!controller.wantsPlayback)
        #expect(controller.isPaused)
        controller.togglePlay()
        #expect(controller.wantsPlayback)
        #expect(!controller.isPaused)
    }

    @Test("A stream paused by a hold isn't unloaded")
    func heldPauseKeepsEngine() {
        let center = playingCenter()
        defer { center.stop() }
        let hold = center.holdPlayback(.clip)
        #expect(hold != nil)
        center.controller.update(\.isPaused, to: true)

        center.unloadAfterLongPause()
        #expect(center.engine != nil)
        if let hold { center.releaseHold(hold) }
    }
}
#endif
