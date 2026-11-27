#if os(iOS)
import Foundation

extension PlaybackCenter {

    // MARK: - Multi-slot Holds

    /// Pause active streams for `reason` and return a token that hands them
    /// back on `releaseHold`.
    ///
    /// - `.clip` & `.feedPreview`: hold EVERY active slot (`primary` + `pinnedAudio`),
    ///   recording each slot's own `resumesOnRelease` so manual pauses are never undone.
    /// - `.background`: holds only slots that cannot continue in background (primary
    ///   video without PiP, and muted/volume-0 pinned slots); audible pinned audio
    ///   slots keep playing with the screen locked.
    func holdPlayback(_ reason: PlaybackHoldReason) -> PlaybackHold? {
        guard hasAnyPlayback, activeCenterHolds[reason] == nil else { return nil }
        let targets = slotsEligibleForHold(reason)
        guard !targets.isEmpty else { return nil }

        let holdID = UUID()
        var generations: [UUID: Int] = [:]
        for slot in targets {
            if slot.acquireHold(reason, holdID: holdID) != nil {
                generations[slot.id] = slot.generation
            }
        }
        guard !generations.isEmpty else { return nil }

        let token = PlaybackHold(id: holdID, reason: reason, slotGenerations: generations)
        activeCenterHolds[reason] = token
        reconcileAudioSession()
        return token
    }

    func releaseHold(_ hold: PlaybackHold) {
        guard let active = activeCenterHolds[hold.reason], active.id == hold.id else { return }
        activeCenterHolds[hold.reason] = nil

        for (slotID, expectedGeneration) in active.slotGenerations {
            guard let slot = slot(withID: slotID) else { continue }
            slot.releaseHold(hold.reason, holdID: hold.id, expectedGeneration: expectedGeneration)
            schedulePauseUnload(for: slot)
        }
        reconcileAudioSession()
        refreshNowPlaying()
    }

    /// Removes `slotID` from any active center holds when that slot stops or
    /// changes channel; drops the center hold record once no slot references it.
    func lapseCenterHolds(forSlotID slotID: UUID) {
        for (reason, var hold) in activeCenterHolds where hold.slotGenerations[slotID] != nil {
            hold.slotGenerations[slotID] = nil
            activeCenterHolds[reason] = hold.slotGenerations.isEmpty ? nil : hold
        }
    }

    /// Any new slot created while `.clip` or `.feedPreview` is active inherits
    /// the hold so it cannot start playing behind a clip or unmuted Home preview.
    func inheritActiveCenterHolds(into slot: PlaybackSlot) {
        for (reason, var hold) in activeCenterHolds {
            guard reason == .clip || reason == .feedPreview || shouldHoldInBackground(slot) else { continue }
            if slot.acquireHold(reason, holdID: hold.id) != nil {
                hold.slotGenerations[slot.id] = slot.generation
                activeCenterHolds[reason] = hold
            }
        }
    }

    /// Dynamically reconciles `.background` holds across all slots (including
    /// primary audio-only and pinned slots) when mute/volume/Solo changes while
    /// the app is already in the background.
    func reconcileBackgroundHoldsIfInBackground() {
        guard lifecycle?.isInBackground == true else { return }
        for slot in allSlots {
            let needsHold = shouldHoldInBackground(slot)
            if needsHold, slot.currentHolds[.background] == nil {
                if var existing = activeCenterHolds[.background] {
                    if slot.acquireHold(.background, holdID: existing.id) != nil {
                        existing.slotGenerations[slot.id] = slot.generation
                        activeCenterHolds[.background] = existing
                        lifecycle?.adoptBackgroundHold(existing)
                    }
                } else {
                    let holdID = UUID()
                    if slot.acquireHold(.background, holdID: holdID) != nil {
                        let token = PlaybackHold(
                            id: holdID,
                            reason: .background,
                            slotGenerations: [slot.id: slot.generation]
                        )
                        activeCenterHolds[.background] = token
                        lifecycle?.adoptBackgroundHold(token)
                    }
                }
            } else if !needsHold, let existing = activeCenterHolds[.background],
                      let expectedGen = existing.slotGenerations[slot.id] {
                slot.releaseHold(.background, holdID: existing.id, expectedGeneration: expectedGen)
                var updated = existing
                updated.slotGenerations[slot.id] = nil
                if updated.slotGenerations.isEmpty {
                    activeCenterHolds[.background] = nil
                    lifecycle?.clearBackgroundHold(ifID: existing.id)
                } else {
                    activeCenterHolds[.background] = updated
                    lifecycle?.adoptBackgroundHold(updated)
                }
            }
        }
    }

    /// Whether a hold taken now should resume `controller` on release.
    static func resumesOnRelease(_ controller: StreamPlayerController) -> Bool {
        controller.wantsPlayback && !(controller.hasStarted && controller.isPaused)
    }

    /// PiP started while a `.background` hold is out on `primary`: drop the
    /// primary slot's background hold without resuming so PiP owns playback.
    func yieldBackgroundHoldToPictureInPicture(slotID: UUID) {
        guard let slot = primary, slot.id == slotID,
              slot.controller.isPictureInPictureActive,
              slot.currentHolds[.background] != nil
        else { return }
        slot.dropHoldWithoutResuming(.background)
        if var existing = activeCenterHolds[.background] {
            existing.slotGenerations[slotID] = nil
            activeCenterHolds[.background] = existing.slotGenerations.isEmpty ? nil : existing
        }
    }

    private func slotsEligibleForHold(_ reason: PlaybackHoldReason) -> [PlaybackSlot] {
        switch reason {
        case .clip, .feedPreview:
            return allSlots
        case .background:
            return allSlots.filter { shouldHoldInBackground($0) }
        }
    }

    func shouldHoldInBackground(_ slot: PlaybackSlot) -> Bool {
        let controller = slot.controller
        guard controller.wantsPlayback else { return false }
        let heldPaused = controller.isHeld

        // Pinned background audio slots continue in background whenever audible
        // (unmuted with volume > 0); muted pinned slots pause so they don't burn
        // data/battery silently.
        if primary?.id != slot.id {
            return controller.isMuted || controller.volume == 0
        }

        // Primary slot rules (identical to single-stream behavior):
        if slot.engine?.kind == .native {
            if slot.audioOnly, !controller.nativeFailed, !controller.isMuted, controller.volume > 0 {
                return false
            }
            if controller.isPictureInPictureActive { return false }
            if !heldPaused, controller.continuesInPictureInPicture { return false }
            return true
        } else {
            if controller.isPictureInPictureActive
                || (!heldPaused && controller.allowsAutomaticPictureInPicture) {
                return false
            }
            return true
        }
    }
}
#endif
