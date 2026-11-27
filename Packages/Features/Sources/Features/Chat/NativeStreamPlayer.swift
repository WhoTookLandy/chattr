import SwiftUI
import Core
#if os(iOS)
import UIKit
import QuartzCore
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
        /// Temporary video layer used during a warm Audio-Only → Video swap so
        /// the incoming `AVPlayer` decodes at full view size and bridges the
        /// handoff until `playerLayer` has painted its first frame.
        private(set) var standbyLayer: AVPlayerLayer?

        func installStandbyLayer(_ layer: AVPlayerLayer) {
            removeStandbyLayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = bounds
            self.layer.addSublayer(layer)
            CATransaction.commit()
            standbyLayer = layer
        }

        func removeStandbyLayer() {
            guard let existing = standbyLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            existing.player = nil
            existing.removeFromSuperlayer()
            CATransaction.commit()
            standbyLayer = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let standbyLayer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            standbyLayer.frame = bounds
            CATransaction.commit()
        }
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
        /// How long a warm-swap standby player gets to reach `.playing` before
        /// we invalidate the cached URL and resolve fresh.
        private static let standbyTimeout: Duration = .seconds(8)
        /// Once a video standby hits `.playing`, how long to wait for
        /// `isReadyForDisplay` before committing anyway.
        private static let standbyFrameGrace: Duration = .milliseconds(1200)
        /// Delay before showing the buffering spinner during a warm video
        /// transition so fast switches stay spinner-free.
        private static let standbyBufferingDelay: Duration = .milliseconds(700)
        /// Compact forward buffer target while warming up a standby player so
        /// it transitions to `.playing` quickly; reset to `0` on commit.
        private static let warmStartBufferDuration: TimeInterval = 2
        /// Maximum time the standby cover layer stays after promoting the
        /// primary `AVPlayerLayer` while waiting for `isReadyForDisplay`.
        private static let coverMaxLifetime: Duration = .milliseconds(250)

        private let resolver: any StreamPlaylistResolving
        private var allowsPictureInPicture: Bool
        private var login = ""
        /// Desired audio-only state.
        private var audioOnly = false
        /// Mode currently playing on `controller.avPlayer`.
        private var activeAudioOnly = false
        private weak var playerView: PlayerLayerView?
        /// Between `load` and `teardown`.
        private var isLoaded = false

        /// Most recently resolved playlist for this channel, kept in memory so
        /// audio-only ↔ video toggles skip auth, GQL and Usher round-trips.
        private var cachedPlaylist: StreamPlaylist?
        private var cachedPlaylistAt: ContinuousClock.Instant?
        private var warmAudioOnlyTask: Task<Void, Never>?
        private var modeSwitchTask: Task<Void, Never>?

        private var loadTask: Task<Void, Never>?
        private var stallTask: Task<Void, Never>?
        private var recovery = PlaybackRecovery()
        /// Bumped for each item and each failure, so a late report from an
        /// item that was replaced (or already counted as failed) is dropped.
        private var itemGeneration = 0
        /// When the player last went to paused; nil while it isn't.
        private var pausedAt: ContinuousClock.Instant?

        // MARK: Overlapped warm-swap state
        private var standbyPlayer: AVPlayer?
        private var standbySubscriptions: Set<AnyCancellable> = []
        private var standbyGeneration = 0
        private var standbyTargetAudioOnly = false
        private var standbyIsAudioOnlyRendition = false
        private var standbyUsedCachedURL = false
        private var standbyIsPlaying = false
        private var standbyFrameReady = false
        private var standbyTimeoutTask: Task<Void, Never>?
        private var standbyFrameGraceTask: Task<Void, Never>?
        private var standbyBufferingTask: Task<Void, Never>?
        private var coverSubscription: AnyCancellable?
        private var coverCleanupTask: Task<Void, Never>?

        /// Audio session and device state, for the engine's whole life.
        private var subscriptions: Set<AnyCancellable> = []
        private var playerSubscriptions: Set<AnyCancellable> = []
        private var itemSubscriptions: Set<AnyCancellable> = []

        init(
            controller: StreamPlayerController,
            resolver: any StreamPlaylistResolving = TwitchHLS.Resolver(),
            allowsPictureInPicture: Bool = true
        ) {
            self.controller = controller
            self.resolver = resolver
            self.allowsPictureInPicture = allowsPictureInPicture
        }

        func setAllowsPictureInPicture(_ allowed: Bool) {
            guard allowsPictureInPicture != allowed else { return }
            allowsPictureInPicture = allowed
            if !allowed {
                tearDownPictureInPicture()
                if audioOnly {
                    playerView?.playerLayer.player = nil
                }
            } else if let player = controller.avPlayer {
                syncPlayerLayerAndPiP(for: player, audioOnly: audioOnly)
            }
        }

        private func tearDownPictureInPicture() {
            if let pip = controller.pictureInPicture {
                if pip.isPictureInPictureActive {
                    pip.stopPictureInPicture()
                }
                pip.delegate = nil
            }
            controller.pictureInPicture = nil
            controller.update(\.canPictureInPicture, to: false)
            controller.pictureInPictureEndedAmbiguously()
        }

        /// Keeps `AVPlayerLayer` attachment, `audiovisualBackgroundPlaybackPolicy`,
        /// and `AVPictureInPictureController` consistent with `audioOnly`.
        /// Detaching `playerLayer.player = nil` in audio-only / headless pinned
        /// mode guarantees iOS never pauses a hidden video rendition or demoted
        /// player across background/foreground transitions (Apple QA1668).
        private func syncPlayerLayerAndPiP(for player: AVPlayer, audioOnly: Bool) {
            player.audiovisualBackgroundPlaybackPolicy = audioOnly ? .continuesIfPossible : .automatic
            guard let view = playerView else { return }
            if audioOnly {
                tearDownPictureInPicture()
                if view.playerLayer.player != nil {
                    view.playerLayer.player = nil
                }
            } else {
                if view.playerLayer.player !== player {
                    view.playerLayer.player = player
                }
                if allowsPictureInPicture,
                   controller.pictureInPicture == nil,
                   AVPictureInPictureController.isPictureInPictureSupported(),
                   let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
                    pip.canStartPictureInPictureAutomaticallyFromInline = true
                    pip.delegate = self
                    controller.pictureInPicture = pip
                    controller.update(\.canPictureInPicture, to: true)
                }
                controller.refreshAutomaticPictureInPicture()
            }
        }

        @objc func tapped() { controller.onTap?() }
        @objc func swipedDown() { controller.onSwipeDown?() }

        func load(login: String, audioOnly: Bool, quality: PlayerQuality, into view: PlayerLayerView) {
            teardown()
            loadedKey = Self.key(login, audioOnly)
            self.login = login
            self.audioOnly = audioOnly
            self.activeAudioOnly = audioOnly
            playerView = view
            isLoaded = true
            recovery = PlaybackRecovery()
            controller.preferredQuality = quality
            controller.reset()
            observeSessionAndDevice()
            resolveAndStart(after: nil)
        }

        /// Switches between audio-only and video without tearing down the
        /// engine or interrupting audio. While playing, warms the incoming
        /// rendition on a muted standby `AVPlayer` using the cached playlist
        /// URL and swaps atomically once it is ready.
        func setAudioOnly(_ newAudioOnly: Bool, quality: PlayerQuality) {
            guard isLoaded else { return }
            controller.preferredQuality = quality
            loadedKey = Self.key(login, newAudioOnly)
            let modeChanged = audioOnly != newAudioOnly
            audioOnly = newAudioOnly
            guard modeChanged else {
                controller.applyQuality(quality)
                return
            }

            // Still resolving the initial playlist (no AVPlayer yet): restart
            // the resolve for the newly requested mode.
            guard let currentPlayer = controller.avPlayer else {
                cancelStandby()
                resolveAndStart(after: nil)
                return
            }

            // Rapid toggle back to the mode already playing on the primary
            // player: drop any in-flight standby and keep playing seamlessly.
            if newAudioOnly == activeAudioOnly {
                cancelStandby()
                syncPlayerLayerAndPiP(for: currentPlayer, audioOnly: newAudioOnly)
                controller.applyQuality(quality)
                return
            }

            cancelStandby()

            // Entering audio-only: detach AVPlayerLayer and allow background
            // audio immediately so locking the screen during the brief handoff
            // doesn't pause it.
            if newAudioOnly {
                syncPlayerLayerAndPiP(for: currentPlayer, audioOnly: true)
            }

            // Already playing the master playlist with hidden video (Twitch
            // offered no `audio_only` variant): returning to video is an
            // instant cap removal on the same live item.
            if !newAudioOnly, controller.playsVideoHidden, let currentItem = currentPlayer.currentItem {
                activeAudioOnly = false
                controller.playsVideoHidden = false
                syncPlayerLayerAndPiP(for: currentPlayer, audioOnly: false)
                controller.applyQualityLimits(to: currentItem)
                return
            }

            // Entering audio-only when we already confirmed Twitch has no
            // `audio_only` variant for this channel: drop the bitrate cap in
            // place on the existing item with zero interruption.
            if newAudioOnly,
               let cached = freshCachedPlaylist,
               cached.didProbeAudioOnly,
               cached.audioOnlyURL == nil,
               let currentItem = currentPlayer.currentItem {
                activeAudioOnly = true
                controller.playsVideoHidden = true
                controller.applyQualityLimits(to: currentItem)
                return
            }

            let bridgeLiveAudio = controller.startsPlaying && currentPlayer.timeControlStatus != .paused
            transitionToMode(audioOnly: newAudioOnly, bridgeLiveAudio: bridgeLiveAudio)
        }

        // MARK: Resolve, start, retry

        private var freshCachedPlaylist: StreamPlaylist? {
            guard let cachedPlaylist, let cachedPlaylistAt,
                  ContinuousClock.now - cachedPlaylistAt < StreamPlaylistCache.defaultTTL
            else { return nil }
            return cachedPlaylist
        }

        /// Resolves the playlist (after `delay`, for a retry) and starts
        /// it — on the player that's already there, if one is.
        private func resolveAndStart(after delay: Duration?, invalidateCache: Bool = false) {
            loadTask?.cancel()
            // A report that was already on its way to the main queue when
            // the engine was torn down must not start it again.
            guard isLoaded else { return }
            let resolver = self.resolver
            let login = self.login
            let audioOnly = self.audioOnly
            loadTask = Task { [weak self] in
                if invalidateCache {
                    await resolver.invalidate(login: login)
                    guard !Task.isCancelled else { return }
                }
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
                    if let prepare = self.controller.onPrepareAudioSession {
                        await prepare()
                    } else {
                        await PlaybackAudioSession.shared.activate(muted: self.controller.isMuted)
                    }
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
            cancelStandby()
            cachedPlaylist = playlist
            cachedPlaylistAt = ContinuousClock.now
            activeAudioOnly = audioOnly
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
                // A retry or paused mode switch: the same player (and PiP
                // controller), a fresh playlist.
                player = existing
                syncPlayerLayerAndPiP(for: player, audioOnly: audioOnly)
                player.replaceCurrentItem(with: item)
            } else {
                player = AVPlayer(playerItem: item)
                // `isMuted` is the mute asked for: `startsMuted` on a first
                // start (`reset()` mirrors it, `toggleMute` keeps both in
                // step while loading), the stream's own after a rebuild.
                player.isMuted = controller.isMuted
                player.volume = controller.volume
                controller.avPlayer = player
                syncPlayerLayerAndPiP(for: player, audioOnly: audioOnly)
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

            warmAudioOnlyVariantIfNeeded()
        }

        // MARK: Overlapped warm swap (audio-only ↔ video)

        /// Quietly probes the `audio_only` media playlist URL from the master
        /// playlist once video playback has started so a later Video → Audio-Only
        /// switch needs zero network resolution.
        private func warmAudioOnlyVariantIfNeeded() {
            guard isLoaded, !audioOnly, warmAudioOnlyTask == nil,
                  let cached = freshCachedPlaylist, !cached.didProbeAudioOnly
            else { return }
            let resolver = self.resolver
            let login = self.login
            let masterURL = cached.masterURL
            warmAudioOnlyTask = Task { [weak self] in
                let probe = try? await resolver.warmAudioOnlyVariant(for: masterURL, login: login)
                guard !Task.isCancelled, let self, self.isLoaded else { return }
                self.warmAudioOnlyTask = nil
                guard let current = self.cachedPlaylist, current.masterURL == masterURL else { return }
                switch probe {
                case .available(let variant):
                    self.cachedPlaylist = StreamPlaylist(
                        url: current.url,
                        isAudioOnlyRendition: current.isAudioOnlyRendition,
                        masterURL: masterURL,
                        audioOnlyURL: variant,
                        didProbeAudioOnly: true
                    )
                case .unavailable:
                    self.cachedPlaylist = StreamPlaylist(
                        url: current.url,
                        isAudioOnlyRendition: current.isAudioOnlyRendition,
                        masterURL: masterURL,
                        audioOnlyURL: nil,
                        didProbeAudioOnly: true
                    )
                case .failed, nil:
                    break
                }
            }
        }

        private func transitionToMode(audioOnly targetAudioOnly: Bool, bridgeLiveAudio: Bool) {
            if let cached = freshCachedPlaylist {
                if !targetAudioOnly {
                    let target = StreamPlaylist(
                        url: cached.masterURL,
                        isAudioOnlyRendition: false,
                        masterURL: cached.masterURL,
                        audioOnlyURL: cached.audioOnlyURL,
                        didProbeAudioOnly: cached.didProbeAudioOnly
                    )
                    if bridgeLiveAudio {
                        beginWarmSwap(to: target, targetAudioOnly: false, usedCachedURL: true)
                    } else {
                        start(target)
                    }
                    return
                }
                if let audioURL = cached.audioOnlyURL {
                    let target = StreamPlaylist(
                        url: audioURL,
                        isAudioOnlyRendition: true,
                        masterURL: cached.masterURL,
                        audioOnlyURL: audioURL,
                        didProbeAudioOnly: true
                    )
                    if bridgeLiveAudio {
                        beginWarmSwap(to: target, targetAudioOnly: true, usedCachedURL: true)
                    } else {
                        start(target)
                    }
                    return
                }
            }

            // Need to probe Usher (if background warm probe hasn't finished yet)
            // or refresh an expired token — keep the active player running
            // uninterrupted while resolving.
            let resolver = self.resolver
            let login = self.login
            let cachedForProbe = freshCachedPlaylist
            modeSwitchTask = Task { [weak self] in
                do {
                    if targetAudioOnly, let cached = cachedForProbe, !cached.didProbeAudioOnly {
                        do {
                            let probe = try await resolver.warmAudioOnlyVariant(for: cached.masterURL, login: login)
                            guard !Task.isCancelled, let self, self.isLoaded, self.audioOnly == targetAudioOnly else { return }
                            switch probe {
                            case .available(let variant):
                                let target = StreamPlaylist(
                                    url: variant,
                                    isAudioOnlyRendition: true,
                                    masterURL: cached.masterURL,
                                    audioOnlyURL: variant,
                                    didProbeAudioOnly: true
                                )
                                self.cachedPlaylist = target
                                self.applyResolvedModeSwitch(target, targetAudioOnly: true, usedCachedURL: true, bridgeLiveAudio: bridgeLiveAudio)
                                return
                            case .unavailable:
                                self.cachedPlaylist = StreamPlaylist(
                                    url: cached.masterURL,
                                    isAudioOnlyRendition: false,
                                    masterURL: cached.masterURL,
                                    audioOnlyURL: nil,
                                    didProbeAudioOnly: true
                                )
                                if let currentItem = self.controller.avPlayer?.currentItem {
                                    self.activeAudioOnly = true
                                    self.controller.playsVideoHidden = true
                                    self.controller.applyQualityLimits(to: currentItem)
                                }
                                return
                            case .failed:
                                break
                            }
                        } catch StreamPlaylistError.forbidden {
                            await resolver.invalidate(login: login)
                            guard !Task.isCancelled else { return }
                        }
                    }

                    let playlist = try await resolver.playlist(login: login, audioOnly: targetAudioOnly)
                    guard !Task.isCancelled, let self, self.isLoaded, self.audioOnly == targetAudioOnly else { return }
                    self.cachedPlaylist = playlist
                    self.cachedPlaylistAt = ContinuousClock.now
                    self.applyResolvedModeSwitch(playlist, targetAudioOnly: targetAudioOnly, usedCachedURL: false, bridgeLiveAudio: bridgeLiveAudio)
                } catch {
                    guard !Task.isCancelled, let self, self.isLoaded, self.audioOnly == targetAudioOnly else { return }
                    self.playbackFailed(error)
                }
            }
        }

        private func applyResolvedModeSwitch(
            _ playlist: StreamPlaylist,
            targetAudioOnly: Bool,
            usedCachedURL: Bool,
            bridgeLiveAudio: Bool
        ) {
            if targetAudioOnly, !playlist.isAudioOnlyRendition,
               !activeAudioOnly, let currentItem = controller.avPlayer?.currentItem {
                activeAudioOnly = true
                controller.playsVideoHidden = true
                controller.applyQualityLimits(to: currentItem)
                return
            }
            if bridgeLiveAudio, controller.avPlayer != nil, controller.startsPlaying {
                beginWarmSwap(to: playlist, targetAudioOnly: targetAudioOnly, usedCachedURL: usedCachedURL)
            } else {
                start(playlist)
            }
        }

        private func beginWarmSwap(to playlist: StreamPlaylist, targetAudioOnly: Bool, usedCachedURL: Bool) {
            guard isLoaded, let view = playerView else { return }
            standbyGeneration += 1
            let generation = standbyGeneration
            standbyTargetAudioOnly = targetAudioOnly
            standbyIsAudioOnlyRendition = playlist.isAudioOnlyRendition
            standbyUsedCachedURL = usedCachedURL
            standbyIsPlaying = false
            standbyFrameReady = targetAudioOnly

            let item = AVPlayerItem(url: playlist.url)
            item.automaticallyPreservesTimeOffsetFromLive = true
            item.configuredTimeOffsetFromLive = StreamPlayerController.liveOffset
            item.preferredForwardBufferDuration = Self.warmStartBufferDuration
            controller.applyQualityLimits(to: item, videoIsHidden: targetAudioOnly && !playlist.isAudioOnlyRendition)

            let standby = AVPlayer(playerItem: item)
            standby.isMuted = true
            standby.audiovisualBackgroundPlaybackPolicy = targetAudioOnly ? .continuesIfPossible : .automatic
            standbyPlayer = standby

            if !targetAudioOnly {
                let layer = AVPlayerLayer(player: standby)
                layer.videoGravity = .resizeAspect
                layer.opacity = 0
                view.installStandbyLayer(layer)

                layer.publisher(for: \.isReadyForDisplay)
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] ready in
                        guard let self, generation == self.standbyGeneration, ready else { return }
                        self.standbyFrameReady = true
                        self.tryCommitStandby(generation: generation)
                    }
                    .store(in: &standbySubscriptions)

                standbyBufferingTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.standbyBufferingDelay)
                    guard !Task.isCancelled, let self,
                          generation == self.standbyGeneration,
                          !self.standbyFrameReady,
                          self.controller.startsPlaying
                    else { return }
                    self.controller.update(\.isBuffering, to: true)
                }
            }

            standby.publisher(for: \.timeControlStatus)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self, generation == self.standbyGeneration, status == .playing else { return }
                    self.standbyIsPlaying = true
                    if !self.standbyFrameReady, self.standbyFrameGraceTask == nil {
                        self.standbyFrameGraceTask = Task { [weak self] in
                            try? await Task.sleep(for: Self.standbyFrameGrace)
                            guard !Task.isCancelled, let self, generation == self.standbyGeneration else { return }
                            self.standbyFrameReady = true
                            self.tryCommitStandby(generation: generation)
                        }
                    }
                    self.tryCommitStandby(generation: generation)
                }
                .store(in: &standbySubscriptions)

            item.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak item] status in
                    guard let self, generation == self.standbyGeneration, status == .failed else { return }
                    self.standbyFailed(generation: generation, error: item?.error)
                }
                .store(in: &standbySubscriptions)

            NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    guard let self, generation == self.standbyGeneration else { return }
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                    self.standbyFailed(generation: generation, error: error)
                }
                .store(in: &standbySubscriptions)

            standbyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.standbyTimeout)
                guard !Task.isCancelled, let self, generation == self.standbyGeneration else { return }
                self.standbyFailed(generation: generation, error: nil)
            }

            standby.play()
        }

        private func tryCommitStandby(generation: Int) {
            guard isLoaded, generation == standbyGeneration, standbyIsPlaying, standbyFrameReady else { return }
            guard let standby = standbyPlayer, let item = standby.currentItem, let view = playerView else { return }

            let targetAudioOnly = standbyTargetAudioOnly
            let isAudioOnlyRendition = standbyIsAudioOnlyRendition
            let incomingLayer = view.standbyLayer

            // Detach standby bookkeeping before promoting `standby` to primary.
            standbyGeneration += 1
            standbySubscriptions.removeAll()
            standbyTimeoutTask?.cancel()
            standbyTimeoutTask = nil
            standbyFrameGraceTask?.cancel()
            standbyFrameGraceTask = nil
            standbyBufferingTask?.cancel()
            standbyBufferingTask = nil
            standbyPlayer = nil

            if let incomingLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                incomingLayer.opacity = 1
                CATransaction.commit()
            }

            // Atomic handoff: unmute incoming player and silence the outgoing one
            // back-to-back on the main actor so there is no gap.
            stallTask?.cancel()
            stallTask = nil
            playerSubscriptions.removeAll()
            itemSubscriptions.removeAll()
            pausedAt = nil

            let oldPlayer = controller.avPlayer
            let shouldPlay = controller.startsPlaying
            oldPlayer?.isMuted = true
            standby.isMuted = controller.isMuted
            standby.volume = controller.volume

            oldPlayer?.pause()
            oldPlayer?.replaceCurrentItem(with: nil)

            item.preferredForwardBufferDuration = 0
            activeAudioOnly = targetAudioOnly
            controller.playsVideoHidden = targetAudioOnly && !isAudioOnlyRendition
            controller.applyQualityLimits(to: item)
            controller.avPlayer = standby
            syncPlayerLayerAndPiP(for: standby, audioOnly: targetAudioOnly)

            observePlayer(standby)
            observeItem(item)

            if shouldPlay {
                controller.update(\.isPaused, to: false)
                controller.update(\.isBuffering, to: false)
                controller.noteDidPlay()
            } else {
                standby.pause()
                controller.update(\.isPaused, to: true)
                controller.update(\.isBuffering, to: false)
            }

            if incomingLayer != nil {
                scheduleStandbyCoverRemoval(on: view)
            }
            warmAudioOnlyVariantIfNeeded()
        }

        /// Keeps the already-painted `standbyLayer` covering `view.playerLayer`
        /// until `view.playerLayer.isReadyForDisplay` flips true (typically
        /// one frame) so removing the standby layer never blinks the poster.
        private func scheduleStandbyCoverRemoval(on view: PlayerLayerView) {
            coverSubscription?.cancel()
            coverSubscription = nil
            coverCleanupTask?.cancel()
            coverCleanupTask = nil

            if view.playerLayer.isReadyForDisplay {
                view.removeStandbyLayer()
                return
            }

            coverSubscription = view.playerLayer.publisher(for: \.isReadyForDisplay)
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak view] ready in
                    guard ready else { return }
                    self?.clearStandbyCover(on: view)
                }

            coverCleanupTask = Task { [weak self, weak view] in
                try? await Task.sleep(for: Self.coverMaxLifetime)
                guard !Task.isCancelled else { return }
                self?.clearStandbyCover(on: view)
            }
        }

        private func clearStandbyCover(on view: PlayerLayerView?) {
            coverSubscription?.cancel()
            coverSubscription = nil
            coverCleanupTask?.cancel()
            coverCleanupTask = nil
            view?.removeStandbyLayer()
        }

        private func standbyFailed(generation: Int, error: (any Error)?) {
            guard isLoaded, generation == standbyGeneration else { return }
            let targetAudioOnly = standbyTargetAudioOnly
            let wasCached = standbyUsedCachedURL
            cancelStandby()

            if wasCached {
                // Cached token/playlist may have expired: evict and retry once
                // with fresh credentials while keeping the current player live.
                cachedPlaylist = nil
                cachedPlaylistAt = nil
                let resolver = self.resolver
                let login = self.login
                modeSwitchTask = Task { [weak self] in
                    await resolver.invalidate(login: login)
                    guard !Task.isCancelled, let self, self.isLoaded, self.audioOnly == targetAudioOnly else { return }
                    let bridgeLiveAudio = self.controller.startsPlaying && self.controller.avPlayer?.timeControlStatus != .paused
                    self.transitionToMode(audioOnly: targetAudioOnly, bridgeLiveAudio: bridgeLiveAudio)
                }
            } else {
                playbackFailed(error)
            }
        }

        private func cancelStandby() {
            standbyGeneration += 1
            modeSwitchTask?.cancel()
            modeSwitchTask = nil
            standbyTimeoutTask?.cancel()
            standbyTimeoutTask = nil
            standbyFrameGraceTask?.cancel()
            standbyFrameGraceTask = nil
            standbyBufferingTask?.cancel()
            standbyBufferingTask = nil
            standbySubscriptions.removeAll()
            if let standby = standbyPlayer {
                standby.pause()
                standby.replaceCurrentItem(with: nil)
                standbyPlayer = nil
            }
            clearStandbyCover(on: playerView)
            if let primary = controller.avPlayer {
                controller.update(\.isBuffering, to: primary.timeControlStatus == .waitingToPlayAtSpecifiedRate)
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
                    let changed = self.controller.isMuted != player.isMuted
                    self.controller.update(\.isMuted, to: player.isMuted)
                    if changed {
                        self.controller.onAudioStateChange?(false)
                    }
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
            warmAudioOnlyTask?.cancel()
            warmAudioOnlyTask = nil
            cancelStandby()
            cachedPlaylist = nil
            cachedPlaylistAt = nil

            if let refusal = error as? StreamPlaylistError, refusal == .offline {
                controller.onStreamEnded?()
                return
            }
            let staysNative = controller.staysOnNativeEngine?() ?? false
            switch recovery.step(after: error, staysNative: staysNative) {
            case .retry(let delay):
                controller.update(\.isBuffering, to: true)
                resolveAndStart(after: delay, invalidateCache: true)
            case .giveUp:
                controller.onNativeFailure?()
            }
        }

        // MARK: Device state & centralized audio-session hooks

        private func observeSessionAndDevice() {
            let notifications = NotificationCenter.default

            // Low Power Mode or heat changed: the caps go through the same
            // path as a quality change. Interruption, route-change, and
            // media-services-reset notifications are handled once by
            // `PlaybackCenter` across all active slots.
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
        var wasPlayingJustNow: Bool {
            guard controller.startsPlaying else { return false }
            guard let pausedAt else { return true }
            return ContinuousClock.now - pausedAt < .seconds(2)
        }

        /// Called by `PlaybackCenter` after it invalidates the audio session
        /// once on `AVAudioSession.mediaServicesWereResetNotification`.
        func handleMediaServicesReset() {
            guard isLoaded else { return }
            controller.pictureInPictureEndedAmbiguously()
            controller.update(\.canPictureInPicture, to: false)
            cachedPlaylist = nil
            cachedPlaylistAt = nil
            discardPlayer()
            resolveAndStart(after: nil, invalidateCache: true)
        }

        private func discardPlayer() {
            cancelStandby()
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
            warmAudioOnlyTask?.cancel()
            warmAudioOnlyTask = nil
            cachedPlaylist = nil
            cachedPlaylistAt = nil
            subscriptions.removeAll()
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
