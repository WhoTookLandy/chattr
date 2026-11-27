import SwiftUI
import Core
import TwitchKit
import os
#if os(iOS)
import UIKit
import WebKit
import Combine
#endif

#if os(iOS)

let playbackCenterLogger = AppLogger.make("Features.PlaybackCenter")

/// Coordinates `chattr`'s stream playback: 1 Primary ("stage") slot plus up to
/// `maxPinnedAudioSlots` (3) headless native background-audio slots.
///
/// The primary slot's view is shown by whichever `PlayerHost` claimed it most
/// recently (`hostStack`): the chat header, the landscape stage, or the mini
/// player video tile. Pinned background slots play audio headless on native
/// `AVPlayer` instances and survive tab swipes and app backgrounding.
@MainActor
@Observable
final class PlaybackCenter {
    static let maxPinnedAudioSlots = 3
    /// A paused stream gives its engine up after this long
    /// (`unloadAfterLongPause`).
    static let pauseUnloadDelay: Duration = .seconds(600)

    /// The primary stage stream (video, landscape, PiP, web fallback, mini-player video tile).
    var primary: PlaybackSlot?
    /// Headless native audio-only background streams, ordered by pin time (max `maxPinnedAudioSlots`).
    var pinnedAudio: [PlaybackSlot] = []
    /// Non-observed mirror of `pinnedAudio` channel IDs so `pinnedAudioFlag(for:)`
    /// and non-rendering checks never register an observation dependency on the array.
    @ObservationIgnored var pinnedChannelIDs: Set<String> = []
    /// Slot currently soloed (either `primary?.id` or one of `pinnedAudio`), if any.
    var soloSlotID: UUID?
    /// True while global Mute All is active.
    var isMutedAll = false

    /// The host currently showing the primary video (last to claim).
    var activeHostID: UUID?
    @ObservationIgnored var hostStack: [UUID] = []
    /// Bumped when the primary engine changes so hosts re-attach or detach.
    var hostRevision = 0

    /// Idle controller returned when `primary == nil` and adopted when `play(...)`
    /// creates a primary slot from idle. Replaced with a fresh instance whenever
    /// a slot built on it leaves `primary` (e.g. native demotion) so two slots
    /// can never share one controller.
    @ObservationIgnored var defaultPrimaryController = StreamPlayerController()

    /// Stable center-owned callbacks so swapping `primary` on promote/demote
    /// never loses app-level PiP or surface tap/swipe handlers.
    @ObservationIgnored var onRestoreFromPictureInPicture: (() -> Void)?
    @ObservationIgnored var onPictureInPictureClosed: (() -> Void)?
    @ObservationIgnored var onPrimaryTap: (() -> Void)?
    @ObservationIgnored var onPrimarySwipeDown: (() -> Void)?

    /// How `play` / `pinBackgroundAudio` builds its engines.
    let makeEngine: StreamEngineFactory
    let audioSession: PlaybackAudioSession
    let nowPlaying = StreamNowPlaying()

    /// Set when a chat opens under "Autoplay on Wi-Fi": the next new primary
    /// stream starts muted. Consumed by the next engine build.
    @ObservationIgnored var startNextStreamMuted = false
    /// Leaving the app → PiP or `.background` holds (`PlaybackLifecycleObserver`).
    @ObservationIgnored private(set) var lifecycle: PlaybackLifecycleObserver?

    /// Single owner for Solo / Mute All saved-mute snapshots.
    @ObservationIgnored var audioFocusMode: AudioFocusMode = .none
    /// Active center-level hold tokens (`.clip`, `.feedPreview`, `.background`)
    /// so slots created mid-hold inherit them automatically.
    @ObservationIgnored var activeCenterHolds: [PlaybackHoldReason: PlaybackHold] = [:]
    /// System audio notifications (`interruption`, `routeChange`, `mediaServicesWereReset`).
    @ObservationIgnored var audioSystemSubscriptions: Set<AnyCancellable> = []

    // MARK: - Primary facades (backwards-compatible with single-stream surfaces)

