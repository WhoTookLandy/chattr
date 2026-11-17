import SwiftUI
import Core
#if os(iOS)
import UIKit
import AVKit
import AVFoundation
import Combine
import WebKit
#endif

// MARK: - Settings

/// Video preferences (Settings → Video).
enum PlayerSettings {
    /// Play streams in AVPlayer instead of Twitch's web player. Off by
    /// default: it relies on Twitch's private web playback endpoint (see
    /// `TwitchHLS`), which isn't a supported third-party API and can break.
    static let nativePlayerKey = "chattr.player.native"
    /// Native player only — caps the HLS variant AVPlayer may pick.
    static let maxQualityKey = "chattr.player.maxQuality"
    /// Listen-only mode: no video surface, just chat + stream audio. The
    /// native player switches to Twitch's audio-only rendition (saves data).
    static let audioOnlyKey = "chattr.player.audioOnly"
    /// Leaving a chat with video playing hands it to the system
    /// picture-in-picture window instead of the in-app mini player. Off by
    /// default; the mini player stays as the fallback when PiP can't start.
    static let systemPictureInPictureKey = "chattr.player.systemPiPOnLeave"
    /// Kill switch for the native path. Set, nothing resolves a playlist
    /// through `TwitchHLS`: every stream plays in Twitch's web player and
    /// audio-only (which needs the native engine) isn't offered. No
    /// Settings row writes it — it's for turning the unofficial endpoint
    /// off without shipping a build (a launch argument, managed
    /// configuration, or a remote flag written to this key).
    static let nativePlaybackDisabledKey = "chattr.player.nativeDisabled"

    /// The one read of the kill switch. `PlaybackCenter.play` decides the
    /// engine with it; the views use it only to stop offering audio-only.
    static var isNativePlaybackEnabled: Bool {
        !UserDefaults.standard.bool(forKey: nativePlaybackDisabledKey)
    }
}

/// Resolution cap for the native player. `auto` lets AVPlayer adapt freely.
enum PlayerQuality: String, CaseIterable, Identifiable {
    case auto, p1080, p720, p480, p360

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        case .p360: "360p"
        }
    }

    /// `.zero` = no cap (AVFoundation's sentinel).
    var maximumResolution: CGSize {
        switch self {
        case .auto: .zero
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p720: CGSize(width: 1280, height: 720)
        case .p480: CGSize(width: 854, height: 480)
        case .p360: CGSize(width: 640, height: 360)
        }
    }
}

#if os(iOS)

// MARK: - Controller

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
        // offset the item keeps from it (`liveOffset`). At the very end of
        // the seekable range nothing is buffered yet, and the player
        // stalls the moment it starts.
        if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue {
            let liveEdge = CMTimeRangeGetEnd(range)
            player.seek(to: CMTimeMaximum(range.start, CMTimeSubtract(liveEdge, Self.liveOffset)))
        }
        player.play()
    }

    /// How far behind the live edge the native player sits
    /// (`AVPlayerItem.configuredTimeOffsetFromLive`): about three of
    /// Twitch's two-second segments, enough buffer to play without
    /// stalling.
    static let liveOffset = CMTime(seconds: 6, preferredTimescale: 600)

    /// Lock screen / Control Center play and pause (`StreamNowPlaying`):
    /// the user's intent, exactly like `togglePlay`.
    func remotePlay() {
        if isPaused { togglePlay() }
    }

    func remotePause() {
        if !isPaused { togglePlay() }
    }

    func toggleMute() {
        guard let player = avPlayer else {
            guard webView != nil else {
                // Native playlist still resolving: change the mute the
                // player will start with.
                startsMuted.toggle()
                update(\.isMuted, to: startsMuted)
                return
            }
            return run("toggleMute")
        }
        player.isMuted.toggle()
        update(\.isMuted, to: player.isMuted)
        // Muted mixes with other audio; with sound it's the only one.
        PlaybackAudioSession.shared.setMuted(player.isMuted)
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
    func applyQualityLimits(to item: AVPlayerItem) {
        let limits = PlaybackLimits.resolve(
            quality: preferredQuality,
            deviceIsConstrained: PlaybackLimits.deviceIsConstrained,
            videoIsHidden: playsVideoHidden
        )
        item.preferredMaximumResolution = limits.maximumResolution
        item.preferredMaximumResolutionForExpensiveNetworks = limits.maximumResolutionOnExpensiveNetworks
        item.preferredPeakBitRate = limits.peakBitRate
    }

    private func run(_ command: String) {
        webView?.evaluateJavaScript("window.chattrPlayer && window.chattrPlayer.\(command)()")
    }
}

