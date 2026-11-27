#if os(iOS)
import Testing
import Foundation
import AVFoundation
import Observation
import os
import Core
import TwitchKit
@testable import Features

@MainActor
@Suite("Multi-audio pinned background streams")
struct PlaybackCenterPinnedTests {
    static let chA = ChannelDescriptor(channelId: "1", channelLoginName: "alpha", channelDisplayName: "Alpha", profileImageURL: nil)
    static let chB = ChannelDescriptor(channelId: "2", channelLoginName: "beta", channelDisplayName: "Beta", profileImageURL: nil)
    static let chC = ChannelDescriptor(channelId: "3", channelLoginName: "gamma", channelDisplayName: "Gamma", profileImageURL: nil)
    static let chD = ChannelDescriptor(channelId: "4", channelLoginName: "delta", channelDisplayName: "Delta", profileImageURL: nil)
    static let chE = ChannelDescriptor(channelId: "5", channelLoginName: "epsilon", channelDisplayName: "Epsilon", profileImageURL: nil)

    init() {
        // Ensure native playback is enabled regardless of other suites' UserDefaults mutations.
        UserDefaults.standard.set(false, forKey: PlayerSettings.nativePlaybackDisabledKey)
    }

    private func stream(userId: String, login: String, title: String = "Live") throws -> TwitchStream {
        let json = """
        {"id":"s-\(userId)","userId":"\(userId)","userLogin":"\(login)","userName":"\(login)","gameId":"1","gameName":"Just Chatting",\
        "type":"live","title":"\(title)","tags":[],"viewerCount":100,"startedAt":0,"language":"en",\
        "thumbnailUrl":"https://example.com/{width}x{height}.jpg","isMature":false}
        """
        return try JSONDecoder().decode(TwitchStream.self, from: Data(json.utf8))
    }

    // MARK: - Pinning, capacity, headless PiP prohibition

    @Test("Pins up to 3 headless native audio streams and rejects a 4th without dropping existing slots")
    func pinCapacityAndHeadlessFlag() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        #expect(center.pinBackgroundAudio(Self.chA, title: "A", profileImageURL: nil) == .pinned)
        #expect(center.pinBackgroundAudio(Self.chA, title: "A", profileImageURL: nil) == .alreadyPinned)
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        #expect(center.pinBackgroundAudio(Self.chC, title: "C", profileImageURL: nil) == .pinned)
        #expect(center.pinBackgroundAudio(Self.chD, title: "D", profileImageURL: nil) == .atCapacity)

