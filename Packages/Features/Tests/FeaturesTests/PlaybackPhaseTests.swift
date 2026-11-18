import Testing
import Core
@testable import Features

/// The one-value description of where playback is (`PlaybackPhase`), from
/// the flags it's derived from.
@Suite("Playback phase")
struct PlaybackPhaseTests {
    private func phase(
        isLoaded: Bool = true,
        hasEngine: Bool = true,
        isPaused: Bool = false,
        hasStarted: Bool = false,
        isBuffering: Bool = false
    ) -> PlaybackPhase {
        PlaybackPhase.resolve(
            isLoaded: isLoaded,
            hasEngine: hasEngine,
            isPaused: isPaused,
            hasStarted: hasStarted,
            isBuffering: isBuffering
        )
    }

    @Test("Nothing loaded is idle, whatever the controller's flags were left at")
    func idle() {
        #expect(phase(isLoaded: false, hasEngine: false) == .idle)
        #expect(phase(isLoaded: false, hasEngine: true, isPaused: true, hasStarted: true, isBuffering: true) == .idle)
    }

    @Test("Loaded with no engine is unloaded")
    func unloaded() {
        #expect(phase(hasEngine: false, isPaused: true) == .unloaded)
        #expect(phase(hasEngine: false, isPaused: false, hasStarted: true, isBuffering: true) == .unloaded)
    }

    @Test("No frame yet: loading, waiting on the network or not")
    func loading() {
        #expect(phase() == .loading)
        #expect(phase(isBuffering: true) == .loading)
    }

    @Test("Frames playing: playing")
    func playing() {
        #expect(phase(hasStarted: true) == .playing)
    }

    @Test("Waiting on the network after it had started: buffering, even while the failed player reports paused")
    func buffering() {
        #expect(phase(hasStarted: true, isBuffering: true) == .buffering)
        #expect(phase(isPaused: true, hasStarted: true, isBuffering: true) == .buffering)
        #expect(phase(isPaused: true, isBuffering: true) == .loading)
    }

    @Test("Paused, before or after the first frame")
    func paused() {
        #expect(phase(isPaused: true) == .paused)
        #expect(phase(isPaused: true, hasStarted: true) == .paused)
    }
}

#if os(iOS)
/// `PlaybackCenter.phase` over a stream's life, on a `FakeStreamEngine` with
/// the test reporting the engine's state.
@MainActor
@Suite("Playback center phase")
struct PlaybackCenterPhaseTests {
    static let channel = ChannelDescriptor(
        channelId: "1", channelLoginName: "x",
        channelDisplayName: "x", profileImageURL: nil
    )

    @Test("Idle, loading, playing, buffering, paused, unloaded, and idle again")
    func followsTheStream() {
        let center = FakeStreamEngines().center()
        let controller = center.controller
        #expect(center.phase == .idle)

        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        #expect(center.phase == .loading)

        // The native player's first buffer, then frames.
        controller.update(\.isBuffering, to: true)
        #expect(center.phase == .loading)
        controller.update(\.isBuffering, to: false)
        controller.noteDidPlay()
        #expect(center.phase == .playing)

        // A stall, and its end.
        controller.update(\.isBuffering, to: true)
        #expect(center.phase == .buffering)
        controller.update(\.isBuffering, to: false)
        #expect(center.phase == .playing)

        // The user pauses.
        controller.togglePlay()
        #expect(center.phase == .paused)

        center.unloadAfterLongPause()
        #expect(center.phase == .unloaded)

        // Play builds the engine again.
        controller.togglePlay()
        #expect(center.phase == .loading)

        center.stop()
        #expect(center.phase == .idle)
    }

    @Test("A stream that fell back to the web player goes through the same phases")
    func afterFallback() {
        let center = FakeStreamEngines().center()
        let controller = center.controller
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        defer { center.stop() }

        center.fallBackToWeb(quality: .auto)
        #expect(controller.nativeFailed)
        #expect(center.phase == .loading)

        // The page's first report, in the coordinator's order.
        controller.update(\.isPaused, to: false)
        controller.noteEngineReady(paused: false)
        controller.noteWebState(paused: false)
        controller.noteDidPlay()
        #expect(center.phase == .playing)

        controller.update(\.isPaused, to: true)
        #expect(center.phase == .paused)
    }
}
#endif
