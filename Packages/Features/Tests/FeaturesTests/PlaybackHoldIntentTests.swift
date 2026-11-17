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

    @Test("Seen playing again after starting restores intent, unless it's autoplay under a hold")
    func playingRestoresIntent() {
        let controller = StreamPlayerController()
        controller.noteDidPlay()
        controller.togglePlay()
        #expect(!controller.wantsPlayback)
        controller.update(\.isPaused, to: true)
        controller.noteDidPause()
        // Resumed from outside our controls (PiP window, lock screen).
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)

        controller.update(\.isPaused, to: false)
        controller.togglePlay()
        controller.beginHold()
        controller.noteDidPlay()
        #expect(!controller.wantsPlayback)
        controller.endHold(resume: false)
    }

    @Test("A buffering pause survives native → web fallback and a clip dismissed before the web player loads")
    func pauseSurvivesFallbackAutoplay() {
        let controller = StreamPlayerController()
        // Native buffering, no frames yet: the user pauses.
        controller.togglePlay()
        // A clip opens: the hold won't resume on release.
        #expect(!PlaybackCenter.resumesOnRelease(controller))
        controller.beginHold()
        // Native fails; `PlaybackCenter` rebuilds on the web engine.
        controller.reset()
        // The clip is dismissed before the web page has loaded.
        controller.endHold(resume: false)

        // The page autoplays: paused again, intent untouched — including a
        // repeat report before the pause lands.
        controller.noteDidPlay()
        #expect(!controller.wantsPlayback)
        #expect(controller.isPausingAutoplay)
        controller.noteDidPlay()
        #expect(!controller.wantsPlayback)

        // Paused. A later play is a real resume.
        controller.noteDidPause()
        #expect(!controller.isPausingAutoplay)
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
    }

    @Test("Autoplay of a stream meant to play leaves intent alone")
    func autoplayWhenWantedKeepsPlaying() {
        let controller = StreamPlayerController()
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
        #expect(!controller.isPausingAutoplay)
    }
}

@MainActor
@Suite("Per-channel PiP flag lifetime")
struct PictureInPictureFlagLifetimeTests {
    @Test("A flag keeps its identity while mounted and goes once unowned")
    func flagEvictedWhenUnowned() async {
        let center = PlaybackCenter()
        // body read, then appear.
        let flag = center.pictureInPictureFlag(for: "1")
        center.retainPictureInPictureFlag(for: "1")
        center.retainPictureInPictureFlag(for: "1")
        center.releasePictureInPictureFlag(for: "1")
        await Task.yield()
        #expect(center.pictureInPictureFlag(for: "1") === flag)

        // Remount: the new view reads and appears before the drop runs.
        center.releasePictureInPictureFlag(for: "1")
        center.retainPictureInPictureFlag(for: "1")
        await Task.yield()
        #expect(center.pictureInPictureFlag(for: "1") === flag)

        center.releasePictureInPictureFlag(for: "1")
        for _ in 0..<5 { await Task.yield() }
        #expect(center.pictureInPictureFlagCount == 0)
    }
}
#endif