    var channel: ChannelDescriptor? { primary?.channel }
    var title: String { primary?.title ?? "" }
    var profileImageURL: URL? { primary?.profileImageURL }
    var audioOnly: Bool { primary?.audioOnly ?? false }
    var engine: (any StreamEngine)? { primary?.engine }
    var lingeringStream: TwitchStream? { primary?.lingeringStream }
    var controller: StreamPlayerController { primary?.controller ?? defaultPrimaryController }

    /// A primary stream is loaded — playing, paused, or still starting.
    var isPlaying: Bool { primary != nil }
    var hasPrimary: Bool { primary != nil }
    /// Either a primary stream or at least one pinned background audio stream is active.
    var hasAnyPlayback: Bool { primary != nil || !pinnedAudio.isEmpty }

    /// Non-observing snapshot of currently pinned channel IDs.
    var pinnedChannelIDsSnapshot: Set<String> { pinnedChannelIDs }

    /// Non-observing check for whether another channel can be pinned right now.
    var canPinMoreBackgroundAudio: Bool {
        PlayerSettings.isNativePlaybackEnabled && pinnedChannelIDs.count < Self.maxPinnedAudioSlots
    }

    /// Every active slot (`primary` first if present, then `pinnedAudio`).
    var allSlots: [PlaybackSlot] {
        var result: [PlaybackSlot] = []
        if let primary { result.append(primary) }
        result.append(contentsOf: pinnedAudio)
        return result
    }

    /// Streams represented in the unified bottom audio dock (`primary` if
    /// native audio-only, followed by all `pinnedAudio` slots).
    var audioDockSlots: [PlaybackSlot] {
        var result: [PlaybackSlot] = []
        if let primary, primary.audioOnly, !primary.controller.nativeFailed {
            result.append(primary)
        }
        result.append(contentsOf: pinnedAudio)
        return result
    }

    /// True while the primary video tile should be shown outside chat.
    var showsPrimaryVideoTile: Bool {
        guard let primary else { return false }
        let isAudioOnly = primary.audioOnly && !primary.controller.nativeFailed
        return !isAudioOnly && !primary.controller.isPictureInPictureActive
    }

    /// A primary stream is loaded, not paused, and showing video: the one case
    /// that should keep the display from sleeping. Pinned background audio
    /// slots never hold the screen awake.
    var holdsScreenAwake: Bool {
        guard let primary else { return false }
        return !primary.controller.isPaused && !(primary.audioOnly && !primary.controller.nativeFailed)
    }

    init(
        playlistResolver: any StreamPlaylistResolving = TwitchHLS.Resolver(),
        makeEngine: StreamEngineFactory? = nil,
        audioSession: PlaybackAudioSession = .shared
    ) {
        self.makeEngine = makeEngine ?? PlaybackCenter.realEngines(playlistResolver: playlistResolver)
        self.audioSession = audioSession
        lifecycle = PlaybackLifecycleObserver(center: self)
        observeSystemAudioNotifications()
    }

    static func realEngines(playlistResolver: any StreamPlaylistResolving) -> StreamEngineFactory {
        return { (request: StreamEngineRequest, controller: StreamPlayerController) -> any StreamEngine in
            switch request {
            case .native(let login, let audioOnly, let quality, let allowsPictureInPicture):
                return NativeStreamEngine(
                    login: login,
                    audioOnly: audioOnly,
                    quality: quality,
                    allowsPictureInPicture: allowsPictureInPicture,
                    controller: controller,
                    resolver: playlistResolver
                )
            case .web(let login, let recycled):
                return WebStreamEngine(login: login, controller: controller, reusing: recycled)
            }
        }
    }

    // MARK: - Per-channel PiP flags

    @ObservationIgnored private var pictureInPictureFlags: [String: ChannelPictureInPictureFlag] = [:]
    @ObservationIgnored private var pictureInPictureFlagOwners: [String: Int] = [:]
    @ObservationIgnored private var pictureInPictureChannelID: String?
    @ObservationIgnored private var pendingFlagEvictions: Set<String> = []

