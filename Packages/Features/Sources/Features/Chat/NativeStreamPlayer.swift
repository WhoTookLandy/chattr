import SwiftUI
import Core
#if os(iOS)
import UIKit
import AVKit
import AVFoundation
import Combine
import WebKit
#endif

#if os(iOS)

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
