#if os(iOS)
import Foundation
import Core
import TwitchKit

/// One active stream slot owned by `PlaybackCenter` — either the single
/// `primary` stage slot (video, landscape, PiP, web fallback, mini-player
/// video tile) or one of the up to 3 headless `pinnedAudio` background slots.
@MainActor
@Observable
final class PlaybackSlot: Identifiable {
    let id: UUID
    var channel: ChannelDescriptor
    var title: String
    var profileImageURL: URL?
    var audioOnly: Bool
    /// True for `primary` (interactive video + PiP eligible); false for
    /// headless `pinnedAudio` slots.
    var allowsPictureInPicture: Bool
    /// Observed engine kind so SwiftUI surfaces (e.g. `AudioMixerSheet`) can
    /// reactively show/hide native-only volume sliders without reading
    /// `@ObservationIgnored avPlayer`.
    var engineKind: StreamEngineKind?
    /// Last live `TwitchStream` kept through a single poll that left this
    /// channel out so the header/stage doesn't flash offline prematurely.
    /// Observed on `primary` (`PlaybackCenter.stream(for:live:)`).
    private(set) var lingeringStream: TwitchStream?

    let controller: StreamPlayerController
    @ObservationIgnored var engine: (any StreamEngine)?
    @ObservationIgnored var engineKey: String?

    @ObservationIgnored var firstOfflineReadingAt: Date?
    /// Independent two-reading offline tracker for pinned background slots so
    /// even unloaded slots or pins without `lastLiveStream` require two distinct
    /// `fetchedAt` offline readings before being auto-unpinned.
    @ObservationIgnored var pinnedFirstOfflineReadingAt: Date?
    @ObservationIgnored var lastLiveStream: TwitchStream?
    @ObservationIgnored var pauseUnloadTask: Task<Void, Never>?

    @ObservationIgnored var lastQuality: PlayerQuality
    @ObservationIgnored var lastNative: Bool
    /// True when this slot was explicitly promoted from `pinnedAudio` to
    /// `primary`: keeps it on `NativeStreamEngine` even if the user's global
    /// `Native Video Player` preference is off, until channel change or
    /// native failure.
    @ObservationIgnored var promotedToNative = false

    /// Bumped when WHAT plays in this slot changes (different channel or stop).
    /// Same-channel rebuilds, audio-only swaps, promote, and demote keep it.
    @ObservationIgnored var generation = 0
    /// Outstanding holds on this slot by reason.
    @ObservationIgnored var currentHolds: [PlaybackHoldReason: SlotHold] = [:]
    /// Whether this slot was playing immediately before an OS audio
    /// interruption began and should resume if `.shouldResume` arrives.
    @ObservationIgnored var resumesAfterInterruption = false

    init(
        id: UUID = UUID(),
        channel: ChannelDescriptor,
        title: String,
        profileImageURL: URL?,
        audioOnly: Bool,
        allowsPictureInPicture: Bool,
        quality: PlayerQuality,
        native: Bool,
        controller: StreamPlayerController = StreamPlayerController()
    ) {
        self.id = id
        self.channel = channel
        self.title = title
        self.profileImageURL = profileImageURL
        self.audioOnly = audioOnly
        self.allowsPictureInPicture = allowsPictureInPicture
        self.lastQuality = quality
        self.lastNative = native
        self.controller = controller
    }

    /// True while this slot is producing audible sound on a native player.
    var isAudibleNative: Bool {
        engineKind == .native && engine != nil && controller.isEffectivelyAudible
    }

    /// True while this native slot wants exclusive audio-session focus
    /// (unmuted with volume > 0 and an active engine). Intentionally ignores
    /// `isPaused` and `isHeld` so Lock Screen pause, screen-lock video pause,
    /// and background/foreground transitions never churn `AVAudioSession`
    /// between exclusive and `.mixWithOthers`.
    var wantsExclusiveNativeAudio: Bool {
        engineKind == .native && engine != nil && !controller.isMuted && controller.volume > 0
    }

    /// True while this slot has an active (non-unloaded) native engine.
    var hasActiveNativeEngine: Bool {
        engineKind == .native && engine != nil
    }

    /// True while this slot is playing unmuted video on `WebStreamEngine`.
    var isAudibleWeb: Bool {
        engineKind == .web && engine != nil && !controller.isMuted && !controller.isPaused && !controller.isHeld
    }

    // MARK: - Offline softening

    func noteWentOffline(_ stream: TwitchStream) {
        guard engine != nil, channel.channelId == stream.userId else { return }
        if lingeringStream != stream { lingeringStream = stream }
    }

    func noteLive(_ stream: TwitchStream) {
        guard channel.channelId == stream.userId else { return }
        lastLiveStream = stream
        pinnedFirstOfflineReadingAt = nil
        clearLingeringStream()
    }

    func offlineReadingConfirmed(at fetchedAt: Date) -> Bool {
        if lingeringStream == nil, let lastLiveStream { noteWentOffline(lastLiveStream) }
        guard lingeringStream != nil else { return true }
        guard let first = firstOfflineReadingAt else {
            firstOfflineReadingAt = fetchedAt
            return false
        }
        return fetchedAt != first
    }

    /// Two-reading offline confirmation for pinned background slots,
    /// independent of `lingeringStream` and `engine` (handles unloaded slots
    /// and slots pinned with `stream: nil`).
    func pinnedOfflineReadingConfirmed(at fetchedAt: Date) -> Bool {
        guard let first = pinnedFirstOfflineReadingAt else {
            pinnedFirstOfflineReadingAt = fetchedAt
            return false
        }
        return fetchedAt != first
    }

    func clearLingeringStream() {
        firstOfflineReadingAt = nil
        if lingeringStream != nil { lingeringStream = nil }
    }

    // MARK: - Per-slot holds

    func acquireHold(_ reason: PlaybackHoldReason, holdID: UUID) -> SlotHold? {
        guard currentHolds[reason] == nil else { return nil }
        let resumeOnRelease = currentHolds.isEmpty
            ? PlaybackCenter.resumesOnRelease(controller)
            : currentHolds.values.contains { $0.resumeOnRelease }
        let hold = SlotHold(
            id: holdID,
            reason: reason,
            generation: generation,
            resumeOnRelease: resumeOnRelease
        )
        currentHolds[reason] = hold
        controller.beginHold(reason)
        return hold
    }

    func releaseHold(_ reason: PlaybackHoldReason, holdID: UUID, expectedGeneration: Int) {
        guard let existing = currentHolds[reason],
              existing.id == holdID,
              existing.generation == expectedGeneration,
              generation == expectedGeneration
        else { return }
        currentHolds[reason] = nil
        controller.endHold(reason, resume: existing.resumeOnRelease && controller.wantsPlayback)
    }

    func dropHoldWithoutResuming(_ reason: PlaybackHoldReason) {
        guard currentHolds[reason] != nil else { return }
        currentHolds[reason] = nil
        controller.endHold(reason, resume: false)
    }

    func advanceGeneration() {
        generation += 1
        currentHolds.removeAll()
        controller.endAllHolds()
    }
}
#endif