    func pictureInPictureFlag(for channelId: String) -> ChannelPictureInPictureFlag {
        if let flag = pictureInPictureFlags[channelId] { return flag }
        let flag = ChannelPictureInPictureFlag()
        flag.isActive = pictureInPictureChannelID == channelId
        pictureInPictureFlags[channelId] = flag
        return flag
    }

    func retainPictureInPictureFlag(for channelId: String) {
        _ = pictureInPictureFlag(for: channelId)
        pictureInPictureFlagOwners[channelId, default: 0] += 1
    }

    func releasePictureInPictureFlag(for channelId: String) {
        guard let owners = pictureInPictureFlagOwners[channelId] else { return }
        guard owners <= 1 else {
            pictureInPictureFlagOwners[channelId] = owners - 1
            return
        }
        pictureInPictureFlagOwners[channelId] = nil
        let wasIdle = pendingFlagEvictions.isEmpty
        pendingFlagEvictions.insert(channelId)
        guard wasIdle else { return }
        Task { @MainActor [weak self] in
            self?.drainPendingEvictions()
        }
    }

    // MARK: - Per-channel Pinned Audio flags

    @ObservationIgnored private var pinnedAudioFlags: [String: ChannelPinnedAudioFlag] = [:]
    @ObservationIgnored private var pinnedAudioFlagOwners: [String: Int] = [:]
    @ObservationIgnored private var pendingPinnedFlagEvictions: Set<String> = []

    /// Seeds new flags from `@ObservationIgnored pinnedChannelIDs` so calling
    /// this during a view's `body` never registers an observation dependency on
    /// the whole `pinnedAudio` array.
    func pinnedAudioFlag(for channelId: String) -> ChannelPinnedAudioFlag {
        if let flag = pinnedAudioFlags[channelId] { return flag }
        let flag = ChannelPinnedAudioFlag()
        flag.isPinned = pinnedChannelIDs.contains(channelId)
        pinnedAudioFlags[channelId] = flag
        return flag
    }

    func retainPinnedAudioFlag(for channelId: String) {
        _ = pinnedAudioFlag(for: channelId)
        pinnedAudioFlagOwners[channelId, default: 0] += 1
    }

    func releasePinnedAudioFlag(for channelId: String) {
        guard let owners = pinnedAudioFlagOwners[channelId] else { return }
        guard owners <= 1 else {
            pinnedAudioFlagOwners[channelId] = owners - 1
            return
        }
        pinnedAudioFlagOwners[channelId] = nil
        let wasIdle = pendingPinnedFlagEvictions.isEmpty
        pendingPinnedFlagEvictions.insert(channelId)
        guard wasIdle else { return }
        Task { @MainActor [weak self] in
            self?.drainPendingEvictions()
        }
    }

    func drainPendingEvictions() {
        let pendingPiP = pendingFlagEvictions
        pendingFlagEvictions.removeAll()
        for channelId in pendingPiP where pictureInPictureFlagOwners[channelId] == nil {
            pictureInPictureFlags[channelId] = nil
        }

        let pendingPinned = pendingPinnedFlagEvictions
        pendingPinnedFlagEvictions.removeAll()
        for channelId in pendingPinned where pinnedAudioFlagOwners[channelId] == nil {
            pinnedAudioFlags[channelId] = nil
        }
    }

    var pictureInPictureFlagCount: Int { pictureInPictureFlags.count }
    var pinnedAudioFlagCount: Int { pinnedAudioFlags.count }

    func syncPictureInPictureFlags() {
        let current = (primary?.controller.isPictureInPictureActive == true) ? primary?.channel.channelId : nil
        guard current != pictureInPictureChannelID else { return }
        if let previous = pictureInPictureChannelID {
            pictureInPictureFlags[previous]?.isActive = false
        }
        pictureInPictureChannelID = current
        if let current {
            pictureInPictureFlags[current]?.isActive = true
        }
    }

