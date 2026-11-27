#if os(iOS)
import Foundation
import AVFoundation
import Combine
import os

extension PlaybackCenter {

    // MARK: - Aggregate Audio Session

    /// Snapshot of all playback slots' audio-session needs.
    var currentAudioSessionState: AudioSessionClientState {
        let slots = allSlots
        let hasActiveNative = slots.contains { $0.hasActiveNativeEngine }
        let hasAudibleNative = slots.contains { $0.wantsExclusiveNativeAudio }
        let hasAudibleWeb = primary?.isAudibleWeb ?? false
        return AudioSessionClientState(
            hasActiveNative: hasActiveNative,
            hasAudibleNative: hasAudibleNative,
            hasAudibleWeb: hasAudibleWeb
        )
    }

    /// Pushes `PlaybackCenter`'s aggregate audio state to `PlaybackAudioSession`.
    func reconcileAudioSession(force: Bool = false) {
        audioSession.updateClientAsync(
            .playback,
            state: currentAudioSessionState,
            force: force,
            inBackground: lifecycle?.isInBackground ?? false
        )
    }

    /// Awaited by `NativePlayer.Coordinator` right before creating an `AVPlayer`
    /// so the audio session is active in the right category before audio starts.
    /// Always passes `force: true` so a torn-down `WKWebView` that deactivated
    /// the session asynchronously can never leave `AVAudioSession` inactive.
    func prepareAudioSessionForNativeStart(slotID: UUID) async {
        guard let slot = slot(withID: slotID) else { return }
        var state = currentAudioSessionState
        // The requesting slot's AVPlayer isn't instantiated yet, so ensure its
        // upcoming native state is counted even if `engine` is still resolving.
        state.hasActiveNative = true
        if !slot.controller.isMuted && slot.controller.volume > 0 {
            state.hasAudibleNative = true
        }
        await audioSession.updateClient(
            .playback,
            state: state,
            force: true,
            inBackground: lifecycle?.isInBackground ?? false
        )
    }

    // MARK: - Centralized System Audio Notifications

    func observeSystemAudioNotifications() {
        let notifications = NotificationCenter.default

        notifications.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
            .store(in: &audioSystemSubscriptions)

        notifications.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            }
            .store(in: &audioSystemSubscriptions)

        notifications.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleMediaServicesWereReset()
            }
            .store(in: &audioSystemSubscriptions)
    }

    func handleAudioSessionInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            let reasonRaw = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            playbackCenterLogger.notice("Audio session interruption began (reason=\(reasonRaw.map(String.init) ?? "nil", privacy: .public), slots=\(self.allSlots.count))")
            for slot in allSlots where slot.engineKind == .native {
                slot.resumesAfterInterruption = slot.engine?.wasPlayingJustNow ?? false
            }

        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            playbackCenterLogger.notice("Audio session interruption ended (shouldResume=\(shouldResume))")
            var slotIDsToResume: [UUID] = []
            for slot in allSlots where slot.engineKind == .native {
                let wasPlaying = slot.resumesAfterInterruption
                slot.resumesAfterInterruption = false
                if shouldResume, wasPlaying {
                    slotIDsToResume.append(slot.id)
                }
            }
            guard !slotIDsToResume.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.audioSession.updateClient(
                    .playback,
                    state: self.currentAudioSessionState,
                    force: true,
                    inBackground: self.lifecycle?.isInBackground ?? false
                )
                for id in slotIDsToResume {
                    guard let slot = self.slot(withID: id),
                          slot.controller.avPlayer != nil,
                          slot.controller.startsPlaying
                    else { continue }
                    slot.controller.resume()
                }
            }

        @unknown default:
            break
        }
    }

    func handleAudioRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
        else { return }

        for slot in allSlots where slot.engineKind == .native {
            guard let player = slot.controller.avPlayer else { continue }
            if player.isMuted || slot.controller.volume == 0 {
                // Silent stream paused by the OS along with the route: carry on.
                if slot.engine?.wasPlayingJustNow == true {
                    player.play()
                }
            } else {
                // Headphones disconnected: stay quiet until user resumes.
                slot.controller.wantsPlayback = false
                player.pause()
            }
        }
    }

    func handleMediaServicesWereReset() {
        audioSession.invalidate()
        for slot in allSlots where slot.engineKind == .native {
            slot.engine?.handleMediaServicesReset()
        }
    }

    // MARK: - Now Playing (Lock Screen / Control Center)

    /// Slots eligible for Lock Screen / Control Center Now Playing:
    /// all `pinnedAudio` slots plus `primary` when in native audio-only mode.
    /// Yields to WebKit PiP while an audible web primary is in background PiP.
    var nowPlayingEligibleSlots: [PlaybackSlot] {
        if let primary, primary.isAudibleWeb, primary.controller.isPictureInPictureActive {
            return []
        }
        var eligible: [PlaybackSlot] = []
        if let primary, primary.audioOnly, primary.engineKind == .native {
            eligible.append(primary)
        }
        eligible.append(contentsOf: pinnedAudio.filter { $0.engineKind == .native || $0.engine == nil })
        return eligible
    }

    func refreshNowPlaying() {
        guard let summary = StreamNowPlaying.summarize(slots: nowPlayingEligibleSlots) else {
            nowPlaying.clear()
            return
        }
        nowPlaying.publish(summary: summary, center: self)
    }

    /// Unified Lock Screen play: resumes every Now Playing eligible slot
    /// (never inverting mixed paused/playing states).
    func remotePlayBackgroundAudio() {
        applyPlayPause(to: nowPlayingEligibleSlots, play: true)
    }

    /// Unified Lock Screen pause: pauses every Now Playing eligible slot.
    func remotePauseBackgroundAudio() {
        applyPlayPause(to: nowPlayingEligibleSlots, play: false)
    }

    /// Unified Lock Screen toggle: if *any* eligible slot is playing, pauses all;
    /// if *all* are paused, plays all.
    func remoteTogglePlayPauseBackgroundAudio() {
        let slots = nowPlayingEligibleSlots
        guard !slots.isEmpty else { return }
        let anyPlaying = slots.contains { !$0.controller.isPaused }
        applyPlayPause(to: slots, play: !anyPlaying)
    }

    /// Unified in-app audio dock play/pause toggle covering `audioDockSlots`.
    func togglePlayPauseAudioDock() {
        let slots = audioDockSlots
        guard !slots.isEmpty else { return }
        let anyPlaying = slots.contains { !$0.controller.isPaused }
        applyPlayPause(to: slots, play: !anyPlaying)
    }

    private func applyPlayPause(to slots: [PlaybackSlot], play: Bool) {
        for slot in slots {
            if play {
                if slot.controller.isPaused || !slot.controller.wantsPlayback {
                    slot.controller.remotePlay()
                }
            } else {
                if !slot.controller.isPaused || slot.controller.wantsPlayback {
                    slot.controller.remotePause()
                }
            }
        }
        refreshNowPlaying()
        reconcileAudioSession()
    }
}
#endif
