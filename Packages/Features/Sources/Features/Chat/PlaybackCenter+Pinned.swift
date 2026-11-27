#if os(iOS)
import Foundation
import Core
import TwitchKit

/// Single snapshot owner for Solo and Mute All so the two modes never clobber
/// each other's saved mute states.
enum AudioFocusMode {
    case none
    case solo(slotID: UUID, savedMutes: [UUID: Bool])
    case mutedAll(savedMutes: [UUID: Bool])
}

/// Outcome of attempting to pin a channel into background audio.
enum PinBackgroundAudioResult: Equatable, Sendable {
    case pinned
    case alreadyPinned
    case atCapacity
    case nativeDisabled
    case nativeFailed
}

extension PlaybackCenter {

    // MARK: - Pin / Unpin / Demote / Promote

    /// Pins `channel` as a headless native `audio_only` background stream.
    @discardableResult
    func pinBackgroundAudio(
        _ channel: ChannelDescriptor,
        title: String,
        profileImageURL: URL?,
        stream: TwitchStream? = nil,
        quality: PlayerQuality = .auto
    ) -> PinBackgroundAudioResult {
        guard PlayerSettings.isNativePlaybackEnabled else { return .nativeDisabled }
        if pinnedChannelIDs.contains(channel.channelId) { return .alreadyPinned }

        if primary?.channel.channelId == channel.channelId {
            return demotePrimaryToPinnedAudio()
        }

        guard pinnedAudio.count < Self.maxPinnedAudioSlots else { return .atCapacity }

        // If the primary stream is currently running in WKWebView, upgrade it
        // to the native engine before starting pinned native audio so WebKit's
        // out-of-process media session doesn't fight AVPlayer or pause streams
        // when returning from the background.
        if let existingPrimary = primary,
           existingPrimary.engineKind == .web,
           !existingPrimary.controller.nativeFailed {
            existingPrimary.promotedToNative = true
            play(
                existingPrimary.channel,
                title: existingPrimary.title,
                profileImageURL: existingPrimary.profileImageURL,
                native: true,
                audioOnly: existingPrimary.audioOnly,
                quality: existingPrimary.lastQuality
            )
        }

        let slot = PlaybackSlot(
            channel: channel,
            title: title,
            profileImageURL: profileImageURL,
            audioOnly: true,
            allowsPictureInPicture: false,
            quality: quality,
            native: true
        )
        if let stream { slot.noteLive(stream) }
        wireSlotCallbacks(slot)

        let mutedByFocus = shouldNewSlotStartMuted(excluding: slot.id)
        slot.controller.startsMuted = mutedByFocus
        slot.controller.wantsPlayback = true
        slot.controller.reset()
        if mutedByFocus {
            recordNewSlotInAudioFocus(slotID: slot.id, unmutedWhenRestored: true)
        }

        inheritActiveCenterHolds(into: slot)

        let request: StreamEngineRequest = .native(
            login: channel.channelLoginName,
            audioOnly: true,
            quality: quality,
            allowsPictureInPicture: false
        )
        let built = makeEngine(request, slot.controller)
        slot.engine = built
        slot.engineKind = built.kind
        slot.engineKey = "\(channel.channelLoginName)|true"

        pinnedAudio.append(slot)
        syncPinnedAudioFlag(for: channel.channelId, isPinned: true)
        playbackCenterLogger.notice("Pinned background audio @\(channel.channelLoginName, privacy: .public) (count=\(self.pinnedAudio.count))")
        reconcileAudioSession()
        refreshNowPlaying()
        schedulePauseUnload(for: slot)
        return .pinned
    }