// MARK: - Playlist

/// Resolves a channel's live HLS playlist the way twitch.tv's own web
/// player does: a playback access token from Twitch's GQL endpoint (public
/// web client ID), then the usher playlist signed with it.
///
/// Not an official third-party API — Twitch can change or block it at any
/// time, which is why the native player is opt-in, falls back to the web
/// player when it keeps failing, and can be switched off altogether
/// (`PlayerSettings.isNativePlaybackEnabled`). The native engine reaches it
/// only through `StreamPlaylistResolving`.
enum TwitchHLS {
    /// The resolver the native engine uses unless it's handed another.
    struct Resolver: StreamPlaylistResolving {
        func playlist(login: String, audioOnly: Bool) async throws -> StreamPlaylist {
            try await TwitchHLS.playlist(login: login, audioOnly: audioOnly)
        }
    }

    private static let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    private static let query = """
    query PlaybackAccessToken($login: String!) {
      streamPlaybackAccessToken(channelName: $login, params: {platform: "ios", playerBackend: "mediaplayer", playerType: "site"}) {
        value
        signature
      }
    }
    """

    private struct Response: Decodable {
        struct DataField: Decodable {
            struct Token: Decodable {
                let value: String
                let signature: String
            }
            let streamPlaybackAccessToken: Token?
        }
        let data: DataField?
    }

    static func playlist(login: String, audioOnly: Bool = false) async throws -> StreamPlaylist {
        var request = URLRequest(url: Endpoints.TwitchPlayer.playbackAccessToken)
        request.httpMethod = "POST"
        request.setValue(webClientID, forHTTPHeaderField: "Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": query,
            "variables": ["login": login],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let fields = try JSONDecoder().decode(Response.self, from: data).data
        else { throw StreamPlaylistError.unavailable }
        // Answered, but with no token: a channel that doesn't exist, or
        // one Twitch won't play for this client.
        guard let token = fields.streamPlaybackAccessToken else { throw StreamPlaylistError.forbidden }

        guard let playlistURL = Endpoints.TwitchPlayer.livePlaylist(login: login),
              var components = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false)
        else { throw StreamPlaylistError.unavailable }
        components.queryItems = [
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "token", value: token.value),
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "fast_bread", value: "true"),
            URLQueryItem(name: "player_backend", value: "mediaplayer"),
            URLQueryItem(name: "playlist_include_framerate", value: "true"),
            URLQueryItem(name: "supported_codecs", value: "avc1"),
            URLQueryItem(name: "p", value: String(Int.random(in: 1_000_000...9_999_999))),
        ]
        guard let url = components.url else { throw StreamPlaylistError.unavailable }
        guard audioOnly else { return StreamPlaylist(url: url, isAudioOnlyRendition: false) }
        // Audio-only: pick the `audio_only` variant out of the master
        // playlist. If Twitch didn't offer one, the full stream still plays.
        if let variant = try await audioOnlyVariant(in: url) {
            return StreamPlaylist(url: variant, isAudioOnlyRendition: true)
        }
        return StreamPlaylist(url: url, isAudioOnlyRendition: false)
    }

    /// nil when the master playlist lists no audio-only variant, or
    /// couldn't be read at all (the player then loads it itself). Throws
    /// only for what Twitch's status says outright: offline, or refused.
    private static func audioOnlyVariant(in master: URL) async throws -> URL? {
        guard let (data, response) = try? await URLSession.shared.data(from: master) else { return nil }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 404: throw StreamPlaylistError.offline
        case 401, 403: throw StreamPlaylistError.forbidden
        default: break
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: master)
    }
}

// MARK: - Native view

/// AVPlayer-backed player pieces, assembled by `NativeStreamEngine`. Taps
/// toggle the header chrome and a swipe down hides the video, the same
/// contract as the web player.
enum NativePlayer {
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: StreamPlayerController
        var loadedKey: String?

        static func key(_ login: String, _ audioOnly: Bool) -> String {
            "\(login)|\(audioOnly)"
        }
        /// How long a stalled player gets to recover by itself before the
        /// playlist is resolved again.
        static let stallPatience: Duration = .seconds(10)

