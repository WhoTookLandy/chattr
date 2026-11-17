#if os(iOS)
import Testing
@testable import Features

/// Whether a clip's hold on the live stream resumes it on release
/// (`PlaybackCenter.resumesOnRelease`). Driven through the controller's
/// state and its user-facing `togglePlay` — with no engine attached
/// (`avPlayer`/`webView` nil) the commands are no-ops, so only the intent
/// bookkeeping runs.
@MainActor
@Suite("Playback hold intent")
struct PlaybackHoldIntentTests {
    @Test("A stream still loading toward autoplay resumes")
    func loadingResumes() {
        let controller = StreamPlayerController()
        #expect(PlaybackCenter.resumesOnRelease(controller))
    }

    @Test("A user pause while buffering before the first frame doesn't resume")
    func pausedWhileBufferingStaysPaused() {
        let controller = StreamPlayerController()
        // Buffering: the engine reports not paused, nothing started yet.
        #expect(!controller.hasStarted)
        #expect(!controller.isPaused)
        controller.togglePlay()
        #expect(!controller.wantsPlayback)
        #expect(!PlaybackCenter.resumesOnRelease(controller))
    }

    @Test("Playing again after a user pause resumes")
    func pauseThenPlayResumes() {
        let controller = StreamPlayerController()
        controller.togglePlay()
        // The engine now reports paused; the control shows "play".
        controller.update(\.isPaused, to: true)
        controller.togglePlay()
        #expect(controller.wantsPlayback)
    }

    @Test("A started stream paused from outside our controls doesn't resume")
    func externalPauseAfterStartStaysPaused() {
        let controller = StreamPlayerController()
        controller.noteDidPlay()
        controller.update(\.isPaused, to: true)
        #expect(!PlaybackCenter.resumesOnRelease(controller))
    }

    @Test("Seen playing restores intent, unless it's autoplay under a hold")
    func playingRestoresIntent() {
        let controller = StreamPlayerController()
        controller.togglePlay()
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)

        controller.togglePlay()
        controller.beginHold()
        controller.noteDidPlay()
        #expect(!controller.wantsPlayback)
        controller.endHold(resume: false)
    }
}
#endif