    /// Demotes the current `primary` stream into `pinnedAudio`.
    @discardableResult
    func demotePrimaryToPinnedAudio() -> PinBackgroundAudioResult {
        guard PlayerSettings.isNativePlaybackEnabled else { return .nativeDisabled }
        guard let slot = primary else { return .nativeFailed }
        guard !slot.controller.nativeFailed else { return .nativeFailed }
        guard pinnedAudio.count < Self.maxPinnedAudioSlots else { return .atCapacity }

        let channel = slot.channel
        let title = slot.title
        let profileImageURL = slot.profileImageURL
        let lastLive = slot.lastLiveStream
        let quality = slot.lastQuality
        let wasNative = slot.engine?.kind == .native
        let wasHeld = slot.controller.isHeld
        let inheritedWantsPlayback: Bool = wasHeld
            ? slot.currentHolds.values.contains { $0.resumeOnRelease }
            : (slot.controller.wantsPlayback && !(slot.controller.hasStarted && slot.controller.isPaused))

        // Clear `primary` BEFORE `setInteractive(false)` so any delayed PiP
        // stop/close delegate callback is ignored by the `primary?.id == slotID` guard.
        primary = nil
        // Never let a future primary slot share a controller that just moved
        // into `pinnedAudio` (`defaultPrimaryController` isolation).
        if slot.controller === defaultPrimaryController {
            defaultPrimaryController = StreamPlayerController()
        }
        slot.engine?.setInteractive(false)
        slot.engine?.view.removeFromSuperview()
        syncPictureInPictureFlags()
        hostRevision += 1

        if wasNative {
            slot.allowsPictureInPicture = false
            slot.audioOnly = true
            slot.promotedToNative = false
            if slot.controller.isMuted, !shouldNewSlotStartMuted(excluding: slot.id) {
                slot.controller.setMuted(false, programmatic: true)
            }
            slot.engine?.setAudioOnly(true, quality: quality)
            pinnedAudio.append(slot)
            syncPinnedAudioFlag(for: channel.channelId, isPinned: true)
            playbackCenterLogger.notice("Demoted native primary → background audio @\(channel.channelLoginName, privacy: .public)")
            reconcileAudioSession()
            refreshNowPlaying()
            schedulePauseUnload(for: slot)
            return .pinned
        }

        // Web primary → preserve any active `.clip`/`.feedPreview` hold tokens
        // across teardown so the replacement headless native slot inherits them.
        let preservedHoldTokens: [(PlaybackHoldReason, PlaybackHold)] = slot.currentHolds.keys.compactMap { reason in
            guard reason == .clip || reason == .feedPreview, let token = activeCenterHolds[reason] else { return nil }
            return (reason, token)
        }
        let oldSlotID = slot.id
        tearDownSlot(slot)
        handleSlotRemovedFromAudioFocus(slotID: oldSlotID)

        let pinnedSlot = PlaybackSlot(
            channel: channel,
            title: title,
            profileImageURL: profileImageURL,
            audioOnly: true,
            allowsPictureInPicture: false,
            quality: quality,
            native: true
        )
        if let lastLive { pinnedSlot.noteLive(lastLive) }
        wireSlotCallbacks(pinnedSlot)

        let mutedByFocus = shouldNewSlotStartMuted(excluding: pinnedSlot.id)
        pinnedSlot.controller.startsMuted = mutedByFocus
        pinnedSlot.controller.wantsPlayback = inheritedWantsPlayback
        pinnedSlot.controller.reset()
        if mutedByFocus {
            recordNewSlotInAudioFocus(slotID: pinnedSlot.id, unmutedWhenRestored: true)
        }

        // Re-register any preserved center holds that lapsed when `slot` was
        // the only member, then inherit all active center holds into `pinnedSlot`.
        for (reason, token) in preservedHoldTokens where activeCenterHolds[reason] == nil {
            activeCenterHolds[reason] = PlaybackHold(id: token.id, reason: reason, slotGenerations: [:])
        }
        inheritActiveCenterHolds(into: pinnedSlot)

        let request: StreamEngineRequest = .native(
            login: channel.channelLoginName,
            audioOnly: true,
            quality: quality,
            allowsPictureInPicture: false
        )
        let built = makeEngine(request, pinnedSlot.controller)
        pinnedSlot.engine = built
        pinnedSlot.engineKind = built.kind
        pinnedSlot.engineKey = "\(channel.channelLoginName)|true"

        pinnedAudio.append(pinnedSlot)
        syncPinnedAudioFlag(for: channel.channelId, isPinned: true)
        playbackCenterLogger.notice("Demoted web primary → background audio @\(channel.channelLoginName, privacy: .public)")
        reconcileAudioSession()
        refreshNowPlaying()
        schedulePauseUnload(for: pinnedSlot)
        return .pinned
    }

    /// Promotes a `pinnedAudio` channel into `primary` (typically video).
    ///
    /// Stops any existing `primary` FIRST (while the target slot is still in
    /// `pinnedAudio` / `allSlots`) so if the old primary was soloed, the
    /// promoted target receives its restored mute state before taking over.
    func promotePinnedToPrimary(
        channelId: String,
        audioOnly: Bool = false,
        quality: PlayerQuality = .auto,
        title: String? = nil,
        profileImageURL: URL?? = nil,
        syncGlobalDisplayPreferences: Bool = false
    ) {
        guard pinnedAudio.contains(where: { $0.channel.channelId == channelId }) else { return }

        // Stop old primary while target is still in `allSlots` so Solo restoration includes it.
        if primary != nil {
            stopPrimary()
        }

        guard let idx = pinnedAudio.firstIndex(where: { $0.channel.channelId == channelId }) else { return }
        let slot = pinnedAudio.remove(at: idx)
        syncPinnedAudioFlag(for: channelId, isPinned: false)

        if let title { slot.title = title }
        if let profileImageURL { slot.profileImageURL = profileImageURL }
        slot.allowsPictureInPicture = true
        slot.audioOnly = audioOnly
        slot.lastQuality = quality
        slot.lastNative = true
        slot.promotedToNative = true
        primary = slot

        if syncGlobalDisplayPreferences {
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: StreamHeaderView.expandedKey) != true {
                defaults.set(true, forKey: StreamHeaderView.expandedKey)
            }
            if defaults.bool(forKey: PlayerSettings.audioOnlyKey) != audioOnly {
                defaults.set(audioOnly, forKey: PlayerSettings.audioOnlyKey)
            }
        }

