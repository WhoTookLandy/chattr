#if os(iOS)
import Foundation
import CoreGraphics
import AVFoundation
import Combine
import UIKit
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.HomeFeedPreview")

/// Drives the single muted live HLS video preview on Home → Live.
///
/// Tracks card frames in an `@ObservationIgnored` dictionary so 120 fps
/// scrolling triggers zero SwiftUI body passes; only when the focused card
/// actually settles and starts/stops playing do observed properties change.
///
/// Reuses one `AVPlayer`, caps resolution and bitrate for quick startup and
/// low battery cost, and plays nicely with both external music (mixable audio
/// session while muted) and an active audio-only mini player (via a
/// `.feedPreview` hold if the user unmutes a card).
@MainActor
@Observable
final class HomeFeedPreviewController {

    /// Stream ID whose preview player view should currently be mounted.
    private(set) var activeStreamID: String?
    /// Stream ID whose video layer has decoded frames ready to fade in.
    private(set) var readyStreamID: String?
    /// Whether the active preview is muted. Always resets to `true` when
    /// switching cards so scrolling never blasts audio unexpectedly.
    private(set) var isMuted = true

    /// Single reusable player mounted into whichever card is active.
    @ObservationIgnored let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        return player
    }()

    /// How long a card must stay focused before we resolve its HLS playlist.
    static let settleDelay: Duration = .milliseconds(400)
    /// 480p cap — sharp on a mobile 16:9 card while starting quickly and
    /// staying light on battery and data.
    static let maxResolution = CGSize(width: 854, height: 480)
    static let peakBitRate: Double = 1_500_000
    static let forwardBufferDuration: TimeInterval = 2
    private static let liveOffset = CMTime(seconds: 3, preferredTimescale: 1)

    @ObservationIgnored private let resolver: any StreamPlaylistResolving
    @ObservationIgnored private weak var playbackCenter: PlaybackCenter?

    @ObservationIgnored private var streamOrder: [String] = []
    @ObservationIgnored private var streamsByID: [String: TwitchStream] = [:]
    @ObservationIgnored private var cardFrames: [String: HomeFeedPreviewPolicy.CardFrame] = [:]
    @ObservationIgnored private var viewportHeight: CGFloat = 0

    @ObservationIgnored private var isSurfaceActive = false
    @ObservationIgnored private var isAppActive = true
    @ObservationIgnored private var hasActiveVideoMiniPlayer = false

    @ObservationIgnored private var targetedStreamID: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var unmuteTask: Task<Void, Never>?
    @ObservationIgnored private var previewHold: PlaybackHold?
    @ObservationIgnored private var ownsAudioSession = false
    /// Bumped each time this controller queues a `PlaybackAudioSession.activate`
    /// call so a cancelled activation never deactivates a newer one's session.
    @ObservationIgnored private var audioSessionActivationGeneration = 0

    @ObservationIgnored private var deviceSubscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var itemSubscriptions: Set<AnyCancellable> = []

    init(resolver: any StreamPlaylistResolving = TwitchHLS.Resolver()) {
        self.resolver = resolver
        self.isAppActive = UIApplication.shared.applicationState == .active
        observeSystemEvents()
    }

    // MARK: - Wiring

    func attach(playback: PlaybackCenter?) {
        playbackCenter = playback
    }

    func setSurfaceActive(_ active: Bool) {
        guard isSurfaceActive != active else { return }
        isSurfaceActive = active
        if active {
            evaluateFocus()
        } else {
            stop()
        }
    }

    func setVideoMiniPlayerActive(_ active: Bool) {
        guard hasActiveVideoMiniPlayer != active else { return }
        hasActiveVideoMiniPlayer = active
        if active {
            stop()
        } else {
            evaluateFocus()
        }
    }

    func updateStreams(_ streams: [TwitchStream]) {
        streamOrder = streams.map(\.userId)
        streamsByID = Dictionary(streams.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        let validIDs = Set(streamOrder)
        cardFrames = cardFrames.filter { validIDs.contains($0.key) }
        if let targetedStreamID, !validIDs.contains(targetedStreamID) {
            stop()
        }
        evaluateFocus()
    }

    func updateViewportHeight(_ height: CGFloat) {
        guard abs(viewportHeight - height) > 1 else { return }
        viewportHeight = height
        evaluateFocus()
    }

    func reportCardFrame(streamID: String, minY: CGFloat, maxY: CGFloat) {
        let frame = HomeFeedPreviewPolicy.CardFrame(id: streamID, minY: minY, maxY: maxY)
        if cardFrames[streamID] == frame { return }
        cardFrames[streamID] = frame
        evaluateFocus()
    }

    func clearCardFrame(streamID: String) {
        guard cardFrames.removeValue(forKey: streamID) != nil else { return }
        evaluateFocus()
    }

    func refreshPolicy() {
        if !canPreviewSynchronously {
            stop()
        } else {
            evaluateFocus()
        }
    }

    // MARK: - Video readiness & mute

    func markVideoReady(for streamID: String, isReady: Bool) {
        guard activeStreamID == streamID else { return }
        if isReady {
            if readyStreamID != streamID { readyStreamID = streamID }
        } else if readyStreamID == streamID {
            readyStreamID = nil
        }
    }

    func toggleMute(for streamID: String) {
        guard activeStreamID == streamID else { return }
        unmuteTask?.cancel()
        unmuteTask = nil

        if isMuted {
            isMuted = false
            unmuteTask = Task { [weak self] in
                guard let self else { return }
                // Pause any active stream (primary or pinned background audio)
                // while the user listens to this inline preview; muting or
                // scrolling away resumes them.
                if let center = self.playbackCenter, center.hasAnyPlayback, self.previewHold == nil {
                    self.previewHold = center.holdPlayback(.feedPreview)
                }
                self.audioSessionActivationGeneration += 1
                let activationGen = self.audioSessionActivationGeneration
                await PlaybackAudioSession.shared.updateClient(
                    .homePreview,
                    state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: true, hasAudibleWeb: false)
                )
                guard !Task.isCancelled, self.activeStreamID == streamID, !self.isMuted else {
                    if activationGen == self.audioSessionActivationGeneration {
                        let fallback: AudioSessionClientState = self.activeStreamID == nil
                            ? .inactive
                            : AudioSessionClientState(hasActiveNative: true, hasAudibleNative: false, hasAudibleWeb: false)
                        PlaybackAudioSession.shared.updateClientAsync(.homePreview, state: fallback)
                        self.ownsAudioSession = fallback.hasActiveNative
                    }
                    return
                }
                self.ownsAudioSession = true
                self.player.isMuted = false
            }
        } else {
            isMuted = true
            player.isMuted = true
            releasePreviewHold()
            if ownsAudioSession {
                PlaybackAudioSession.shared.updateClientAsync(
                    .homePreview,
                    state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: false, hasAudibleWeb: false)
                )
            }
        }
    }

    // MARK: - Lifecycle

    func stop() {
        stopPlayback(clearingTarget: true)
    }

    private func stopPlayback(clearingTarget: Bool) {
        loadTask?.cancel()
        loadTask = nil
        unmuteTask?.cancel()
        unmuteTask = nil
        itemSubscriptions.removeAll()
        if clearingTarget { targetedStreamID = nil }
        if activeStreamID != nil { activeStreamID = nil }
        if readyStreamID != nil { readyStreamID = nil }
        if !isMuted { isMuted = true }
        player.pause()
        player.isMuted = true
        player.replaceCurrentItem(with: nil)
        releasePreviewHold()
        if ownsAudioSession {
            PlaybackAudioSession.shared.updateClientAsync(.homePreview, state: .inactive)
        }
        ownsAudioSession = false
    }

    // MARK: - Focus selection & playback

    private var canPreviewSynchronously: Bool {
        let mode = PlaybackPreferences.homePreview
        let onWiFi = mode == .wiFiOnly ? (NetworkReachability.shared.knownIsOnWiFi ?? true) : true
        return HomeFeedPreviewPolicy.canPreview(
            mode: mode,
            isNativePlaybackEnabled: PlayerSettings.isNativePlaybackEnabled,
            isHomeLiveVisible: isSurfaceActive && isAppActive,
            isDeviceConstrained: PlaybackLimits.deviceIsConstrained,
            isOnWiFi: onWiFi,
            hasActiveVideoMiniPlayer: hasActiveVideoMiniPlayer
        )
    }

    private func evaluateFocus() {
        guard canPreviewSynchronously else {
            if targetedStreamID != nil || activeStreamID != nil { stop() }
            return
        }

        let orderedFrames = streamOrder.compactMap { cardFrames[$0] }
        let focusedID = HomeFeedPreviewPolicy.focusedStreamID(
            in: orderedFrames,
            viewportHeight: viewportHeight
        )

        guard focusedID != targetedStreamID else { return }

        // Tear down the old stream immediately on focus change so we never show
        // stale video on a newly focused card or keep decoding off-screen.
        stop()

        guard let focusedID, let stream = streamsByID[focusedID] else { return }
        targetedStreamID = focusedID
        startDebouncedLoad(for: stream)
    }

    private func startDebouncedLoad(for stream: TwitchStream) {
        let resolver = self.resolver
        let streamID = stream.userId
        let login = stream.userLogin

        loadTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self, self.targetedStreamID == streamID else { return }

            let mode = PlaybackPreferences.homePreview
            let isOnWiFi: Bool
            if mode == .wiFiOnly {
                isOnWiFi = await NetworkReachability.shared.isOnWiFi(waitingUpTo: .milliseconds(300))
            } else {
                isOnWiFi = true
            }
            guard !Task.isCancelled, self.targetedStreamID == streamID else { return }

            let allowed = HomeFeedPreviewPolicy.canPreview(
                mode: mode,
                isNativePlaybackEnabled: PlayerSettings.isNativePlaybackEnabled,
                isHomeLiveVisible: self.isSurfaceActive && self.isAppActive,
                isDeviceConstrained: PlaybackLimits.deviceIsConstrained,
                isOnWiFi: isOnWiFi,
                hasActiveVideoMiniPlayer: self.hasActiveVideoMiniPlayer
            )
            guard allowed else {
                self.stop()
                return
            }

            do {
                let playlist = try await resolver.playlist(login: login, audioOnly: false)
                guard !Task.isCancelled, self.targetedStreamID == streamID else { return }

                // Register the muted preview through the shared audio-session
                // arbiter so it never deactivates or clobbers pinned streams.
                self.audioSessionActivationGeneration += 1
                let activationGen = self.audioSessionActivationGeneration
                await PlaybackAudioSession.shared.updateClient(
                    .homePreview,
                    state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: false, hasAudibleWeb: false)
                )
                guard !Task.isCancelled, self.targetedStreamID == streamID else {
                    if activationGen == self.audioSessionActivationGeneration,
                       self.activeStreamID == nil {
                        PlaybackAudioSession.shared.updateClientAsync(.homePreview, state: .inactive)
                        self.ownsAudioSession = false
                    }
                    return
                }
                self.ownsAudioSession = true

                self.play(playlist: playlist, streamID: streamID)
            } catch {
                guard !Task.isCancelled else { return }
                logger.debug("Feed preview skipped for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if self.targetedStreamID == streamID {
                    self.activeStreamID = nil
                    self.readyStreamID = nil
                }
            }
        }
    }

    private func play(playlist: StreamPlaylist, streamID: String) {
        let item = AVPlayerItem(url: playlist.url)
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.configuredTimeOffsetFromLive = Self.liveOffset
        item.preferredMaximumResolution = Self.maxResolution
        item.preferredPeakBitRate = Self.peakBitRate
        item.preferredForwardBufferDuration = Self.forwardBufferDuration

        observeItem(item, streamID: streamID)

        isMuted = true
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        activeStreamID = streamID
        readyStreamID = nil
        player.play()
    }

    private func observeItem(_ item: AVPlayerItem, streamID: String) {
        itemSubscriptions.removeAll()
        let notifications = NotificationCenter.default

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, self.activeStreamID == streamID else { return }
                if status == .failed {
                    // Release any audio hold / owned session, while keeping
                    // `targetedStreamID` so staying on a broken card doesn't
                    // spin in a retry loop.
                    self.stopPlayback(clearingTarget: false)
                }
            }
            .store(in: &itemSubscriptions)

        notifications.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.activeStreamID == streamID else { return }
                self.stop()
            }
            .store(in: &itemSubscriptions)
    }

    private func releasePreviewHold() {
        guard let hold = previewHold else { return }
        previewHold = nil
        playbackCenter?.releaseHold(hold)
    }

    private func observeSystemEvents() {
        let notifications = NotificationCenter.default

        notifications.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isAppActive = false
                self?.stop()
            }
            .store(in: &deviceSubscriptions)

        notifications.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isAppActive = true
                self?.evaluateFocus()
            }
            .store(in: &deviceSubscriptions)

        notifications.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPolicy() }
            .store(in: &deviceSubscriptions)

        notifications.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPolicy() }
            .store(in: &deviceSubscriptions)

        notifications.publisher(for: NetworkReachability.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPolicy() }
            .store(in: &deviceSubscriptions)
    }
}
#endif