    func syncPinnedAudioFlag(for channelId: String, isPinned: Bool) {
        if isPinned {
            pinnedChannelIDs.insert(channelId)
        } else {
            pinnedChannelIDs.remove(channelId)
        }
        guard let flag = pinnedAudioFlags[channelId], flag.isPinned != isPinned else { return }
        flag.isPinned = isPinned
    }

    // MARK: - Primary playback

    /// Play `channel` in the primary stage slot (or keep playing it if it
    /// already is). Rebuilds the engine only when the channel or engine-shaping
    /// settings change. If `channel` is currently pinned in background audio,
    /// promotes it seamlessly instead of building a duplicate engine.
    func play(
        _ channel: ChannelDescriptor,
        title: String,
        profileImageURL: URL?,
        native: Bool,
        audioOnly: Bool,
        quality: PlayerQuality
    ) {
        if pinnedChannelIDs.contains(channel.channelId) {
            promotePinnedToPrimary(
                channelId: channel.channelId,
                audioOnly: audioOnly,
                quality: quality,
                title: title,
                profileImageURL: profileImageURL
            )
            return
        }

        let existingPrimary = primary
        let sameChannel = existingPrimary?.channel.channelId == channel.channelId
        let slot: PlaybackSlot
        if let existingPrimary {
            slot = existingPrimary
        } else {
            let created = PlaybackSlot(
                channel: channel,
                title: title,
                profileImageURL: profileImageURL,
                audioOnly: audioOnly,
                allowsPictureInPicture: true,
                quality: quality,
                native: native,
                controller: defaultPrimaryController
            )
            wireSlotCallbacks(created)
            primary = created
            slot = created
        }

        if slot.title != title { slot.title = title }
        if slot.profileImageURL != profileImageURL { slot.profileImageURL = profileImageURL }
        let entersAudioOnly = audioOnly && !slot.audioOnly
        let audioOnlyChanged = slot.audioOnly != audioOnly
        if audioOnlyChanged { slot.audioOnly = audioOnly }
        slot.lastQuality = quality
        slot.lastNative = native
        slot.clearLingeringStream()

        let nativeEnabled = PlayerSettings.isNativePlaybackEnabled
        let wantsNative = native || (sameChannel && slot.promotedToNative)
        let useNative = wantsNative && nativeEnabled && !(sameChannel && slot.controller.nativeFailed)
        let key = "\(channel.channelLoginName)|\(useNative)"

        guard key != slot.engineKey else {
            if audioOnlyChanged {
                if entersAudioOnly, slot.controller.isMuted, !shouldNewSlotStartMuted(excluding: slot.id) {
                    slot.controller.setMuted(false, programmatic: true)
                }
                if useNative {
                    slot.engine?.setAudioOnly(audioOnly, quality: quality)
                } else {
                    slot.controller.applyQuality(quality)
                }
                refreshNowPlaying()
                reconcileAudioSession()
            } else {
                slot.controller.applyQuality(quality)
            }
            return
        }

        let previous = slot.engine
        slot.engine = nil
        var recycledWebView: WKWebView?
        if !useNative, let web = previous as? WebStreamEngine {
            recycledWebView = web.releaseWebView()
        } else {
            previous?.teardown()
        }

        if !sameChannel {
            if existingPrimary != nil {
                handleSlotRemovedFromAudioFocus(slotID: slot.id)
                lapseCenterHolds(forSlotID: slot.id)
            }
            slot.channel = channel
            slot.controller.nativeFailed = false
            slot.promotedToNative = false
            slot.lastLiveStream = nil
            slot.controller.wantsPlayback = true
            slot.controller.update(\.volume, to: 1.0)
            slot.advanceGeneration()
        }

        if native, !nativeEnabled {
            slot.controller.nativeFailed = true
        }

        let mutedByFocus = shouldNewSlotStartMuted(excluding: slot.id)
        if sameChannel {
            // Respect active Solo / Mute All even when rebuilding a web primary
            // into native audio-only.
            slot.controller.startsMuted = (slot.controller.isMuted && !entersAudioOnly) || mutedByFocus
        } else {
            slot.controller.startsMuted = startNextStreamMuted || mutedByFocus
            if mutedByFocus {
                recordNewSlotInAudioFocus(slotID: slot.id, unmutedWhenRestored: !startNextStreamMuted)
            }
        }
        startNextStreamMuted = false
        slot.controller.reset()
        syncPictureInPictureFlags()

        // If a `.clip` or `.feedPreview` hold is still active on pinned slots,
        // this new primary slot inherits it before its engine starts.
        if !sameChannel {
            inheritActiveCenterHolds(into: slot)
        }

        slot.engineKey = key
        let request: StreamEngineRequest = useNative
            ? .native(
                login: channel.channelLoginName,
                audioOnly: audioOnly,
                quality: quality,
                allowsPictureInPicture: true
            )
            : .web(login: channel.channelLoginName, reusing: recycledWebView)
        let builtEngine = makeEngine(request, slot.controller)
        slot.engine = builtEngine
        slot.engineKind = builtEngine.kind

        activeHostID = hostStack.last
        hostRevision += 1
        refreshNowPlaying()
        reconcileAudioSession()
        schedulePauseUnload(for: slot)
    }

