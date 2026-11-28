#if os(iOS)
import SwiftUI
import UIKit
import AVKit
import AVFoundation
import WebKit

/// State + commands for whichever player is mounted (web or native). The
/// header's overlay talks only to this.
@MainActor
@Observable
final class StreamPlayerController {
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            onPausedChange?()
        }
    }
    /// `isPaused` changed — `PlaybackCenter` keeps Now Playing and its
    /// long-pause unload in step.
    @ObservationIgnored var onPausedChange: (() -> Void)?
    var isMuted = false
    /// Independent loudness (`0.0...1.0`) for native `AVPlayer` slots.
    /// Re-applied on every player start, warm swap, and media-services reset.
    var volume: Float = 1.0
    /// True while this stream is actually producing audible sound (used for
    /// audio-session exclusivity and background-hold eligibility).
    var isEffectivelyAudible: Bool {
        !isMuted && volume > 0 && !isPaused && !isHeld
    }
    /// The native player is waiting on the network: starting up, stalled
    /// mid-stream, or between tries after a failure.
    var isBuffering = false
    var canPictureInPicture = false
    /// The stream is in the system picture-in-picture window. The chat
    /// header gives its video area back to chat, and the mini player
    /// stays out of the way, while this is true.
    ///
    /// Global — every reader re-renders on each PiP transition. Per-page
    /// views (one per pre-mounted chat page) read
    /// `PlaybackCenter.pictureInPictureFlag(for:)` instead, which only
    /// changes for the page whose stream is in PiP.
    private(set) var isPictureInPictureActive = false {
        didSet {
            guard isPictureInPictureActive != oldValue else { return }
            onPictureInPictureActiveChange?()
        }
    }
    /// `isPictureInPictureActive` changed — `PlaybackCenter` keeps its
    /// per-channel PiP flags in step.
    @ObservationIgnored var onPictureInPictureActiveChange: (() -> Void)?
    /// Flips once real frames are playing.
    var hasStarted = false
    /// The native player couldn't get a playlist / failed to play — the
    /// header falls back to the web player for this channel.
    var nativeFailed = false
    /// The next engine starts muted (Wi-Fi autoplay, or a rebuild of a
    /// muted stream). Set by `PlaybackCenter` before it builds an engine,
    /// and mirrored into `isMuted` by `reset()` so the requested mute holds
    /// while the engine loads — and through a fallback rebuild that happens
    /// before it ever played.
    @ObservationIgnored var startsMuted = false

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var avPlayer: AVPlayer?
    @ObservationIgnored var pictureInPicture: AVPictureInPictureController? {
        didSet { refreshAutomaticPictureInPicture() }
    }
    @ObservationIgnored weak var hostView: UIView?

    @ObservationIgnored var onTap: (() -> Void)?
    @ObservationIgnored var onSwipeDown: (() -> Void)?
    /// Native engine failed — `PlaybackCenter` rebuilds on the web engine.
    @ObservationIgnored var onNativeFailure: (() -> Void)?
    /// Whether a failing native engine has nothing to fall back to right
    /// now (audio-only with the app in the background, where the web
    /// player can't play). It then keeps trying instead of giving up.
    @ObservationIgnored var staysOnNativeEngine: (() -> Bool)?
    /// The native engine saw the broadcast end — its playlist closed, or
    /// Twitch says the channel is offline. `PlaybackCenter` stops.
    @ObservationIgnored var onStreamEnded: (() -> Void)?
    /// Play was asked for with no engine to play it: `PlaybackCenter`
    /// unloads one after a long pause, and builds it again on this.
    @ObservationIgnored var onResumeRequested: (() -> Void)?
    /// Mute, volume, or playback audibility changed. `userInitiatedUnmute` is
    /// true only when the user explicitly unmuted or raised volume above 0
    /// (exiting Solo / Mute All); programmatic updates pass false.
    @ObservationIgnored var onAudioStateChange: ((_ userInitiatedUnmute: Bool) -> Void)?
    /// Called by `NativePlayer.Coordinator` right before creating an `AVPlayer`
    /// so `PlaybackCenter` configures `PlaybackAudioSession` through the single
    /// aggregate arbiter.
    @ObservationIgnored var onPrepareAudioSession: (() async -> Void)?
    /// Audio-only is playing the full stream because Twitch offered no
    /// audio rendition — the video nobody sees is kept as small as it goes
    /// (`applyQualityLimits`).
    @ObservationIgnored var playsVideoHidden = false
    /// PiP's "return to app" button — go back to this stream's chat.
    @ObservationIgnored var onRestoreFromPictureInPicture: (() -> Void)?
    /// PiP was closed with its × (not restored) — nothing left on screen.
    @ObservationIgnored var onPictureInPictureClosed: (() -> Void)?
    @ObservationIgnored private var isRestoringFromPictureInPicture = false

    /// What currently asks the stream to stay paused and will hand it back
    /// (`PlaybackCenter.holdPlayback(_:)`): a clip playing over it, or the
    /// app in the background without PiP. One mechanism for both. Unlike a
    /// one-shot pause a hold outlives engine loading: an engine built or
    /// finishing its load while held starts paused (`startsPlaying`), and a
    /// play reported while held is paused again (`noteDidPlay`). Not
    /// cleared by `reset()`, so it survives a same-channel rebuild.
    @ObservationIgnored private(set) var holds: Set<PlaybackHoldReason> = []
    /// Any hold is out.
    var isHeld: Bool { !holds.isEmpty }

    /// What the user wants the stream doing: true = playing, false = they
    /// paused it. Explicit intent, separate from `isPaused` (the engine's
    /// report), because a stream buffering before its first frame isn't
    /// "paused" yet — a user pause in that window would otherwise look like
    /// "about to autoplay" to `PlaybackCenter.holdPlayback`.
    ///
    /// Set by `togglePlay` (the user's play/pause control), and back to
    /// true whenever the engine reports playing (`noteDidPlay`), so a
    /// resume from outside our controls (native fullscreen, PiP window,
    /// lock screen) counts too. That's sound because no engine starts
    /// playing on its own: each starts paused unless `startsPlaying`. Our
    /// own `pause()`/`resume()` (holds) never touch it. Reset per stream by
    /// `PlaybackCenter`. Not observed: nothing renders from it, so changing
    /// it invalidates no view.
    @ObservationIgnored var wantsPlayback = true

    /// Whether an engine starting now should start playing: the user wants
    /// it (`wantsPlayback`) and no hold of any kind is out. The native engine checks
    /// it when its load finishes; the web engine bakes it into the page's
    /// `autoplay` parameter, and `noteEngineReady` applies it again, either
    /// way, if it changed while the page loaded.
    var startsPlaying: Bool { wantsPlayback && !isHeld }

    /// A web page is loading and hasn't posted its first state yet
    /// (`beginWebEngineLoad` → `noteEngineReady`). Its bridge may not exist
    /// yet, so a play/pause sent now would be lost: until ready, those
    /// commands only record intent, and `noteEngineReady` applies it.
    @ObservationIgnored private(set) var isAwaitingWebEngine = false
    /// The loading page was built with `autoplay=true`.
    @ObservationIgnored private var webEngineAutoplays = false
    /// `noteEngineReady` paused a page that was built to autoplay but whose
    /// intent turned to paused while it loaded. Until that pause has
    /// visibly landed, play reports are the page's own autoplay, not the
    /// user: they're paused again and leave intent alone. Ends at the first
    /// paused report after such a play (`noteWebState`), when the user or a
    /// hold release asks to play (`togglePlay`, `resume`), or after
    /// `webStartupSettleWindow` at the latest. The time bound matters when
    /// the page's first report is already paused: Twitch may never autoplay
    /// at all, and without it a later genuine play (PiP window, lock
    /// screen) would be swallowed forever.
    var isSettlingWebStartup: Bool {
        guard let deadline = webStartupSettleDeadline else { return false }
        return ContinuousClock.now < deadline
    }
    /// How long a page's startup autoplay can still arrive after it's ready.
    @ObservationIgnored var webStartupSettleWindow: Duration = .seconds(5)
    @ObservationIgnored private var webStartupSettleDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var didSuppressStartupPlay = false

    /// A web page is about to be built. Returns its `autoplay` — the
    /// current `startsPlaying` — and holds play/pause commands back until
    /// the page reports ready.
    func beginWebEngineLoad() -> Bool {
        isAwaitingWebEngine = true
        webStartupSettleDeadline = nil
        didSuppressStartupPlay = false
        webEngineAutoplays = startsPlaying
        return webEngineAutoplays
    }

    /// The engine reports real frames playing. Engines start playing only
    /// when `startsPlaying`, so every play report is the user's doing — our
    /// control, or one outside it (native fullscreen, PiP window, lock
    /// screen) — and restores intent. Except while held, or while a web
    /// page's startup autoplay is being undone (`isSettlingWebStartup`):
    /// then it's paused again and intent is left alone.
    func noteDidPlay() {
        update(\.hasStarted, to: true)
        // A hold wins over settling: its pause is PiP-aware, so a web video
        // WebKit is handing to picture in picture as the app leaves isn't
        // stopped before `pipStart` arrives and releases the background hold.
        if isHeld {
            if isSettlingWebStartup { didSuppressStartupPlay = true }
            pauseForHold()
        } else if isSettlingWebStartup {
            didSuppressStartupPlay = true
            pause()
        } else {
            wantsPlayback = true
        }
    }

    /// The web page's first state report: it now takes commands. Applies
    /// the CURRENT intent both ways, since play/pause made while it loaded
    /// were only recorded. Meant to play: start it if it isn't (a hold
    /// released, or play pressed, while it loaded). Not meant to play:
    /// pause it — and if it was built to autoplay, its startup play
    /// reports are that autoplay, not intent (`isSettlingWebStartup`).
    func noteEngineReady(paused: Bool) {
        isAwaitingWebEngine = false
        // Apply any mute requested while the web page was still loading
        // (e.g. Solo / Mute All or a mute tap before first state report).
        if isMuted != webPageReportedMuted {
            runCall("setMuted", arguments: isMuted ? "true" : "false")
        }
        if startsPlaying {
            if paused { resume() }
        } else {
            // Startup suppression is only for a USER pause. A hold alone
            // re-pauses play reports itself (PiP-aware) for as long as it's
            // out; once it's released — including by `pipStart` handing the
            // video to PiP — play reports must count as intent again.
            if webEngineAutoplays, !wantsPlayback {
                webStartupSettleDeadline = ContinuousClock.now + webStartupSettleWindow
            }
            // Held: the hold's pause is PiP-aware, so a video WebKit is
            // handing to picture in picture as the app leaves isn't stopped.
            if isHeld { pauseForHold() } else { pause() }
        }
    }

    /// Last mute state reported by the web page so `noteEngineReady` knows
    /// whether a mute requested while loading still needs to be pushed.
    @ObservationIgnored var webPageReportedMuted = false

    /// Every web state report, after `noteEngineReady` and before
    /// `noteDidPlay`. A paused report following a suppressed startup play
    /// means the startup pause has landed: from here every play report
    /// counts as intent again.
    func noteWebState(paused: Bool) {
        if paused, isSettlingWebStartup, didSuppressStartupPlay {
            webStartupSettleDeadline = nil
        }
    }

    func beginHold(_ reason: PlaybackHoldReason) {
        holds.insert(reason)
        pauseForHold()
    }

    /// Pauses for the holds that are out. With a `.background` hold on the
    /// web player the page pauses only if the video isn't in (or entering)
    /// picture in picture: `isPictureInPictureActive` comes from the page's
    /// async `pipStart` message and can lag the app leaving, and an
    /// unconditional pause would stop the video WebKit is handing to PiP.
    /// (`PlaybackCenter` drops the hold once `pipStart` arrives.)
    func pauseForHold() {
        guard avPlayer == nil, holds.contains(.background) else { return pause() }
        // A loading web page gets it from `noteEngineReady`.
        if isAwaitingWebEngine { return }
        run("pauseUnlessPictureInPicture")
    }

    /// `resume`: this holder paused a stream that was playing (or about
    /// to). It resumes only once nothing else holds the stream and the user
    /// still wants it (`startsPlaying`); another hold still out keeps it
    /// paused, and the last release decides (a hold taken over another
    /// inherits its resume — see `PlaybackCenter.holdPlayback`). If the engine is still
    /// loading there's nothing to resume yet — the load applies
    /// `startsPlaying` itself.
    func endHold(_ reason: PlaybackHoldReason, resume: Bool) {
        holds.remove(reason)
        if resume, startsPlaying { self.resume() }
    }

    /// Every hold lapses without resuming (the stream stopped or changed).
    func endAllHolds() {
        holds.removeAll()
    }

    func pictureInPictureDidStart() {
        isPictureInPictureActive = true
    }

    func pictureInPictureWillRestore() {
        isRestoringFromPictureInPicture = true
        onRestoreFromPictureInPicture?()
    }

    /// PiP ended but whether the user returned or closed is unknown (web
    /// player, video already paused): clear the state, take no action.
    func pictureInPictureEndedAmbiguously() {
        isPictureInPictureActive = false
        isRestoringFromPictureInPicture = false
    }

    func pictureInPictureDidStop() {
        isPictureInPictureActive = false
        if !isRestoringFromPictureInPicture { onPictureInPictureClosed?() }
        isRestoringFromPictureInPicture = false
    }

    var isNative: Bool { avPlayer != nil }

    func reset() {
        isAwaitingWebEngine = false
        webStartupSettleDeadline = nil
        // Until the new engine reports, show the intent its load applies,
        // so the play/pause control matches what a tap flips (`togglePlay`).
        update(\.isPaused, to: !wantsPlayback)
        update(\.isMuted, to: startsMuted)
        update(\.isBuffering, to: false)
        update(\.canPictureInPicture, to: false)
        update(\.isPictureInPictureActive, to: false)
        update(\.hasStarted, to: false)
        playsVideoHidden = false
    }

    /// Writes `value` only when it differs. Observation notifies on every
    /// set, equal or not, and the engines report state far more often than
    /// it changes (the web bridge re-sends every field on any change; AVPlayer
    /// re-reports `.playing` after each stall) — each redundant write
    /// re-rendered the stream header and the mini player.
    func update<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<StreamPlayerController, Value>,
        to value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
        // Mute / pause decide whether leaving the app may open PiP.
        refreshAutomaticPictureInPicture()
    }

    /// The user's play/pause control — records their intent
    /// (`wantsPlayback`) as well as acting on it.
    func togglePlay() {
        guard let player = avPlayer else {
            if isAwaitingWebEngine || webView == nil {
                // An engine still loading: a web page not ready yet, or the
                // native playlist still resolving (no AVPlayer, no page).
                // Nothing reports state yet, so flip the intent and show
                // it; the load applies it (`noteEngineReady`, or the native
                // load's `startsPlaying` check).
                wantsPlayback.toggle()
                if wantsPlayback { webStartupSettleDeadline = nil }
                update(\.isPaused, to: !wantsPlayback)
                // No engine at all (unloaded after a long pause): the
                // owner builds it again. One that's loading ignores this.
                if wantsPlayback { onResumeRequested?() }
                return
            }
            // Web, ready: the control showed "play" when the page reported
            // paused, "pause" otherwise.
            wantsPlayback = isPaused
            if wantsPlayback { webStartupSettleDeadline = nil }
            return run("togglePlay")
        }
        if player.timeControlStatus == .paused {
            wantsPlayback = true
            resume()
        } else {
            // Includes `.waitingToPlayAtSpecifiedRate`: buffering before
            // the first frame, which is still a pause the user asked for.
            wantsPlayback = false
            player.pause()
        }
    }

    func pause() {
        guard let player = avPlayer else {
            // A loading web page gets it from `noteEngineReady`.
            if isAwaitingWebEngine { return }
            return run("pause")
        }
        player.pause()
    }

    func resume() {
        guard let player = avPlayer else {
            webStartupSettleDeadline = nil
            // A loading web page gets it from `noteEngineReady`.
            if isAwaitingWebEngine { return }
            return run("play")
        }
        // Live: resume at the live edge, not where we paused — less the
        // active profile's offset (`PlaybackLatencyProfile.current.liveOffset`).
        // At the very end of the seekable range nothing is buffered yet, and
        // the player stalls the moment it starts.
        let latency = PlaybackLatencyProfile.current
        if let item = player.currentItem,
           item.status == .readyToPlay,
           let range = item.seekableTimeRanges.last?.timeRangeValue,
           let target = Self.liveResumeTarget(for: range, offset: latency.liveOffset) {
            player.seek(to: target)
        }
        player.play()
    }

    /// Applies `profile` to an active native `AVPlayerItem` immediately. When
    /// switching into Low Latency while already playing further behind live
    /// than the new target, nudges the playhead forward toward the live edge.
    func applyLatencyProfile(_ profile: PlaybackLatencyProfile = .current) {
        guard let player = avPlayer, let item = player.currentItem else { return }
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.configuredTimeOffsetFromLive = profile.liveOffset
        item.preferredForwardBufferDuration = profile.forwardBufferDuration

        guard profile.isLowLatency,
              player.timeControlStatus == .playing,
              item.status == .readyToPlay,
              let range = item.seekableTimeRanges.last?.timeRangeValue,
              let target = Self.liveResumeTarget(for: range, offset: profile.liveOffset)
        else { return }

        let current = item.currentTime()
        let edge = CMTimeRangeGetEnd(range)
        if current.isNumeric, edge.isNumeric {
            let currentLag = CMTimeGetSeconds(CMTimeSubtract(edge, current))
            if currentLag > profile.liveOffsetSeconds + 1.5 {
                player.seek(to: target)
            }
        }
    }

    /// Computes the live-edge seek target for `range`, or `nil` when `range`
    /// cannot yield a finite numeric `CMTime`.
    ///
    /// Live HLS items can report invalid, empty, indefinite, or infinite
    /// seekable ranges (during stalls, playlist reloads, or discontinuities).
    /// Passing a non-numeric `CMTime` to `AVPlayer.seek(to:)` throws
    /// `NSInvalidArgumentException`, so `resume()` skips the seek and lets
    /// `AVPlayer.play()` resume via `configuredTimeOffsetFromLive`.
    static func liveResumeTarget(for range: CMTimeRange, offset: CMTime = liveOffset) -> CMTime? {
        guard range.isValid, !range.isEmpty,
              range.start.isNumeric, range.duration.isNumeric,
              offset.isNumeric
        else { return nil }
        let liveEdge = CMTimeRangeGetEnd(range)
        guard liveEdge.isNumeric else { return nil }
        let offsetTarget = CMTimeSubtract(liveEdge, offset)
        let target = offsetTarget.isNumeric
            ? CMTimeMaximum(range.start, offsetTarget)
            : range.start
        return target.isNumeric ? target : nil
    }

    /// Default live-edge offset for the standard latency profile
    /// (`AVPlayerItem.configuredTimeOffsetFromLive`): about three of
    /// Twitch's two-second segments, enough buffer to play without
    /// stalling.
    static let liveOffset = PlaybackLatencyProfile.standard.liveOffset

    /// Lock screen / Control Center play and pause (`StreamNowPlaying`):
    /// the user's intent, exactly like `togglePlay`.
    func remotePlay() {
        if isPaused { togglePlay() }
    }

    func remotePause() {
        guard isPaused else { return togglePlay() }
        // Already paused, but possibly by a hold rather than the user:
        // record the intent, or releasing the hold would resume it.
        if wantsPlayback { wantsPlayback = false }
    }

    func toggleMute() {
        setMuted(!isMuted, programmatic: false)
    }

    /// Sets mute explicitly on either engine (or while still loading).
    /// `programmatic: true` is used by Solo, Mute All, and new-slot init so
    /// programmatic mute updates never accidentally cancel Solo / Mute All.
    func setMuted(_ muted: Bool, programmatic: Bool = false) {
        let wasMuted = isMuted
        let userUnmuted = !programmatic && wasMuted && !muted
        guard let player = avPlayer else {
            startsMuted = muted
            update(\.isMuted, to: muted)
            if webView != nil, !isAwaitingWebEngine {
                runCall("setMuted", arguments: muted ? "true" : "false")
            }
            if wasMuted != muted || userUnmuted {
                onAudioStateChange?(userUnmuted)
            }
            return
        }
        if player.isMuted != muted {
            player.isMuted = muted
        }
        update(\.isMuted, to: player.isMuted)
        if wasMuted != player.isMuted || userUnmuted {
            onAudioStateChange?(userUnmuted)
        }
    }

    /// Sets per-slot loudness (`0.0...1.0`) for native `AVPlayer` slots.
    /// Only transitioning from muted or 0-volume to >0 counts as a user unmute
    /// (so lowering volume from 80% → 50% never exits Solo / Mute All), and
    /// `onAudioStateChange` only fires when audibility crosses the 0 boundary.
    func setVolume(_ newVolume: Float, programmatic: Bool = false) {
        let clamped = min(max(newVolume, 0), 1)
        let wasZeroOrMuted = isMuted || volume == 0
        let wasAudible = isEffectivelyAudible
        update(\.volume, to: clamped)
        avPlayer?.volume = clamped
        if clamped > 0, isMuted {
            setMuted(false, programmatic: programmatic)
            return
        }
        let userUnmuted = !programmatic && wasZeroOrMuted && clamped > 0
        let nowAudible = isEffectivelyAudible
        if userUnmuted || wasAudible != nowAudible {
            onAudioStateChange?(userUnmuted)
        }
    }

    func togglePictureInPicture() {
        guard avPlayer != nil else { return run("pip") }
        guard let pip = pictureInPicture else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    func enterFullscreen() {
        guard let player = avPlayer else { return run("fullscreen") }
        guard var presenter = hostView?.window?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        let fullscreen = AVPlayerViewController()
        fullscreen.player = player
        fullscreen.modalPresentationStyle = .fullScreen
        // PiP started from the fullscreen player reports through its own
        // delegate — forward it so PiP state, return-to-chat and close all
        // behave the same as PiP from the inline player.
        let forwarder = FullscreenPictureInPictureForwarder(controller: self)
        fullscreenPictureInPictureForwarder = forwarder
        fullscreen.delegate = forwarder
        presenter.present(fullscreen, animated: true)
    }

    /// Kept alive while a fullscreen player may be presented
    /// (`AVPlayerViewController.delegate` is weak).
    @ObservationIgnored private var fullscreenPictureInPictureForwarder: FullscreenPictureInPictureForwarder?

    /// Latest requested cap — read when a pending native load finishes, so
    /// a change made while the playlist was loading isn't lost.
    @ObservationIgnored var preferredQuality: PlayerQuality = .auto

    func applyQuality(_ quality: PlayerQuality) {
        preferredQuality = quality
        if let item = avPlayer?.currentItem { applyQualityLimits(to: item) }
    }

    /// Everything that limits the variant AVPlayer may pick for `item`:
    /// the user's cap, cellular, a power-saving or hot device, and video
    /// nobody sees (`PlaybackLimits`). Applied to each new item, and again
    /// through `applyQuality` when any of those change.
    func applyQualityLimits(to item: AVPlayerItem, videoIsHidden: Bool? = nil) {
        let limits = PlaybackLimits.resolve(
            quality: preferredQuality,
            deviceIsConstrained: PlaybackLimits.deviceIsConstrained,
            videoIsHidden: videoIsHidden ?? playsVideoHidden
        )
        item.preferredMaximumResolution = limits.maximumResolution
        item.preferredMaximumResolutionForExpensiveNetworks = limits.maximumResolutionOnExpensiveNetworks
        item.preferredPeakBitRate = limits.peakBitRate
    }

    private func run(_ command: String) {
        runCall(command, arguments: "")
    }

    /// Builds the JS invocation evaluated on `webView`. Exposed `internal` for
    /// unit-test verification so invalid double-invocations cannot regress.
    static func webCommandJS(_ command: String, arguments: String = "") -> String {
        "window.chattrPlayer && window.chattrPlayer.\(command)(\(arguments))"
    }

    private func runCall(_ command: String, arguments: String) {
        webView?.evaluateJavaScript(Self.webCommandJS(command, arguments: arguments))
    }
}
#endif
