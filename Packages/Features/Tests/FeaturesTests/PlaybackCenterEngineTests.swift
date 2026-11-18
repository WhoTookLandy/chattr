#if os(iOS)
import Testing
import Core
@testable import Features

/// Which engine `PlaybackCenter.play` asks its factory for, and when it
/// builds, keeps or tears one down — on `FakeStreamEngine`s, so the web
/// path runs without a `WKWebView`.
///
/// The native path's kill switch is a `UserDefaults` read
/// (`PlayerSettings.isNativePlaybackEnabled`); these leave it at its
/// default, on.
@MainActor
@Suite("Playback center engines")
struct PlaybackCenterEngineTests {
    static let channel = ChannelDescriptor(
        channelId: "1", channelLoginName: "x",
        channelDisplayName: "x", profileImageURL: nil
    )
    static let otherChannel = ChannelDescriptor(
        channelId: "2", channelLoginName: "y",
        channelDisplayName: "y", profileImageURL: nil
    )

    private func play(
        _ channel: ChannelDescriptor,
        on center: PlaybackCenter,
        native: Bool,
        quality: PlayerQuality = .auto
    ) {
        center.play(
            channel, title: "x", profileImageURL: nil,
            native: native, audioOnly: false, quality: quality
        )
    }

    @Test("Native asked for: one native engine, for that login and quality")
    func nativeRequest() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        play(Self.channel, on: center, native: true, quality: .p720)
        defer { center.stop() }

        #expect(engines.built.count == 1)
        #expect(center.engine?.kind == .native)
        guard case .native(let login, let audioOnly, let quality)? = engines.built.first?.request else {
            Issue.record("Expected a native engine request")
            return
        }
        #expect(login == "x")
        #expect(!audioOnly)
        #expect(quality == .p720)
    }

    @Test("Native not asked for: a web page, built to autoplay, with no web view to reuse")
    func webRequest() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        play(Self.channel, on: center, native: false)
        defer { center.stop() }

        #expect(engines.built.count == 1)
        #expect(center.engine?.kind == .web)
        #expect(engines.built.first?.autoplay == true)
        #expect(center.controller.isAwaitingWebEngine)
        guard case .web(let login, let recycled)? = engines.built.first?.request else {
            Issue.record("Expected a web engine request")
            return
        }
        #expect(login == "x")
        let reusesWebView = recycled != nil
        #expect(!reusesWebView)
    }

    @Test("Asked for the stream it's already playing: no rebuild, only the quality is applied")
    func sameStreamKeepsEngine() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        play(Self.channel, on: center, native: true)
        defer { center.stop() }

        play(Self.channel, on: center, native: true, quality: .p480)
        #expect(engines.built.count == 1)
        #expect(engines.built.first?.teardownCount == 0)
        #expect(center.controller.preferredQuality == .p480)
    }

    @Test("Another channel: the old engine is torn down, a new one built, and a hold on the old stream lapses")
    func channelChangeRebuilds() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        play(Self.channel, on: center, native: true)
        defer { center.stop() }
        let hold = center.holdPlayback(.clip)
        #expect(hold != nil)

        play(Self.otherChannel, on: center, native: true)
        #expect(engines.built.count == 2)
        #expect(engines.built.first?.teardownCount == 1)
        #expect(engines.built.last?.teardownCount == 0)
        #expect(center.isPlaying(Self.otherChannel.channelId))
        #expect(!center.controller.isHeld)
        // Releasing the lapsed hold does nothing to the new stream.
        if let hold { center.releaseHold(hold) }
        #expect(center.controller.startsPlaying)
    }

    @Test("Falling back to web rebuilds the same stream on a web page; a hold out keeps it from autoplaying")
    func fallbackKeepsHold() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        play(Self.channel, on: center, native: true)
        defer { center.stop() }
        let controller = center.controller
        let hold = center.holdPlayback(.clip)
        #expect(hold != nil)

        center.fallBackToWeb(quality: .auto)
        #expect(engines.built.count == 2)
        #expect(engines.built.first?.teardownCount == 1)
        #expect(center.engine?.kind == .web)
        #expect(controller.nativeFailed)
        #expect(center.isPlaying(Self.channel.channelId))
        // Same stream, so the hold is still out and the page loads paused.
        #expect(controller.isHeld)
        #expect(engines.built.last?.autoplay == false)

        // The native engine stays failed for this channel.
        play(Self.channel, on: center, native: true)
        #expect(engines.built.count == 2)

        if let hold { center.releaseHold(hold) }
        #expect(!controller.isHeld)
        #expect(controller.startsPlaying)
    }

    @Test("A new stream starts muted when asked to, once")
    func startsNextStreamMuted() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        center.startNextStreamMuted = true
        play(Self.channel, on: center, native: false)
        defer { center.stop() }

        #expect(engines.built.first?.startedMuted == true)
        #expect(center.controller.isMuted)
        #expect(!center.startNextStreamMuted)

        play(Self.otherChannel, on: center, native: false)
        #expect(engines.built.last?.startedMuted == false)
        #expect(!center.controller.isMuted)
    }

    @Test("Stop tears the engine down and leaves nothing loaded")
    func stopTearsDown() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        play(Self.channel, on: center, native: false)

        center.stop()
        #expect(engines.built.first?.teardownCount == 1)
        #expect(center.engine == nil)
        #expect(center.channel == nil)
        #expect(!center.controller.isAwaitingWebEngine)
    }
}
#endif