    /// Primary native engine gave up — rebuild the same channel on the web engine.
    func fallBackToWeb(quality: PlayerQuality) {
        guard let slot = primary else { return }
        slot.controller.nativeFailed = true
        slot.promotedToNative = false
        play(
            slot.channel,
            title: slot.title,
            profileImageURL: slot.profileImageURL,
            native: false,
            audioOnly: slot.audioOnly,
            quality: quality
        )
    }

    var primaryStaysOnNativeEngine: Bool {
        guard let primary else { return false }
        return primary.audioOnly && primary.engine?.kind == .native && (lifecycle?.isInBackground ?? false)
    }

    /// Stops ONLY the primary stage stream. Pinned background audio slots stay
    /// untouched. Kept as `stop()` as well for single-stream caller compatibility.
    func stop() {
        stopPrimary()
    }

    func stopPrimary() {
        guard let slot = primary else {
            defaultPrimaryController.startsMuted = false
            defaultPrimaryController.wantsPlayback = true
            defaultPrimaryController.reset()
            defaultPrimaryController.nativeFailed = false
            reconcileAudioSession()
            return
        }
        tearDownSlot(slot)
        primary = nil
        handleSlotRemovedFromAudioFocus(slotID: slot.id)
        syncPictureInPictureFlags()
        refreshNowPlaying()
        reconcileAudioSession()
        hostRevision += 1
    }

    /// Tears down EVERY active stream (primary + all pinned background audio),
    /// cancels all holds and timers, and resets audio focus. Used on sign-out /
    /// account switch (`AppShell.onDisappear`).
    func stopAll() {
        if let slot = primary {
            tearDownSlot(slot)
            primary = nil
        }
        let oldPinned = pinnedAudio
        pinnedAudio.removeAll()
        for slot in oldPinned {
            tearDownSlot(slot)
            syncPinnedAudioFlag(for: slot.channel.channelId, isPinned: false)
        }
        pinnedChannelIDs.removeAll()
        activeCenterHolds.removeAll()
        audioFocusMode = .none
        soloSlotID = nil
        isMutedAll = false
        syncPictureInPictureFlags()
        nowPlaying.clear()
        reconcileAudioSession()
        hostRevision += 1
    }

    func tearDownSlot(_ slot: PlaybackSlot) {
        lapseCenterHolds(forSlotID: slot.id)
        slot.advanceGeneration()
        slot.pauseUnloadTask?.cancel()
        slot.pauseUnloadTask = nil
        slot.engine?.teardown()
        slot.engine = nil
        slot.engineKey = nil
        slot.engineKind = nil
        slot.clearLingeringStream()
        slot.lastLiveStream = nil
        slot.promotedToNative = false
        slot.controller.startsMuted = false
        slot.controller.wantsPlayback = true
        slot.controller.reset()
        slot.controller.nativeFailed = false
        slot.controller.update(\.volume, to: 1.0)
    }