        private let resolver: any StreamPlaylistResolving
        private var login = ""
        private var audioOnly = false
        private weak var playerView: PlayerLayerView?
        /// Between `load` and `teardown`.
        private var isLoaded = false

        private var loadTask: Task<Void, Never>?
        private var stallTask: Task<Void, Never>?
        private var recovery = PlaybackRecovery()
        /// Bumped for each item and each failure, so a late report from an
        /// item that was replaced (or already counted as failed) is dropped.
        private var itemGeneration = 0
        /// When the player last went to paused; nil while it isn't.
        private var pausedAt: ContinuousClock.Instant?
        private var resumesAfterInterruption = false

        /// Audio session and device state, for the engine's whole life.
        private var subscriptions: Set<AnyCancellable> = []
        private var playerSubscriptions: Set<AnyCancellable> = []
        private var itemSubscriptions: Set<AnyCancellable> = []

        init(controller: StreamPlayerController, resolver: any StreamPlaylistResolving = TwitchHLS.Resolver()) {
            self.controller = controller
            self.resolver = resolver
        }

        @objc func tapped() { controller.onTap?() }
        @objc func swipedDown() { controller.onSwipeDown?() }

        func load(login: String, audioOnly: Bool, quality: PlayerQuality, into view: PlayerLayerView) {
            teardown()
            loadedKey = Self.key(login, audioOnly)
            self.login = login
            self.audioOnly = audioOnly
            playerView = view
            isLoaded = true
            recovery = PlaybackRecovery()
            controller.preferredQuality = quality
            controller.reset()
            observeSessionAndDevice()
            resolveAndStart(after: nil)
        }

        // MARK: Resolve, start, retry

        /// Resolves the playlist (after `delay`, for a retry) and starts
        /// it — on the player that's already there, if one is.
        private func resolveAndStart(after delay: Duration?) {
            loadTask?.cancel()
            // A report that was already on its way to the main queue when
            // the engine was torn down must not start it again.
            guard isLoaded else { return }
            let resolver = self.resolver
            let login = self.login
            let audioOnly = self.audioOnly
            loadTask = Task { [weak self] in
                if let delay {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                }
                do {
                    let playlist = try await resolver.playlist(login: login, audioOnly: audioOnly)
                    guard !Task.isCancelled, let self else { return }
                    // Before the player exists: one started first brings
                    // the session up in whatever category it was left in,
                    // and a muted autoplay would cut the user's music.
                    await PlaybackAudioSession.shared.activate(muted: self.controller.isMuted)
                    guard !Task.isCancelled else { return }
                    self.start(playlist)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.playbackFailed(error)
                }
            }
        }

        private func start(_ playlist: StreamPlaylist) {
            guard isLoaded, let view = playerView else { return }
            controller.playsVideoHidden = audioOnly && !playlist.isAudioOnlyRendition

            let item = AVPlayerItem(url: playlist.url)
            // Hold a fixed distance behind the live edge. Left alone, each
            // stall adds its length to the delay for good, and chat runs
            // further and further ahead of the video.
            item.automaticallyPreservesTimeOffsetFromLive = true
            item.configuredTimeOffsetFromLive = StreamPlayerController.liveOffset
            controller.applyQualityLimits(to: item)
            observeItem(item)

            let player: AVPlayer
            if let existing = controller.avPlayer {
                // A retry: the same player (and PiP controller), a fresh
                // playlist.
                player = existing
                player.replaceCurrentItem(with: item)
            } else {
                player = AVPlayer(playerItem: item)
                // `isMuted` is the mute asked for: `startsMuted` on a first
                // start (`reset()` mirrors it, `toggleMute` keeps both in
                // step while loading), the stream's own after a rebuild.
                player.isMuted = controller.isMuted
                view.playerLayer.player = player
                controller.avPlayer = player

                if AVPictureInPictureController.isPictureInPictureSupported(),
                   let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
                    pip.canStartPictureInPictureAutomaticallyFromInline = true
                    pip.delegate = self
                    controller.pictureInPicture = pip
                    controller.update(\.canPictureInPicture, to: true)
                }
                observePlayer(player)
            }

