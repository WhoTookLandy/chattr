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

    @Test("Seen playing restores intent, unless held — then it's paused again")
    func playingRestoresIntent() {
        let controller = StreamPlayerController()
        controller.noteDidPlay()
        controller.togglePlay()
        #expect(!controller.wantsPlayback)
        controller.update(\.isPaused, to: true)
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

    @Test("Paused before the first frame, then resumed from outside our controls, plays")
    func pauseBeforeStartThenExternalResumePlays() {
        let controller = StreamPlayerController()
        // Buffering, no frames yet: the user pauses. An engine built or
        // finishing its load now starts paused.
        controller.togglePlay()
        #expect(!controller.startsPlaying)
        // Native fullscreen / PiP / lock screen plays it: that's intent.
        controller.noteDidPlay()
        #expect(controller.hasStarted)
        #expect(controller.wantsPlayback)
        #expect(PlaybackCenter.resumesOnRelease(controller))
    }

    @Test("A buffering pause survives native → web fallback and a clip dismissed before the web player loads")
    func pauseSurvivesFallback() {
        let controller = StreamPlayerController()
        // Native buffering, no frames yet: the user pauses.
        controller.togglePlay()
        // A clip opens: the hold won't resume on release.
        #expect(!PlaybackCenter.resumesOnRelease(controller))
        controller.beginHold()
        // Native fails; `PlaybackCenter` rebuilds on the web engine, which
        // loads without autoplay.
        controller.reset()
        #expect(!controller.startsPlaying)
        let url = TwitchWebPlayer.playerURL("x", autoplay: controller.startsPlaying)
        #expect(url.absoluteString.contains("autoplay=false"))
        // The clip is dismissed before the web page has loaded.
        controller.endHold(resume: false)
        #expect(!controller.startsPlaying)

        // The page comes up paused and stays so.
        controller.noteEngineReady(paused: true)
        controller.update(\.isPaused, to: true)
        #expect(!controller.wantsPlayback)
        #expect(!PlaybackCenter.resumesOnRelease(controller))
    }

    @Test("A stream meant to play starts playing; its play report keeps intent")
    func startsPlayingWhenWanted() {
        let controller = StreamPlayerController()
        #expect(controller.startsPlaying)
        controller.beginHold()
        #expect(!controller.startsPlaying)
        controller.endHold(resume: true)
        #expect(controller.startsPlaying)
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
    }
}

@MainActor
@Suite("Per-channel PiP flag lifetime")
struct PictureInPictureFlagLifetimeTests {
    @Test("A flag keeps its identity while mounted and goes once unowned")
    func flagEvictedWhenUnowned() {
        let center = PlaybackCenter()
        // body read, then appear.
        let flag = center.pictureInPictureFlag(for: "1")
        center.retainPictureInPictureFlag(for: "1")
        center.retainPictureInPictureFlag(for: "1")
        center.releasePictureInPictureFlag(for: "1")
        center.drainPendingEvictions()
        #expect(center.pictureInPictureFlag(for: "1") === flag)

        // Remount: the new view reads and appears before the drop runs.
        center.releasePictureInPictureFlag(for: "1")
        center.retainPictureInPictureFlag(for: "1")
        center.drainPendingEvictions()
        #expect(center.pictureInPictureFlag(for: "1") === flag)

        center.releasePictureInPictureFlag(for: "1")
        center.drainPendingEvictions()
        #expect(center.pictureInPictureFlagCount == 0)
    }
}
#endif