        #expect(center.pinnedAudio.count == 3)
        #expect(engines.built.count == 3)
        for engine in engines.built {
            #expect(engine.kind == .native)
            #expect(!engine.allowsPictureInPicture)
        }
        #expect(!center.hasPrimary)
        #expect(center.hasAnyPlayback)
        #expect(!center.holdsScreenAwake)
    }

    // MARK: - Demote, controller isolation (B1), PiP close isolation (B2)

    @Test("Demoting native primary gives the next primary an independent controller so neither clobbers the other")
    func demoteNativePrimaryThenPlayAnotherChannel() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: false, quality: .p720)
        let originalEngine = engines.built.first
        let controllerA = center.controller

        #expect(center.pinBackgroundAudio(Self.chA, title: "A", profileImageURL: nil) == .pinned)
        #expect(center.primary == nil)
        #expect(center.pinnedAudio.count == 1)
        #expect(originalEngine?.teardownCount == 0)
        #expect(originalEngine?.interactiveChanges == [false])
        #expect(originalEngine?.audioOnlyChanges.last?.audioOnly == true)

        // Calling stopPrimary when idle must NOT reset the demoted pinned slot's controller.
        controllerA.setMuted(true)
        center.stopPrimary()
        #expect(controllerA.isMuted)

        // Starting channel B in primary must allocate a distinct controller.
        center.play(Self.chB, title: "B", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        let controllerB = center.controller
        #expect(controllerA !== controllerB)

        // Stream ended on pinned A unpins only A; primary B stays intact.
        controllerA.onStreamEnded?()
        #expect(center.pinnedAudio.isEmpty)
        #expect(center.isPlaying(Self.chB.channelId))
    }

    @Test("Demoting during active PiP does not swallow a subsequent primary's real PiP close")
    func demoteDuringPiPPreservesNextPrimaryPiPClose() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        var pipClosedCount = 0
        center.onPictureInPictureClosed = { pipClosedCount += 1 }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        let controllerA = center.controller
        controllerA.pictureInPictureDidStart()
        #expect(center.demotePrimaryToPinnedAudio() == .pinned)
        // Even if a delayed PiP stop arrives from A, it must not fire onPictureInPictureClosed.
        controllerA.pictureInPictureDidStop()
        #expect(pipClosedCount == 0)

        // Start primary B, enter PiP, then close PiP: callback MUST fire.
        center.play(Self.chB, title: "B", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        center.controller.pictureInPictureDidStart()
        center.controller.pictureInPictureDidStop()
        #expect(pipClosedCount == 1)
    }

    @Test("Demoting a web primary while held preserves hold-resume intent and resumes when the hold ends")
    func demoteWebPrimaryWhileHeldResumesOnRelease() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: false, audioOnly: false, quality: .auto)
        center.controller.noteEngineReady(paused: false)
        center.controller.noteDidPlay()

        let clipHold = center.holdPlayback(.clip)
        #expect(clipHold != nil)
        // Simulate the web engine reporting paused because of the clip hold.
        center.controller.update(\.isPaused, to: true)

        #expect(center.demotePrimaryToPinnedAudio() == .pinned)
        #expect(center.primary == nil)
        #expect(engines.built[0].teardownCount == 1)
        let demotedSlot = center.pinnedSlot(for: Self.chA.channelId)!
        #expect(demotedSlot.engineKind == .native)
        #expect(demotedSlot.controller.holds.contains(.clip))
        #expect(demotedSlot.controller.wantsPlayback)

        if let clipHold { center.releaseHold(clipHold) }
        #expect(!demotedSlot.controller.isHeld)
        #expect(demotedSlot.controller.startsPlaying)
    }

    // MARK: - Promotion

    @Test("Promoting a pinned slot reuses its engine, restores interactivity, restores Solo mutes, and stays native")
    func promotePinnedToPrimaryAndSoloRestore() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: false, audioOnly: false, quality: .auto)
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        let slotA = center.primary!
        let slotB = center.pinnedSlot(for: Self.chB.channelId)!
        let pinnedEngine = engines.built.last

        // Solo primary A (so B is muted by Solo).
        center.toggleSolo(slotID: slotA.id)
        #expect(slotB.controller.isMuted)

        // Promote B while A is soloed: stopping A must restore B's unmuted state!
        center.promotePinnedToPrimary(channelId: Self.chB.channelId, audioOnly: false, quality: .p720)
        #expect(!center.isPinnedAudio(Self.chB.channelId))
        #expect(center.isPlaying(Self.chB.channelId))
        #expect(!slotB.controller.isMuted)
        #expect(center.soloSlotID == nil)
        #expect(pinnedEngine?.teardownCount == 0)
        #expect(pinnedEngine?.interactiveChanges == [true])
        #expect(pinnedEngine?.audioOnlyChanges.last?.audioOnly == false)
        #expect(center.primary?.promotedToNative == true)

        // Header re-syncing with global `prefersNativePlayer == false` must NOT rebuild as web.
        let countBefore = engines.built.count
        center.play(Self.chB, title: "B", profileImageURL: nil, native: false, audioOnly: false, quality: .p720)
        #expect(engines.built.count == countBefore)
        #expect(center.engine?.kind == .native)
    }

    @Test("Promoting a pinned slot unloaded after a long pause rebuilds it directly in video mode")
    func promoteUnloadedPinnedSlot() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        #expect(center.pinBackgroundAudio(Self.chA, title: "A", profileImageURL: nil) == .pinned)
        let slotA = center.pinnedSlot(for: Self.chA.channelId)!
        slotA.controller.togglePlay()
        center.unloadAfterLongPause(slotID: slotA.id)
        #expect(slotA.engine == nil)

        center.promotePinnedToPrimary(channelId: Self.chA.channelId, audioOnly: false, quality: .p1080)
        #expect(center.isPlaying(Self.chA.channelId))
        #expect(center.engine != nil)
        #expect(engines.built.last?.allowsPictureInPicture == true)
        #expect(slotA.controller.wantsPlayback)
    }

    @Test("Pinning a channel whose native engine failed is refused")
    func pinRefusedWhenNativeFailed() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        center.fallBackToWeb(quality: .auto)
        #expect(center.controller.nativeFailed)
        #expect(center.demotePrimaryToPinnedAudio() == .nativeFailed)
        #expect(center.pinnedAudio.isEmpty)
    }

    // MARK: - Stop semantics

    @Test("stopPrimary preserves pinned audio; stopAudioDockStreams preserves primary video; stopAll clears everything")
    func stopSemantics() {
        let engines = FakeStreamEngines()
        let center = engines.center()

        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)

        center.stopAudioDockStreams()
        #expect(center.pinnedAudio.isEmpty)
        #expect(center.isPlaying(Self.chA.channelId))

        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        center.stopPrimary()
        #expect(center.primary == nil)
        #expect(center.pinnedAudio.count == 1)

        center.play(Self.chC, title: "C", profileImageURL: nil, native: true, audioOnly: true, quality: .auto)
        #expect(center.audioDockSlots.count == 2)
        center.stopAudioDockStreams()
        #expect(!center.hasAnyPlayback)

        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        center.toggleMuteAll()
        center.stopAll()
        #expect(!center.hasAnyPlayback)
        #expect(!center.isMutedAll)
        #expect(center.soloSlotID == nil)
    }

    // MARK: - Solo, Mute All, Web rebuild focus, Volume & JS syntax

    @Test("Solo and Mute All preserve snapshots; lowering volume does not exit Solo; web audio-only rebuild respects Solo")
    func soloMuteAllAndVolumeBehavior() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: false, audioOnly: false, quality: .auto)
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        #expect(center.pinBackgroundAudio(Self.chC, title: "C", profileImageURL: nil) == .pinned)

        let slotA = center.primary!
        let slotB = center.pinnedSlot(for: Self.chB.channelId)!
        let slotC = center.pinnedSlot(for: Self.chC.channelId)!
        slotC.controller.setMuted(true, programmatic: false)

        // Solo B → A & C muted.
        center.toggleSolo(slotID: slotB.id)
        #expect(center.soloSlotID == slotB.id)
        #expect(slotA.controller.isMuted && !slotB.controller.isMuted && slotC.controller.isMuted)

        // Lowering B's volume from 100% → 50% must NOT exit Solo!
        slotB.controller.setVolume(0.5, programmatic: false)
        #expect(center.soloSlotID == slotB.id)

        // Switching web primary A to native Audio Only while B is soloed keeps A muted!
        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: true, quality: .auto)
        #expect(slotA.controller.isMuted)
        #expect(center.soloSlotID == slotB.id)

        // Pin D during Solo → D starts muted.
        #expect(center.pinBackgroundAudio(Self.chD, title: "D", profileImageURL: nil) == .pinned)
        let slotD = center.pinnedSlot(for: Self.chD.channelId)!
        #expect(slotD.controller.isMuted)

        // Solo → Mute All → Unmute All restores original snapshot (A/B/D unmuted, C muted).
        center.toggleMuteAll()
        #expect(center.isMutedAll && center.soloSlotID == nil)
        center.toggleMuteAll()
        #expect(!center.isMutedAll)
        #expect(!slotA.controller.isMuted && !slotB.controller.isMuted && slotC.controller.isMuted && !slotD.controller.isMuted)

        // Manual unmute exits Solo cleanly.
        center.toggleSolo(slotID: slotA.id)
        slotC.controller.setMuted(false, programmatic: false)
        #expect(center.soloSlotID == nil)
        #expect(!slotC.controller.isMuted)

        // Verify web JS command builder produces a single valid call (no trailing `()`).
        #expect(StreamPlayerController.webCommandJS("setMuted", arguments: "true") == "window.chattrPlayer && window.chattrPlayer.setMuted(true)")
        #expect(StreamPlayerController.webCommandJS("pause") == "window.chattrPlayer && window.chattrPlayer.pause()")
    }

    // MARK: - Aggregate Audio Session Driver (FIFO Ordering & Home Preview Coexistence)

    @Test("PlaybackAudioSession serializes actions in FIFO order and preserves pinned audio when Home preview stops")
    func audioSessionDriverFIFOAndHomePreview() async {
        let driver = RecordingAudioSessionDriver()
        let session = PlaybackAudioSession(driver: driver)

        // 1. Pinned native audio active & audible → exclusive.
        await session.updateClient(
            .playback,
            state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: true, hasAudibleWeb: false)
        )
        // 2. Home preview starts muted → still exclusive.
        await session.updateClient(
            .homePreview,
            state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: false, hasAudibleWeb: false)
        )
        // 3. Home preview stops → must NOT deactivate because pinned playback is still active!
        await session.updateClient(.homePreview, state: .inactive)
        // 4. Web primary becomes unmuted alongside pinned audio → flips to mixable.
        await session.updateClient(
            .playback,
            state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: true, hasAudibleWeb: true)
        )
        // 5. App backgrounds (web primary held → hasAudibleWeb = false) with force=true → exclusive.
        await session.updateClient(
            .playback,
            state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: true, hasAudibleWeb: false),
            force: true
        )
        // 6. All playback stops → deactivate.
        await session.updateClient(.playback, state: .inactive)

        let expected: [(AudioSessionAction, Bool)] = [
            (.activate(mixable: false), false),
            (.activate(mixable: false), false),
            (.activate(mixable: false), false),
            (.activate(mixable: true), false),
            (.activate(mixable: false), true),
            (.deactivate, false),
        ]
        let recorded = driver.actions
        #expect(recorded.count == expected.count)
        for (lhs, rhs) in zip(recorded, expected) {
            #expect(lhs.action == rhs.0)
            #expect(lhs.force == rhs.1)
        }
    }

    // MARK: - Multi-slot Holds, Dynamic Background Reconcile, Interruptions & Reset

    @Test("Background holds pause primary video & muted pins, dynamically update on mute/unmute, and release on foreground")
    func backgroundHoldAndDynamicReconcile() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        #expect(center.pinBackgroundAudio(Self.chC, title: "C", profileImageURL: nil) == .pinned)

        let slotA = center.primary!
        let slotB = center.pinnedSlot(for: Self.chB.channelId)!
        let slotC = center.pinnedSlot(for: Self.chC.channelId)!
        slotC.controller.setMuted(true)

        center.lifecycle?.didEnterBackground()
        #expect(slotA.controller.holds.contains(.background))
        #expect(!slotB.controller.isHeld)
        #expect(slotC.controller.holds.contains(.background))

        // Mid-background: unmute C (releases its background hold), then mute B (acquires a fresh background hold).
        slotC.controller.setMuted(false)
        #expect(!slotC.controller.holds.contains(.background))
        slotB.controller.setMuted(true)
        #expect(slotB.controller.holds.contains(.background))

        // Foregrounding must release the dynamically created hold on B too!
        center.lifecycle?.willEnterForeground()
        #expect(!slotA.controller.isHeld)
        #expect(!slotB.controller.isHeld)
        #expect(!slotC.controller.isHeld)
    }

    @Test("Pinning or starting a primary mid-feedPreview hold inherits the hold; manual pauses stay paused on release")
    func midHoldInheritanceAndManualPause() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        #expect(center.pinBackgroundAudio(Self.chA, title: "A", profileImageURL: nil) == .pinned)
        let slotA = center.pinnedSlot(for: Self.chA.channelId)!
        slotA.controller.togglePlay() // manual pause

        let hold = center.holdPlayback(.feedPreview)
        #expect(hold != nil)

        // Pin B and start primary C while feedPreview hold is active: both inherit it!
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        center.play(Self.chC, title: "C", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        let slotB = center.pinnedSlot(for: Self.chB.channelId)!
        let slotC = center.primary!
        #expect(slotB.controller.holds.contains(.feedPreview))
        #expect(slotC.controller.holds.contains(.feedPreview))

        if let hold { center.releaseHold(hold) }
        #expect(!slotA.controller.startsPlaying) // stayed manually paused
        #expect(slotB.controller.startsPlaying)
        #expect(slotC.controller.startsPlaying)
    }

    @Test("Media services reset invalidates audio session once and notifies every native slot")
    func mediaServicesResetNotifiesAllNativeSlots() async {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.play(Self.chA, title: "A", profileImageURL: nil, native: true, audioOnly: false, quality: .auto)
        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)

        center.handleMediaServicesWereReset()
        // Wait for serial queue invalidate to land.
        await engines.audioSession.updateClient(.homePreview, state: .inactive)
        #expect(engines.audioDriver.invalidations == 1)
        #expect(engines.built[0].mediaResetCount == 1)
        #expect(engines.built[1].mediaResetCount == 1)
    }

    // MARK: - Mixed-state Lock Screen commands & Pinned offline reconciliation

    @Test("Remote Play/Pause/Toggle unify mixed paused/playing slots instead of inverting them")
    func remoteCommandsUnifyMixedState() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        #expect(center.pinBackgroundAudio(Self.chA, title: "Stream A", profileImageURL: nil) == .pinned)
        #expect(center.pinBackgroundAudio(Self.chB, title: "Stream B", profileImageURL: nil) == .pinned)
        let slotA = center.pinnedSlot(for: Self.chA.channelId)!
        let slotB = center.pinnedSlot(for: Self.chB.channelId)!

        slotB.controller.togglePlay()
        let summary = StreamNowPlaying.summarize(slots: center.nowPlayingEligibleSlots)
        #expect(summary?.title == "Alpha + 1 more")
        #expect(summary?.artist == "chattr · 2 live streams")
        #expect(summary?.isPaused == false)

        center.remoteTogglePlayPauseBackgroundAudio()
        #expect(slotA.controller.isPaused && slotB.controller.isPaused)

        center.remoteTogglePlayPauseBackgroundAudio()
        #expect(!slotA.controller.isPaused && !slotB.controller.isPaused)
    }

    @Test("Pinned offline confirmation requires two distinct timestamps even for unloaded slots or pins without stream metadata")
    func pinnedOfflineRequiresTwoReadings() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        #expect(center.pinBackgroundAudio(Self.chA, title: "A", profileImageURL: nil, stream: nil) == .pinned)
        let slotA = center.pinnedSlot(for: Self.chA.channelId)!
        slotA.controller.togglePlay()
        center.unloadAfterLongPause(slotID: slotA.id)
        #expect(slotA.engine == nil)

        let t1 = Date(timeIntervalSince1970: 1_000)
        #expect(!slotA.pinnedOfflineReadingConfirmed(at: t1))
        #expect(!slotA.pinnedOfflineReadingConfirmed(at: t1))
        #expect(slotA.pinnedOfflineReadingConfirmed(at: t1.addingTimeInterval(60)))
    }

    // MARK: - Observation isolation (withObservationTracking)

    @Test("Pinning channel B invalidates channel B's flag only and never invalidates channel A's flag")
    func pinnedFlagObservationIsolation() {
        let engines = FakeStreamEngines()
        let center = engines.center()
        defer { center.stopAll() }

        center.retainPinnedAudioFlag(for: Self.chA.channelId)
        center.retainPinnedAudioFlag(for: Self.chB.channelId)

        let flagAInvalidated = OSAllocatedUnfairLock(initialState: false)
        let flagBInvalidated = OSAllocatedUnfairLock(initialState: false)

        withObservationTracking {
            _ = center.pinnedAudioFlag(for: Self.chA.channelId).isPinned
        } onChange: {
            flagAInvalidated.withLock { $0 = true }
        }
        withObservationTracking {
            _ = center.pinnedAudioFlag(for: Self.chB.channelId).isPinned
        } onChange: {
            flagBInvalidated.withLock { $0 = true }
        }

        #expect(center.pinBackgroundAudio(Self.chB, title: "B", profileImageURL: nil) == .pinned)
        #expect(!flagAInvalidated.withLock { $0 })
        #expect(flagBInvalidated.withLock { $0 })

        center.releasePinnedAudioFlag(for: Self.chA.channelId)
        center.releasePinnedAudioFlag(for: Self.chB.channelId)
        center.drainPendingEvictions()
        #expect(center.pinnedAudioFlagCount == 0)
    }
}
#endif