            // Held (a clip over the stream, or the app left without PiP
            // while the playlist resolved): stay paused until the holder
            // releases — `endHold(_:resume:)` starts it then. Paused by the
            // user while the playlist loaded: leave it paused.
            if controller.startsPlaying {
                player.play()
            } else {
                controller.update(\.isPaused, to: true)
                controller.update(\.isBuffering, to: false)
            }
        }

        private func observePlayer(_ player: AVPlayer) {
            player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self else { return }
                    self.controller.update(\.isPaused, to: status == .paused)
                    self.controller.update(\.isBuffering, to: status == .waitingToPlayAtSpecifiedRate)
                    if status == .paused {
                        if self.pausedAt == nil { self.pausedAt = ContinuousClock.now }
                    } else {
                        self.pausedAt = nil
                    }
                    if status == .playing {
                        self.stallTask?.cancel()
                        self.stallTask = nil
                        self.controller.noteDidPlay()
                    }
                }
                .store(in: &playerSubscriptions)

            // Every way the mute changes lands here — our control, and the
            // fullscreen player's own.
            player.publisher(for: \.isMuted)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // The player's value now, not the one delivered: two
                    // quick toggles would otherwise replay the first.
                    guard let self, let player = self.controller.avPlayer else { return }
                    self.controller.update(\.isMuted, to: player.isMuted)
                    PlaybackAudioSession.shared.setMuted(player.isMuted)
                }
                .store(in: &playerSubscriptions)
        }

        private func observeItem(_ item: AVPlayerItem) {
            itemSubscriptions.removeAll()
            itemGeneration += 1
            let generation = itemGeneration
            let notifications = NotificationCenter.default

            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak item] status in
                    guard let self, generation == self.itemGeneration, status == .failed else { return }
                    self.playbackFailed(item?.error)
                }
                .store(in: &itemSubscriptions)

            notifications.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self, generation == self.itemGeneration else { return }
                    self.playbackFailed(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)
                }
                .store(in: &itemSubscriptions)

            notifications.publisher(for: .AVPlayerItemPlaybackStalled, object: item)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, generation == self.itemGeneration else { return }
                    self.playbackStalled()
                }
                .store(in: &itemSubscriptions)

            // A live playlist only ends when the broadcast does.
            notifications.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, generation == self.itemGeneration else { return }
                    self.controller.onStreamEnded?()
                }
                .store(in: &itemSubscriptions)
        }

        /// A stall usually clears by itself once the buffer refills. One
        /// that hasn't after `stallPatience` is treated like a failure: a
        /// fresh playlist, with the same backoff.
        private func playbackStalled() {
            guard stallTask == nil else { return }
            stallTask = Task { [weak self] in
                try? await Task.sleep(for: Coordinator.stallPatience)
                guard !Task.isCancelled, let self else { return }
                self.stallTask = nil
                // Still waiting, and still meant to play: a pause (the
                // user's, or a hold's) in the meantime ends the matter.
                guard self.controller.startsPlaying,
                      self.controller.avPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                else { return }
                self.playbackFailed(nil)
            }
        }

        /// A resolve failed, the item failed, or a stall never cleared.
        /// Tries again with backoff (`PlaybackRecovery`) before giving the
        /// stream to the web player.
        private func playbackFailed(_ error: (any Error)?) {
            // One failure per item, however many of its observers report it.
            itemGeneration += 1
            itemSubscriptions.removeAll()
            stallTask?.cancel()
            stallTask = nil

            if let refusal = error as? StreamPlaylistError, refusal == .offline {
                controller.onStreamEnded?()
                return
            }
            let staysNative = controller.staysOnNativeEngine?() ?? false
            switch recovery.step(after: error, staysNative: staysNative) {
            case .retry(let delay):
                controller.update(\.isBuffering, to: true)
                resolveAndStart(after: delay)
            case .giveUp:
                controller.onNativeFailure?()
            }
        }

        // MARK: Audio session and device

        private func observeSessionAndDevice() {
            let notifications = NotificationCenter.default

            notifications.publisher(for: AVAudioSession.interruptionNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in self?.audioSessionInterrupted(notification) }
                .store(in: &subscriptions)

            notifications.publisher(for: AVAudioSession.routeChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in self?.audioRouteChanged(notification) }
                .store(in: &subscriptions)

            notifications.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.mediaServicesWereReset() }
                .store(in: &subscriptions)

            // Low Power Mode or heat changed: the caps go through the same
            // path as a quality change.
            notifications.publisher(for: .NSProcessInfoPowerStateDidChange)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reapplyQuality() }
                .store(in: &subscriptions)

            notifications.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reapplyQuality() }
                .store(in: &subscriptions)
        }

        private func reapplyQuality() {
            controller.applyQuality(controller.preferredQuality)
        }

        /// Meant to play, and not sitting paused since before whatever just
        /// happened. The system's own pause for an interruption or a route
        /// change can land a moment before its notification does, so a
        /// pause that fresh counts as "was playing".
        private var wasPlayingJustNow: Bool {
            guard controller.startsPlaying else { return false }
            guard let pausedAt else { return true }
            return ContinuousClock.now - pausedAt < .seconds(2)
        }

        private func audioSessionInterrupted(_ notification: Notification) {
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                // The system pauses the player. Only what was playing
                // comes back afterwards.
                resumesAfterInterruption = wasPlayingJustNow
            case .ended:
                let resumes = resumesAfterInterruption
                resumesAfterInterruption = false
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                guard resumes, AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                else { return }
                reactivateAndResume()
            @unknown default:
                break
            }
        }

        /// Brings the session back up, then resumes at the live edge — if
        /// that's still wanted: the user may have paused, or a hold begun,
        /// while the interruption lasted.
        private func reactivateAndResume() {
            Task { [weak self] in
                guard let muted = self?.controller.isMuted else { return }
                await PlaybackAudioSession.shared.activate(muted: muted)
                guard let self, self.isLoaded,
                      self.controller.avPlayer != nil, self.controller.startsPlaying
                else { return }
                self.controller.resume()
            }
        }

        private func audioRouteChanged(_ notification: Notification) {
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
                  let player = controller.avPlayer
            else { return }
            if player.isMuted {
                // Nothing audible moved to the speaker: a silent stream the
                // system paused along with the route carries on.
                if wasPlayingJustNow { player.play() }
            } else {
                // Headphones (or a speaker) gone: stay quiet until the user
                // says otherwise, like any pause of theirs — no hold
                // release or interruption end restarts it out loud.
                controller.wantsPlayback = false
                player.pause()
            }
        }

        /// The media server restarted: the player, its item and the PiP
        /// controller are dead and the session is back to its defaults.
        /// Build them again with the mute and intent the stream had.
        private func mediaServicesWereReset() {
            PlaybackAudioSession.shared.invalidate()
            controller.pictureInPictureEndedAmbiguously()
            controller.update(\.canPictureInPicture, to: false)
            discardPlayer()
            resolveAndStart(after: nil)
        }

        private func discardPlayer() {
            stallTask?.cancel()
            stallTask = nil
            itemGeneration += 1
            playerSubscriptions.removeAll()
            itemSubscriptions.removeAll()
            pausedAt = nil
            if let player = controller.avPlayer {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            playerView?.playerLayer.player = nil
            controller.avPlayer = nil
            controller.pictureInPicture = nil
        }

        /// The audio session is left as it is: `PlaybackCenter` takes it
        /// down when native playback stops, not when one engine replaces
        /// another on a channel change.
        func teardown() {
            isLoaded = false
            loadTask?.cancel()
            loadTask = nil
            subscriptions.removeAll()
            resumesAfterInterruption = false
            discardPlayer()
        }
    }
}
// MARK: - Picture in picture state

/// Forwards PiP events from the fullscreen `AVPlayerViewController` to the
/// same controller hooks the inline player's PiP uses.
@MainActor
final class FullscreenPictureInPictureForwarder: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private weak var controller: StreamPlayerController?

    init(controller: StreamPlayerController) {
        self.controller = controller
    }

    // Marked active on *will* start too: fullscreen PiP can begin as the app
    // leaves, and the background handler must see it before it pauses.
    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        controller?.pictureInPictureDidStart()
    }

    // Undo the early "active" from will-start if PiP never came up.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        controller?.pictureInPictureEndedAmbiguously()
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        controller?.pictureInPictureDidStart()
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        controller?.pictureInPictureDidStop()
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        controller?.pictureInPictureWillRestore()
        completionHandler(true)
    }
}

extension NativePlayer.Coordinator: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        controller.pictureInPictureDidStart()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        controller.pictureInPictureDidStop()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        controller.pictureInPictureWillRestore()
        completionHandler(true)
    }
}
#endif