        if let engine = slot.engine {
            engine.setInteractive(true)
            engine.setAudioOnly(audioOnly, quality: quality)
        } else {
            slot.controller.wantsPlayback = true
            slot.controller.startsMuted = slot.controller.isMuted
            slot.controller.reset()
            let request: StreamEngineRequest = .native(
                login: slot.channel.channelLoginName,
                audioOnly: audioOnly,
                quality: quality,
                allowsPictureInPicture: true
            )
            let built = makeEngine(request, slot.controller)
            slot.engine = built
            slot.engineKind = built.kind
            slot.engineKey = "\(slot.channel.channelLoginName)|true"
        }

        activeHostID = hostStack.last
        hostRevision += 1
        playbackCenterLogger.notice("Promoted background audio → primary @\(slot.channel.channelLoginName, privacy: .public)")
        syncPictureInPictureFlags()
        reconcileAudioSession()
        refreshNowPlaying()
        schedulePauseUnload(for: slot)
    }

    /// Stops and removes a single pinned background audio stream.
    func unpinBackgroundAudio(channelId: String) {
        guard let idx = pinnedAudio.firstIndex(where: { $0.channel.channelId == channelId }) else { return }
        let slot = pinnedAudio.remove(at: idx)
        tearDownSlot(slot)
        syncPinnedAudioFlag(for: channelId, isPinned: false)
        handleSlotRemovedFromAudioFocus(slotID: slot.id)
        playbackCenterLogger.notice("Unpinned background audio @\(slot.channel.channelLoginName, privacy: .public) (remaining=\(self.pinnedAudio.count))")
        reconcileAudioSession()
        refreshNowPlaying()
    }

    /// Stops and removes every pinned background audio stream, leaving `primary` intact.
    func stopAllPinnedAudio() {
        guard !pinnedAudio.isEmpty else { return }
        let oldPinned = pinnedAudio
        pinnedAudio.removeAll()
        for slot in oldPinned {
            tearDownSlot(slot)
            syncPinnedAudioFlag(for: slot.channel.channelId, isPinned: false)
            handleSlotRemovedFromAudioFocus(slotID: slot.id)
        }
        reconcileAudioSession()
        refreshNowPlaying()
    }

    /// Stops every stream represented by the unified bottom audio dock:
    /// all `pinnedAudio` slots AND `primary` if `primary` is in native
    /// audio-only mode. Preserves any separate primary video tile.
    func stopAudioDockStreams() {
        let primaryInDock = primary.map { $0.audioOnly && !$0.controller.nativeFailed } ?? false
        stopAllPinnedAudio()
        if primaryInDock {
            stopPrimary()
        }
    }

    // MARK: - Solo & Mute All (single snapshot owner)

    func toggleSolo(slotID: UUID) {
        guard let target = slot(withID: slotID) else { return }
        switch audioFocusMode {
        case .solo(let currentID, let savedMutes) where currentID == slotID:
            audioFocusMode = .none
            soloSlotID = nil
            isMutedAll = false
            for slot in allSlots {
                if let saved = savedMutes[slot.id] {
                    slot.controller.setMuted(saved, programmatic: true)
                }
            }

        case .solo(_, let savedMutes), .mutedAll(let savedMutes):
            audioFocusMode = .solo(slotID: slotID, savedMutes: savedMutes)
            soloSlotID = slotID
            isMutedAll = false
            applySoloState(target: target)

        case .none:
            var snapshot: [UUID: Bool] = [:]
            for slot in allSlots {
                snapshot[slot.id] = slot.controller.isMuted
            }
            audioFocusMode = .solo(slotID: slotID, savedMutes: snapshot)
            soloSlotID = slotID
            isMutedAll = false
            applySoloState(target: target)
        }
        reconcileAudioSession()
        reconcileBackgroundHoldsIfInBackground()
    }

    func toggleMuteAll() {
        switch audioFocusMode {
        case .mutedAll(let savedMutes):
            audioFocusMode = .none
            isMutedAll = false
            soloSlotID = nil
            for slot in allSlots {
                if let saved = savedMutes[slot.id] {
                    slot.controller.setMuted(saved, programmatic: true)
                }
            }

        case .solo(_, let savedMutes):
            audioFocusMode = .mutedAll(savedMutes: savedMutes)
            isMutedAll = true
            soloSlotID = nil
            for slot in allSlots {
                slot.controller.setMuted(true, programmatic: true)
            }

        case .none:
            var snapshot: [UUID: Bool] = [:]
            for slot in allSlots {
                snapshot[slot.id] = slot.controller.isMuted
            }
            audioFocusMode = .mutedAll(savedMutes: snapshot)
            isMutedAll = true
            soloSlotID = nil
            for slot in allSlots {
                slot.controller.setMuted(true, programmatic: true)
            }
        }
        reconcileAudioSession()
        reconcileBackgroundHoldsIfInBackground()
    }

    private func applySoloState(target: PlaybackSlot) {
        for slot in allSlots {
            if slot.id == target.id {
                if slot.controller.volume == 0 {
                    slot.controller.setVolume(1.0, programmatic: true)
                }
                slot.controller.setMuted(false, programmatic: true)
            } else {
                slot.controller.setMuted(true, programmatic: true)
            }
        }
    }

    func shouldNewSlotStartMuted(excluding slotID: UUID) -> Bool {
        switch audioFocusMode {
        case .none: return false
        case .mutedAll: return true
        case .solo(let soloID, _): return soloID != slotID
        }
    }

    func recordNewSlotInAudioFocus(slotID: UUID, unmutedWhenRestored: Bool) {
        switch audioFocusMode {
        case .none:
            break
        case .solo(let soloID, var savedMutes):
            savedMutes[slotID] = !unmutedWhenRestored
            audioFocusMode = .solo(slotID: soloID, savedMutes: savedMutes)
        case .mutedAll(var savedMutes):
            savedMutes[slotID] = !unmutedWhenRestored
            audioFocusMode = .mutedAll(savedMutes: savedMutes)
        }
    }

    func handleSlotRemovedFromAudioFocus(slotID: UUID) {
        switch audioFocusMode {
        case .none:
            break
        case .solo(let soloID, let savedMutes):
            if soloID == slotID {
                audioFocusMode = .none
                soloSlotID = nil
                isMutedAll = false
                for slot in allSlots {
                    if let saved = savedMutes[slot.id] {
                        slot.controller.setMuted(saved, programmatic: true)
                    }
                }
            } else {
                var trimmed = savedMutes
                trimmed[slotID] = nil
                audioFocusMode = .solo(slotID: soloID, savedMutes: trimmed)
            }
        case .mutedAll(var savedMutes):
            savedMutes[slotID] = nil
            if allSlots.isEmpty {
                audioFocusMode = .none
                isMutedAll = false
            } else {
                audioFocusMode = .mutedAll(savedMutes: savedMutes)
            }
        }
    }

    /// Called when any slot's mute/volume changes. User-initiated unmutes exit
    /// active Solo / Mute All while preserving every slot's current state.
    func handleAudioStateChange(slotID: UUID, userInitiatedUnmute: Bool) {
        if userInitiatedUnmute {
            switch audioFocusMode {
            case .none:
                break
            case .solo, .mutedAll:
                audioFocusMode = .none
                soloSlotID = nil
                isMutedAll = false
            }
        }
        reconcileAudioSession()
        refreshNowPlaying()
        reconcileBackgroundHoldsIfInBackground()
    }

    // MARK: - Pinned offline reconciliation

    /// Checks fresh foreground status readings for every pinned channel.
    /// Missing entries or unpolled channels are ignored; only two distinct
    /// `fetchedAt` offline readings confirm that a pinned channel went offline
    /// (works even for unloaded slots or pins created without `TwitchStream`).
    func reconcilePinnedStatuses(statusStore: ChannelStatusStore, follows: FollowsStore?) {
        guard !pinnedAudio.isEmpty else { return }
        var toUnpin: [String] = []
        for slot in pinnedAudio {
            let channelId = slot.channel.channelId
            guard let status = statusStore.statuses[channelId],
                  status.fetchedAt != .distantPast
            else { continue }

            if let live = statusStore.liveStream(for: channelId, follows: follows) {
                slot.noteLive(live)
                if slot.title != live.title { slot.title = live.title }
            } else if slot.pinnedOfflineReadingConfirmed(at: status.fetchedAt) {
                toUnpin.append(channelId)
            }
        }
        for channelId in toUnpin {
            unpinBackgroundAudio(channelId: channelId)
        }
    }
}
#endif
