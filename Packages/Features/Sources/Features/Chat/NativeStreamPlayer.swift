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
    /// Flips once real frames are playing.
    var hasStarted = false
    /// The native player couldn't get a playlist / failed to play — the
    /// header falls back to the web player for this channel.
    var nativeFailed = false

    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var avPlayer: AVPlayer?
    @ObservationIgnored var pictureInPicture: AVPictureInPictureController?
    @ObservationIgnored weak var hostView: UIView?

    @ObservationIgnored var onTap: (() -> Void)?
    @ObservationIgnored var onSwipeDown: (() -> Void)?
    /// Native engine failed — `PlaybackCenter` rebuilds on the web engine.
    @ObservationIgnored var onNativeFailure: (() -> Void)?

    var isNative: Bool { avPlayer != nil }

    func reset() {
        isPaused = false
        isMuted = false
        canPictureInPicture = false
        hasStarted = false
    }

    func togglePlay() {
        guard let player = avPlayer else { return run("togglePlay") }
        if player.timeControlStatus == .paused {
            // Live: resume at the live edge, not where we paused.
            if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue {
                player.seek(to: CMTimeRangeGetEnd(range))
            }
            player.play()
        } else {
            player.pause()
        }
    }

    func toggleMute() {
        guard let player = avPlayer else { return run("toggleMute") }
        player.isMuted.toggle()
        isMuted = player.isMuted
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
        presenter.present(fullscreen, animated: true)
    }

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
            view.playerLayer.player = player
            controller.avPlayer = player

            if AVPictureInPictureController.isPictureInPictureSupported(),
               let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
                pip.canStartPictureInPictureAutomaticallyFromInline = true
                controller.pictureInPicture = pip
                controller.canPictureInPicture = true
            }

            player.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self else { return }
                    self.controller.isPaused = status == .paused
                    if status == .playing { self.controller.hasStarted = true }
                }
                .store(in: &subscriptions)

            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    if status == .failed { self?.controller.onNativeFailure?() }
                }
                .store(in: &subscriptions)

            player.play()
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
#endif