    // MARK: - Slot callback wiring (keyed by slot.id)

    func wireSlotCallbacks(_ slot: PlaybackSlot) {
        let slotID = slot.id
        let ctrl = slot.controller

        ctrl.onNativeFailure = { [weak self] in
            self?.handleNativeFailure(slotID: slotID)
        }
        ctrl.staysOnNativeEngine = { [weak self] in
            guard let self else { return false }
            if self.primary?.id == slotID {
                return self.primaryStaysOnNativeEngine
            }
            return false
        }
        ctrl.onStreamEnded = { [weak self] in
            self?.handleStreamEnded(slotID: slotID)
        }
        ctrl.onPictureInPictureActiveChange = { [weak self] in
            guard let self, self.primary?.id == slotID else { return }
            self.syncPictureInPictureFlags()
            self.yieldBackgroundHoldToPictureInPicture(slotID: slotID)
            self.reconcileAudioSession()
            self.refreshNowPlaying()
            if let primary = self.primary {
                self.schedulePauseUnload(for: primary)
            }
        }
        ctrl.onPausedChange = { [weak self] in
            self?.handlePausedChange(slotID: slotID)
        }
        ctrl.onResumeRequested = { [weak self] in
            self?.restoreUnloadedEngine(slotID: slotID)
        }
        ctrl.onAudioStateChange = { [weak self] userInitiatedUnmute in
            self?.handleAudioStateChange(slotID: slotID, userInitiatedUnmute: userInitiatedUnmute)
        }
        ctrl.onPrepareAudioSession = { [weak self] in
            await self?.prepareAudioSessionForNativeStart(slotID: slotID)
        }
        ctrl.onRestoreFromPictureInPicture = { [weak self] in
            guard let self, self.primary?.id == slotID else { return }
            self.onRestoreFromPictureInPicture?()
        }
        ctrl.onPictureInPictureClosed = { [weak self] in
            guard let self, self.primary?.id == slotID else { return }
            self.onPictureInPictureClosed?()
        }
        ctrl.onTap = { [weak self] in
            guard let self, self.primary?.id == slotID else { return }
            self.onPrimaryTap?()
        }
        ctrl.onSwipeDown = { [weak self] in
            guard let self, self.primary?.id == slotID else { return }
            self.onPrimarySwipeDown?()
        }
    }

    private func handleNativeFailure(slotID: UUID) {
        if primary?.id == slotID {
            if primaryStaysOnNativeEngine {
                stopPrimary()
            } else if let quality = primary?.lastQuality {
                fallBackToWeb(quality: quality)
            }
            return
        }
        if let pinned = pinnedAudio.first(where: { $0.id == slotID }) {
            playbackCenterLogger.warning("Pinned native audio failed for @\(pinned.channel.channelLoginName, privacy: .public); unpinning")
            unpinBackgroundAudio(channelId: pinned.channel.channelId)
        }
    }

    private func handleStreamEnded(slotID: UUID) {
        if primary?.id == slotID {
            stopPrimary()
        } else if let pinned = pinnedAudio.first(where: { $0.id == slotID }) {
            playbackCenterLogger.info("Pinned stream ended for @\(pinned.channel.channelLoginName, privacy: .public); unpinning")
            unpinBackgroundAudio(channelId: pinned.channel.channelId)
        }
    }

    private func handlePausedChange(slotID: UUID) {
        guard let slot = slot(withID: slotID) else { return }
        refreshNowPlaying()
        reconcileAudioSession()
        schedulePauseUnload(for: slot)
    }

    func slot(withID id: UUID) -> PlaybackSlot? {
        if primary?.id == id { return primary }
        return pinnedAudio.first { $0.id == id }
    }

    // MARK: - Primary offline softening (isolated from `pinnedAudio`)

