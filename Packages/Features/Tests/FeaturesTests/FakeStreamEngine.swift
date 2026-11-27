#if os(iOS)
import UIKit
import os
@testable import Features

/// Stands in for a player engine in `PlaybackCenter` tests: no `WKWebView`,
/// no `AVPlayer`, no network. It behaves like a real engine that hasn't
/// loaded yet — a native one still resolving its playlist, or a web page
/// that hasn't reported — and records what it was built for and whether it
/// was torn down. A test plays the engine's part from there by calling the
/// controller's `note…` / `update` methods itself.
@MainActor
final class FakeStreamEngine: StreamEngine {
    let view = UIView()
    let kind: StreamEngineKind
    let request: StreamEngineRequest
    /// The `autoplay` a web page would have been built with; nil for the
    /// native engine, which checks `startsPlaying` when its load finishes.
    let autoplay: Bool?
    /// The controller's `startsMuted` when this engine was built.
    let startedMuted: Bool
    /// Whether this native engine was built eligible for PiP / interactive video.
    let allowsPictureInPicture: Bool
    /// Configurable for interruption / route-change unit tests.
    var fakeWasPlayingJustNow = true
    var wasPlayingJustNow: Bool { fakeWasPlayingJustNow }
    /// In-place `setAudioOnly(_:quality:)` calls received by this engine.
    private(set) var audioOnlyChanges: [(audioOnly: Bool, quality: PlayerQuality)] = []
    /// `setInteractive(_:)` calls received on promote/demote.
    private(set) var interactiveChanges: [Bool] = []
    private(set) var mediaResetCount = 0
    private(set) var teardownCount = 0

    init(_ request: StreamEngineRequest, controller: StreamPlayerController) {
        self.request = request
        startedMuted = controller.startsMuted
        switch request {
        case .native(_, _, _, let allowsPiP):
            kind = .native
            autoplay = nil
            allowsPictureInPicture = allowsPiP
        case .web:
            kind = .web
            allowsPictureInPicture = true
            // The first step of the web engine's startup sequence
            // (`WebStreamEngine.init`).
            autoplay = controller.beginWebEngineLoad()
        }
    }

    func setAudioOnly(_ audioOnly: Bool, quality: PlayerQuality) {
        audioOnlyChanges.append((audioOnly, quality))
    }

    func setInteractive(_ interactive: Bool) {
        interactiveChanges.append(interactive)
    }

    func handleMediaServicesReset() {
        mediaResetCount += 1
    }

    func teardown() {
        teardownCount += 1
    }
}

/// Thread-safe recorder for `PlaybackAudioSession` actions in unit tests.
final class RecordingAudioSessionDriver: PlaybackAudioSessionDriver, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(
        initialState: (actions: [(action: AudioSessionAction, force: Bool, inBackground: Bool)](), invalidations: 0)
    )

    var actions: [(action: AudioSessionAction, force: Bool, inBackground: Bool)] {
        state.withLock { $0.actions }
    }

    var invalidations: Int {
        state.withLock { $0.invalidations }
    }

    func apply(_ action: AudioSessionAction, force: Bool, inBackground: Bool) {
        state.withLock { $0.actions.append((action, force, inBackground)) }
    }

    func invalidate() {
        state.withLock { $0.invalidations += 1 }
    }
}

/// Hands `PlaybackCenter` fake engines and keeps each one it built, in
/// order.
@MainActor
final class FakeStreamEngines {
    private(set) var built: [FakeStreamEngine] = []
    let audioDriver = RecordingAudioSessionDriver()
    lazy var audioSession = PlaybackAudioSession(driver: audioDriver)

    var factory: StreamEngineFactory {
        return { [self] (request: StreamEngineRequest, controller: StreamPlayerController) -> any StreamEngine in
            let engine = FakeStreamEngine(request, controller: controller)
            built.append(engine)
            return engine
        }
    }

    /// A center that builds fake engines and records audio-session actions.
    func center() -> PlaybackCenter {
        PlaybackCenter(makeEngine: factory, audioSession: audioSession)
    }
}
#endif
