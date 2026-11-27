#if os(iOS)
import UIKit
import AVKit
import WebKit
import os

// MARK: - Picture in picture gate

extension StreamPlayerController {
    /// Whether leaving the app may hand this stream to picture in picture,
    /// per Settings → Video & Device → Picture in Picture.
    var allowsAutomaticPictureInPicture: Bool {
        switch PlaybackPreferences.pictureInPicture {
        case .off: false
        case .always: true
        case .whenSoundOn: !isMuted && !isPaused
        }
    }

    /// Keeps the native PiP controller's auto-start flag in step with the
    /// preference and the mute / pause state.
    func refreshAutomaticPictureInPicture() {
        guard let pip = pictureInPicture else { return }
        let allow = allowsAutomaticPictureInPicture
        if pip.canStartPictureInPictureAutomaticallyFromInline != allow {
            pip.canStartPictureInPictureAutomaticallyFromInline = allow
        }
    }

    /// The native player is going to PiP (or already is) as the app leaves.
    var continuesInPictureInPicture: Bool {
        if isPictureInPictureActive { return true }
        guard let pip = pictureInPicture else { return false }
        return pip.isPictureInPictureActive
            || (pip.canStartPictureInPictureAutomaticallyFromInline && pip.isPictureInPicturePossible)
    }
}

// MARK: - App lifecycle

/// Decides what active streams do when the app leaves the foreground:
/// - `primary`: continue in PiP, keep playing native audio-only with sound, or
///   take a `.background` hold.
/// - `pinnedAudio`: unmuted native audio slots continue with the screen locked;
///   muted/volume-0 slots take a `.background` hold so they don't burn battery.
/// Also re-evaluates `PlaybackAudioSession` so a backgrounded web primary
/// yields immediately to an exclusive audio session for Lock Screen Now Playing.
@MainActor
final class PlaybackLifecycleObserver: NSObject {
    private weak var center: PlaybackCenter?
    private var backgroundHold: PlaybackHold?
    /// Slots that were actively playing (or intended to play) when the app
    /// entered background, so foregrounding can recover any slot iOS or WebKit
    /// paused without a `.background` hold (e.g. video paused on screen lock
    /// with PiP enabled, or a player interrupted during foreground wake).
    private var pendingForegroundResumeSlotIDs: Set<UUID> = []
    private(set) var isInBackground = false

    init(center: PlaybackCenter) {
        self.center = center
        super.init()
        let notifications = NotificationCenter.default
        notifications.addObserver(
            self, selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        notifications.addObserver(
            self, selector: #selector(didEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        notifications.addObserver(
            self, selector: #selector(willEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
        notifications.addObserver(
            self, selector: #selector(didBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    /// Always adopts the latest active `.background` hold token from
    /// `PlaybackCenter` so replacing a lapsed/dropped background hold
    /// mid-background still releases cleanly on `willEnterForeground`.
    func adoptBackgroundHold(_ hold: PlaybackHold) {
        backgroundHold = hold
    }

    func clearBackgroundHold(ifID id: UUID) {
        if backgroundHold?.id == id {
            backgroundHold = nil
        }
    }

    /// Enrolls a slot that began playing while the app was already in the
    /// background (e.g. via Lock Screen Play) so foreground recovery still
    /// protects it if iOS pauses it before `willEnterForeground`.
    func noteSlotResumedInBackground(_ slotID: UUID) {
        guard isInBackground else { return }
        pendingForegroundResumeSlotIDs.insert(slotID)
    }

    /// Internal (not private) so tests can drive it without posting app-wide notifications.
    @objc func willResignActive() {
        guard let center else { return }
        center.primary?.controller.refreshAutomaticPictureInPicture()
        // While still in the foreground (before iOS locks down background
        // audio-session activation), re-assert active `.playback` when unmuted
        // native audio is active without an audible web primary so external
        // deactivations can never leave the session inactive on backgrounding.
        let state = center.currentAudioSessionState
        if state.hasAudibleNative && !state.hasAudibleWeb {
            center.reconcileAudioSession(force: true)
        }
    }

    /// Internal (not private) so tests can drive it without posting app-wide notifications.
    @objc func didEnterBackground() {
        isInBackground = true
        center?.audioSession.setInBackground(true)
        guard let center, center.hasAnyPlayback else { return }
        pendingForegroundResumeSlotIDs = Set(
            center.allSlots.compactMap { slot in
                (slot.controller.wantsPlayback && !(slot.controller.hasStarted && slot.controller.isPaused))
                    ? slot.id
                    : nil
            }
        )
        backgroundHold = center.holdPlayback(.background) ?? backgroundHold
        playbackCenterLogger.notice(
            "App entered background (primary=\(center.primary?.engineKind.map { String(describing: $0) } ?? "none", privacy: .public), pinned=\(center.pinnedAudio.count), held=\(self.backgroundHold?.slotGenerations.count ?? 0))"
        )
        center.reconcileAudioSession()
        center.refreshNowPlaying()
    }

    @objc func willEnterForeground() {
        isInBackground = false
        center?.audioSession.setInBackground(false)
        guard let center else { return }
        // Also capture any slot that started playing while in background (e.g.
        // via Lock Screen Play) so `didBecomeActive` can recover it if the
        // foreground transition interrupts it.
        for slot in center.allSlots where slot.engine != nil
            && slot.controller.wantsPlayback
            && !slot.controller.isHeld
            && !slot.controller.isPaused {
            pendingForegroundResumeSlotIDs.insert(slot.id)
        }
        if let hold = backgroundHold {
            backgroundHold = nil
            center.releaseHold(hold)
        }
        resumeUnexpectedlyPausedSlots(in: center)
        center.reconcileAudioSession()
        center.refreshNowPlaying()
    }

    /// Runs after UIKit/WebKit finishes foreground activation: catches any
    /// stream the OS or WebKit paused between `didEnterBackground` and
    /// `didBecomeActive` while respecting user-initiated pauses (`wantsPlayback == false`).
    @objc func didBecomeActive() {
        guard !isInBackground, let center else { return }
        guard !pendingForegroundResumeSlotIDs.isEmpty else { return }
        let resumedAny = resumeUnexpectedlyPausedSlots(in: center)
        pendingForegroundResumeSlotIDs.removeAll()
        if resumedAny {
            center.reconcileAudioSession(force: true)
            center.refreshNowPlaying()
        }
    }

    @discardableResult
    private func resumeUnexpectedlyPausedSlots(in center: PlaybackCenter) -> Bool {
        guard !pendingForegroundResumeSlotIDs.isEmpty else { return false }
        var resumedAny = false
        for slot in center.allSlots where pendingForegroundResumeSlotIDs.contains(slot.id) {
            let controller = slot.controller
            guard slot.engine != nil, controller.wantsPlayback, !controller.isHeld, controller.isPaused else { continue }
            playbackCenterLogger.notice("Recovering paused stream on foreground: @\(slot.channel.channelLoginName, privacy: .public)")
            controller.resume()
            resumedAny = true
        }
        return resumedAny
    }
}
#endif
