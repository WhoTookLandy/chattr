#if os(iOS)
import UIKit
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
    private(set) var teardownCount = 0

    init(_ request: StreamEngineRequest, controller: StreamPlayerController) {
        self.request = request
        startedMuted = controller.startsMuted
        switch request {
        case .native:
            kind = .native
            autoplay = nil
        case .web:
            kind = .web
            // The first step of the web engine's startup sequence
            // (`WebStreamEngine.init`).
            autoplay = controller.beginWebEngineLoad()
        }
    }

    func teardown() {
        teardownCount += 1
    }
}

/// Hands `PlaybackCenter` fake engines and keeps each one it built, in
/// order.
@MainActor
final class FakeStreamEngines {
    private(set) var built: [FakeStreamEngine] = []

    var factory: StreamEngineFactory {
        return { [self] (request: StreamEngineRequest, controller: StreamPlayerController) -> any StreamEngine in
            let engine = FakeStreamEngine(request, controller: controller)
            built.append(engine)
            return engine
        }
    }

    /// A center that can only build fake engines.
    func center() -> PlaybackCenter {
        PlaybackCenter(makeEngine: factory)
    }
}
#endif
