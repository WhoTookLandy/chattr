#if os(iOS)
import Testing
import Core
@testable import Features

/// Whether a clip's hold on the live stream resumes it on release
/// (`PlaybackCenter.resumesOnRelease`). Driven through the controller's
/// state and its user-facing `togglePlay` — with no engine attached
/// (`avPlayer`/`webView` nil) the commands are no-ops, so only the intent
/// bookkeeping runs.
@MainActor
@Suite("Playback hold intent")
struct PlaybackHoldIntentTests {
    static let channel = ChannelDescriptor(
        channelId: "1", channelLoginName: "x",
        channelDisplayName: "x", profileImageURL: nil
    )

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
        // No engine has reported yet: each tap flips intent and shows it.
        controller.togglePlay()
        #expect(!controller.wantsPlayback)
        #expect(controller.isPaused)
        controller.togglePlay()
        #expect(controller.wantsPlayback)
        #expect(!controller.isPaused)
    }

    @Test("Native playlist still loading: pause then play updates the control and intent")
    func pauseThenPlayWhileNativeLoads() {
        let center = PlaybackCenter()
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        defer { center.stop() }
        let controller = center.controller
        // Resolving the playlist: no AVPlayer, no web page.
        #expect(!controller.isNative)
        #expect(!controller.isAwaitingWebEngine)
        #expect(!controller.isPaused)

        controller.togglePlay()
        #expect(!controller.wantsPlayback)
        #expect(controller.isPaused)
        #expect(!controller.startsPlaying)

        controller.togglePlay()
        #expect(controller.wantsPlayback)
        #expect(!controller.isPaused)
        #expect(controller.startsPlaying)
    }

    @Test("Clip, then background, then the clip released in the background: stays paused until the app returns")
    func clipReleasedWhileBackgroundedStaysPaused() {
        let center = PlaybackCenter()
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        defer { center.stop() }
        let controller = center.controller
        let clip = center.holdPlayback(.clip)
        #expect(clip != nil)
        // The clip's hold paused the stream (PiP off, so nothing else
        // keeps it going in the background).
        controller.update(\.isPaused, to: true)

        center.lifecycle?.didEnterBackground()
        #expect(controller.holds.contains(.background))

        // The clip goes while the app is still in the background.
        if let clip { center.releaseHold(clip) }
        #expect(controller.isHeld)
        #expect(!controller.startsPlaying)

        // Back in the foreground: the background hold inherited the
        // clip's resume and hands the stream back.
        center.lifecycle?.willEnterForeground()
        #expect(!controller.isHeld)
        #expect(controller.startsPlaying)
    }

    @Test("PiP starting after a background hold was taken drops the hold without resuming")
    func pictureInPictureStartReleasesBackgroundHold() {
        // The page-side pause a background hold sends skips a video in PiP.
        #expect(TwitchWebPlayer.bridgeScript.contains("pauseUnlessPictureInPicture"))

        let center = PlaybackCenter()
        center.play(
            Self.channel, title: "x", profileImageURL: nil,
            native: true, audioOnly: false, quality: .auto
        )
        defer { center.stop() }
        let controller = center.controller
        // The app leaves before PiP has reported starting.
        center.lifecycle?.didEnterBackground()
        #expect(controller.holds.contains(.background))

        // `pipStart` arrives: PiP owns playback now.
        controller.pictureInPictureDidStart()
        #expect(!controller.isHeld)
        #expect(controller.startsPlaying)
        // A play from the PiP window is intent, not paused again.
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)

        // The observer's lapsed hold is ignored on return, and a later
        // background hold can be taken again.
        center.lifecycle?.willEnterForeground()
        #expect(!controller.isHeld)
        controller.pictureInPictureEndedAmbiguously()
        let again = center.holdPlayback(.background)
        #expect(again != nil)
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
        controller.beginHold(.clip)
        controller.noteDidPlay()
        #expect(!controller.wantsPlayback)
        controller.endHold(.clip, resume: false)
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

    @Test("Paused before the web page is ready: its startup autoplay doesn't override the pause")
    func pauseBeforeWebReadyStaysPaused() {
        let controller = StreamPlayerController()
        // The page is built meant to play.
        #expect(controller.beginWebEngineLoad())
        #expect(controller.isAwaitingWebEngine)
        // The user pauses before the bridge exists: recorded, not sent.
        controller.togglePlay()
        #expect(!controller.wantsPlayback)
        #expect(controller.isPaused)

        // Twitch autoplays; the first state report says playing, in the
        // coordinator's order: ready, state, then the play report.
        controller.update(\.isPaused, to: false)
        controller.noteEngineReady(paused: false)
        #expect(!controller.isAwaitingWebEngine)
        #expect(controller.isSettlingWebStartup)
        controller.noteWebState(paused: false)
        controller.noteDidPlay()
        #expect(!controller.wantsPlayback)

        // The startup pause lands.
        controller.update(\.isPaused, to: true)
        controller.noteWebState(paused: true)
        #expect(!controller.isSettlingWebStartup)
        #expect(!controller.wantsPlayback)
        #expect(!controller.startsPlaying)
        #expect(!PlaybackCenter.resumesOnRelease(controller))

        // From here a play report is intent again (PiP window, lock screen).
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
    }

    @Test("Paused first report: a late autoplay is still undone, a later genuine play counts")
    func pausedFirstReportDoesNotSwallowLaterPlay() {
        let controller = StreamPlayerController()
        #expect(controller.beginWebEngineLoad())
        controller.togglePlay()
        #expect(!controller.wantsPlayback)

        // The first report is already paused: Twitch hasn't autoplayed yet.
        controller.noteEngineReady(paused: true)
        controller.noteWebState(paused: true)
        #expect(controller.isSettlingWebStartup)
        // Twitch's autoplay arrives late, inside the window: undone.
        controller.noteDidPlay()
        #expect(!controller.wantsPlayback)

        // Twitch never autoplays this time; the window runs out. A play
        // from the PiP window or lock screen afterwards is the user's.
        let other = StreamPlayerController()
        other.webStartupSettleWindow = .zero
        #expect(other.beginWebEngineLoad())
        other.togglePlay()
        other.noteEngineReady(paused: true)
        other.noteWebState(paused: true)
        #expect(!other.isSettlingWebStartup)
        other.noteDidPlay()
        #expect(other.wantsPlayback)
    }

    @Test("Play pressed again before the web page is ready plays once it is")
    func pauseThenPlayBeforeWebReadyPlays() {
        let controller = StreamPlayerController()
        _ = controller.beginWebEngineLoad()
        controller.togglePlay()
        controller.togglePlay()
        #expect(controller.wantsPlayback)
        #expect(!controller.isPaused)
        controller.noteEngineReady(paused: false)
        #expect(!controller.isSettlingWebStartup)
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
    }

    @Test("A buffering pause survives native → web fallback and a clip dismissed before the web player loads")
    func pauseSurvivesFallback() {
        let controller = StreamPlayerController()
        // Native buffering, no frames yet: the user pauses.
        controller.togglePlay()
        // A clip opens: the hold won't resume on release.
        #expect(!PlaybackCenter.resumesOnRelease(controller))
        controller.beginHold(.clip)
        // Native fails; `PlaybackCenter` rebuilds on the web engine, which
        // loads without autoplay.
        controller.reset()
        #expect(!controller.startsPlaying)
        let url = TwitchWebPlayer.playerURL("x", autoplay: controller.startsPlaying)
        #expect(url.absoluteString.contains("autoplay=false"))
        // The clip is dismissed before the web page has loaded.
        controller.endHold(.clip, resume: false)
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
        controller.beginHold(.clip)
        #expect(!controller.startsPlaying)
        controller.endHold(.clip, resume: true)
        #expect(controller.startsPlaying)
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
    }

    @Test("Clip and background holds stack: nothing starts until the last one goes")
    func holdsStack() {
        let controller = StreamPlayerController()
        controller.beginHold(.clip)
        controller.beginHold(.background)
        #expect(controller.isHeld)
        // The clip is dismissed while the app is still in the background.
        controller.endHold(.clip, resume: true)
        #expect(controller.isHeld)
        #expect(!controller.startsPlaying)
        let url = TwitchWebPlayer.playerURL("x", autoplay: controller.startsPlaying)
        #expect(url.absoluteString.contains("autoplay=false"))
        // A play reported meanwhile is paused again; intent is untouched.
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
        #expect(controller.isHeld)
        controller.endHold(.background, resume: true)
        #expect(!controller.isHeld)
        #expect(controller.startsPlaying)
    }

    @Test("Backgrounded while the web page loads: ready keeps it paused, return resumes")
    func backgroundHoldDuringWebLoad() {
        let controller = StreamPlayerController()
        // The page is built meant to play, then the app leaves.
        #expect(controller.beginWebEngineLoad())
        controller.beginHold(.background)
        // Twitch autoplays: undone, and it isn't the user's intent changing.
        controller.noteEngineReady(paused: false)
        #expect(controller.isSettlingWebStartup)
        controller.noteWebState(paused: false)
        controller.noteDidPlay()
        #expect(controller.wantsPlayback)
        // Back in the foreground: the hold resumes it.
        controller.endHold(.background, resume: true)
        #expect(controller.startsPlaying)
        #expect(!controller.isSettlingWebStartup)
    }

    @Test("A user pause isn't undone by the background hold's release")
    func backgroundHoldKeepsUserPause() {
        let controller = StreamPlayerController()
        controller.togglePlay()
        #expect(!PlaybackCenter.resumesOnRelease(controller))
        controller.beginHold(.background)
        controller.endHold(.background, resume: false)
        #expect(!controller.startsPlaying)
    }

    @Test("Start-muted survives a rebuild and reaches the web page URL")
    func startsMutedThroughRebuild() {
        let controller = StreamPlayerController()
        controller.startsMuted = true
        controller.reset()
        #expect(controller.isMuted)
        let url = TwitchWebPlayer.playerURL("x", autoplay: controller.startsPlaying, muted: controller.startsMuted)
        #expect(url.absoluteString.contains("muted=true"))
        #expect(url.absoluteString.contains("autoplay=true"))
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
