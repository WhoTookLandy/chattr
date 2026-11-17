import SwiftUI
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
    var isPaused = false
    var isMuted = false
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
    /// The app left the foreground and `PlaybackLifecycleObserver` chose to
    /// pause, possibly while the engine was still loading (no AVPlayer or
    /// <video> to pause yet). An engine that finishes loading while this is
    /// set stays paused. Cleared when the app comes back.
    @ObservationIgnored var holdsForBackground = false

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
    /// PiP's "return to app" button — go back to this stream's chat.
    @ObservationIgnored var onRestoreFromPictureInPicture: (() -> Void)?
    /// PiP was closed with its × (not restored) — nothing left on screen.
    @ObservationIgnored var onPictureInPictureClosed: (() -> Void)?
    @ObservationIgnored private var isRestoringFromPictureInPicture = false

    /// Something asked the stream to stay paused and will hand it back —
    /// a clip playing over it (`PlaybackCenter.holdPlayback`). Unlike a
    /// one-shot pause it outlives engine loading: a native load finishing
    /// while held doesn't start playing, and the web player is paused again
    /// if its autoplay kicks in (including after a native → web fallback,
    /// which reuses this controller). Not cleared by `reset()`.
    @ObservationIgnored private(set) var isHeld = false

    /// What the user wants the stream doing: true = playing, false = they
    /// paused it. Explicit intent, separate from `isPaused` (the engine's
    /// report), because a stream buffering before its first frame isn't
    /// "paused" yet — a user pause in that window would otherwise look like
    /// "about to autoplay" to `PlaybackCenter.holdPlayback`.
    ///
    /// Set by `togglePlay` (the user's play/pause control), and back to
    /// true whenever the stream is actually seen playing (`noteDidPlay`),
    /// so a resume from outside our controls (PiP window, lock screen)
    /// counts too. Our own `pause()`/`resume()` (holds) never touch it.
    /// Reset per stream by `PlaybackCenter`. Not observed: nothing renders
    /// from it, so changing it invalidates no view.
    @ObservationIgnored var wantsPlayback = true

    /// The engine reports real frames playing. While held, that's autoplay
    /// the hold is about to re-pause, not the user's intent.
    func noteDidPlay() {
        update(\.hasStarted, to: true)
        if !isHeld { wantsPlayback = true }
    }

    func beginHold() {
        isHeld = true
        pause()
    }

    /// `resume`: the holder paused a stream that was playing (or about to).
    /// If the engine is still loading there's nothing to resume yet — the
    /// load starts playback itself now that the hold is gone.
    func endHold(resume: Bool) {
        isHeld = false
        if resume { self.resume() }
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
        update(\.isPaused, to: false)
        update(\.isMuted, to: startsMuted)
        update(\.canPictureInPicture, to: false)
        update(\.isPictureInPictureActive, to: false)
        update(\.hasStarted, to: false)
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
            // Web, or native still loading: the control showed "play" when
            // the engine reported paused, "pause" otherwise.
            wantsPlayback = isPaused
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
        guard let player = avPlayer else { return run("pause") }
        player.pause()
    }

    func resume() {
        guard let player = avPlayer else { return run("play") }
        // Live: resume at the live edge, not where we paused.
        if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue {
            player.seek(to: CMTimeRangeGetEnd(range))
        }
        player.play()
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
        avPlayer?.currentItem?.preferredMaximumResolution = quality.maximumResolution
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
/// time, which is why the native player is opt-in and falls back to the
/// web player on any failure.
enum TwitchHLS {
    struct Unavailable: Error {}

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

    static func playlistURL(login: String, audioOnly: Bool = false) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
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
              let token = try JSONDecoder().decode(Response.self, from: data).data?.streamPlaybackAccessToken
        else { throw Unavailable() }

        var components = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(login.lowercased()).m3u8")!
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
        guard let url = components.url else { throw Unavailable() }
        guard audioOnly else { return url }
        // Audio-only: pick the `audio_only` variant out of the master
        // playlist. If Twitch didn't offer one, the full stream still plays.
        return (try? await audioOnlyVariant(in: url)) ?? url
    }

    private static func audioOnlyVariant(in master: URL) async throws -> URL? {
        let (data, _) = try await URLSession.shared.data(from: master)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated()
        where line.hasPrefix("#EXT-X-STREAM-INF") && line.contains("audio_only") {
            guard index + 1 < lines.count else { return nil }
            return URL(string: lines[index + 1], relativeTo: master)?.absoluteURL
        }
        return nil
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
        private var loadTask: Task<Void, Never>?
        private var subscriptions: Set<AnyCancellable> = []

        init(controller: StreamPlayerController) {
            self.controller = controller
        }

        @objc func tapped() { controller.onTap?() }
        @objc func swipedDown() { controller.onSwipeDown?() }

        func load(login: String, audioOnly: Bool, quality: PlayerQuality, into view: PlayerLayerView) {
            teardown()
            loadedKey = Self.key(login, audioOnly)
            controller.preferredQuality = quality
            controller.reset()

            loadTask = Task { [weak self, weak view] in
                do {
                    let url = try await TwitchHLS.playlistURL(login: login, audioOnly: audioOnly)
                    guard !Task.isCancelled, let self, let view else { return }
                    self.start(url: url, in: view)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.controller.onNativeFailure?()
                }
            }
        }

        private func start(url: URL, in view: PlayerLayerView) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)

            let item = AVPlayerItem(url: url)
            item.preferredMaximumResolution = controller.preferredQuality.maximumResolution
            let player = AVPlayer(playerItem: item)
            if controller.startsMuted {
                player.isMuted = true
            }
            controller.update(\.isMuted, to: player.isMuted)
            view.playerLayer.player = player
            controller.avPlayer = player

            if AVPictureInPictureController.isPictureInPictureSupported(),
               let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
                pip.canStartPictureInPictureAutomaticallyFromInline = true
                pip.delegate = self
                controller.pictureInPicture = pip
                controller.update(\.canPictureInPicture, to: true)
            }

            player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self else { return }
                    self.controller.update(\.isPaused, to: status == .paused)
                    if status == .playing { self.controller.noteDidPlay() }
                }
                .store(in: &subscriptions)

            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    if status == .failed { self?.controller.onNativeFailure?() }
                }
                .store(in: &subscriptions)

            // Held (a clip is playing over the stream): stay paused until
            // the holder releases — `endHold(resume:)` starts it then. Paused
            // by the user while the playlist loaded: leave it paused.
            if !controller.isHeld, controller.wantsPlayback { player.play() }
        }

        func teardown() {
            loadTask?.cancel()
            loadTask = nil
            subscriptions.removeAll()
            if let player = controller.avPlayer {
                player.pause()
                player.replaceCurrentItem(with: nil)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            controller.avPlayer = nil
            controller.pictureInPicture = nil
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