    /// Checks ONLY `primary` so pre-mounted headers never register an
    /// observation dependency on `pinnedAudio`.
    func stream(for channelId: String, live: TwitchStream?) -> TwitchStream? {
        if let live { return live }
        guard let lingering = primary?.lingeringStream, lingering.userId == channelId else { return nil }
        return lingering
    }

    func noteWentOffline(_ stream: TwitchStream) {
        primary?.noteWentOffline(stream)
    }

    func noteLive(_ stream: TwitchStream) {
        primary?.noteLive(stream)
    }

    func offlineReadingConfirmed(at fetchedAt: Date) -> Bool {
        guard let primary else { return true }
        return primary.offlineReadingConfirmed(at: fetchedAt)
    }

    // MARK: - Long pause unload

    func schedulePauseUnload(for slot: PlaybackSlot) {
        slot.pauseUnloadTask?.cancel()
        slot.pauseUnloadTask = nil
        guard slot.engine != nil, slot.controller.isPaused else { return }
        let slotID = slot.id
        slot.pauseUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackCenter.pauseUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.unloadAfterLongPause(slotID: slotID)
        }
    }

    /// Unloads the primary slot after a long pause (internal so tests drive it directly).
    func unloadAfterLongPause() {
        guard let primary else { return }
        unloadAfterLongPause(slotID: primary.id)
    }

    func unloadAfterLongPause(slotID: UUID) {
        guard let slot = slot(withID: slotID) else { return }
        slot.pauseUnloadTask = nil
        guard let engine = slot.engine,
              slot.controller.isPaused,
              !slot.controller.isHeld,
              !slot.controller.isPictureInPictureActive
        else { return }
        engine.teardown()
        slot.engine = nil
        slot.engineKind = nil
        slot.controller.startsMuted = slot.controller.isMuted
        slot.controller.wantsPlayback = false
        slot.controller.reset()
        reconcileAudioSession()
        refreshNowPlaying()
        if primary?.id == slotID {
            hostRevision += 1
        }
    }

    func restoreUnloadedEngine(slotID: UUID) {
        guard let slot = slot(withID: slotID), slot.engine == nil else { return }
        if primary?.id == slotID {
            slot.engineKey = nil
            play(
                slot.channel,
                title: slot.title,
                profileImageURL: slot.profileImageURL,
                native: slot.lastNative,
                audioOnly: slot.audioOnly,
                quality: slot.lastQuality
            )
            return
        }
        guard PlayerSettings.isNativePlaybackEnabled else {
            unpinBackgroundAudio(channelId: slot.channel.channelId)
            return
        }
        slot.controller.wantsPlayback = true
        slot.controller.startsMuted = slot.controller.isMuted
        slot.controller.reset()
        let request: StreamEngineRequest = .native(
            login: slot.channel.channelLoginName,
            audioOnly: true,
            quality: slot.lastQuality,
            allowsPictureInPicture: false
        )
        let built = makeEngine(request, slot.controller)
        slot.engine = built
        slot.engineKind = built.kind
        slot.engineKey = "\(slot.channel.channelLoginName)|true"
        reconcileAudioSession()
        refreshNowPlaying()
    }

    // MARK: - Queries

    func isPlaying(_ channelId: String) -> Bool {
        primary?.channel.channelId == channelId
    }

    func isPinnedAudio(_ channelId: String) -> Bool {
        pinnedChannelIDs.contains(channelId)
    }

    func isPlayingOrPinned(_ channelId: String) -> Bool {
        isPlaying(channelId) || isPinnedAudio(channelId)
    }

    func pinnedSlot(for channelId: String) -> PlaybackSlot? {
        pinnedAudio.first { $0.channel.channelId == channelId }
    }

    // MARK: - Hosts

    func claim(_ hostID: UUID) {
        hostStack.removeAll { $0 == hostID }
        hostStack.append(hostID)
        if activeHostID != hostID { activeHostID = hostID }
    }

    func release(_ hostID: UUID) {
        hostStack.removeAll { $0 == hostID }
        if activeHostID == hostID { activeHostID = hostStack.last }
    }
}
#endif
