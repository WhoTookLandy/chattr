import SwiftUI
import Core
import TwitchKit
#if os(iOS)
import UIKit
import WebKit
#endif

#if os(iOS)

/// The app's single stream player. The chat header asks it to play the
/// visible channel; when the chat is closed it keeps playing and the
/// `MiniPlayerOverlay` shows it until the user returns or dismisses it.
///
/// The engine's view is shown by whichever `PlayerHost` claimed it most
/// recently (`hostStack`): the chat header while the chat is on screen, the
/// mini player otherwise.
@MainActor
@Observable
final class PlaybackCenter {
    /// What's playing — nil when nothing is.
    private(set) var channel: ChannelDescriptor?
    /// Snapshot for the mini player (the chat header's stores aren't
    /// around once the chat is gone).
    private(set) var title: String = ""
    private(set) var profileImageURL: URL?
    private(set) var audioOnly = false

    /// The host currently showing the video (last to claim).
    private(set) var activeHostID: UUID?
    @ObservationIgnored private var hostStack: [UUID] = []

    let controller = StreamPlayerController()
    @ObservationIgnored private(set) var engine: StreamEngine?
    @ObservationIgnored private var engineKey: String?

    @ObservationIgnored private var lastQuality: PlayerQuality = .auto
    /// The `native` the header last asked for — a rebuild after a long
    /// pause (`restoreUnloadedEngine`) asks for the same.
    @ObservationIgnored private var lastNative = false
    /// How `play` gets its engines (`init`).
    private let makeEngine: StreamEngineFactory
    private let nowPlaying = StreamNowPlaying()

    /// The playing channel's stream as last polled, kept through a poll
    /// that left it out. The engine is still playing then, so the surfaces
    /// that follow live status (the header, the landscape stage) read
    /// `stream(for:live:)` and stay up until the reading is confirmed
    /// (`offlineReadingConfirmed(at:)`) or the stream shows up again.
    private(set) var lingeringStream: TwitchStream?
    /// The reading that started `lingeringStream`.
    @ObservationIgnored private var firstOfflineReadingAt: Date?
    /// The playing channel's stream as the header last asked to play it
    /// (`noteLive`). Stands in for `lingeringStream` when an offline
    /// reading is judged before `noteWentOffline` was told about the drop.
    @ObservationIgnored private var lastLiveStream: TwitchStream?

    /// A paused stream gives its engine up after this long
    /// (`unloadAfterLongPause`).
    static let pauseUnloadDelay: Duration = .seconds(600)
    @ObservationIgnored private var pauseUnloadTask: Task<Void, Never>?

    /// Bumped when WHAT plays changes: a different channel, or stop.
    /// Rebuilding the same channel's engine (native → web fallback, an
    /// engine or audio-only setting) keeps it, so a hold survives that.
    @ObservationIgnored private var generation = 0
    /// The outstanding `holdPlayback` per reason (at most one each).
    @ObservationIgnored private var currentHolds: [PlaybackHoldReason: PlaybackHold] = [:]

    /// Set when a chat opens under "Autoplay on Wi-Fi": the next new
    /// stream starts muted. Consumed by the next engine build.
    @ObservationIgnored var startNextStreamMuted = false
    /// Leaving the app → PiP or a `.background` hold (see
    /// `PlaybackLifecycleObserver`).
    @ObservationIgnored private(set) var lifecycle: PlaybackLifecycleObserver?

    /// A stream is loaded — playing, paused, or still starting.
    var isPlaying: Bool { channel != nil }

    /// A stream is loaded, not paused, and showing video: the one case
    /// that should keep the display from sleeping. A paused stream or the
    /// audio-only pill shouldn't.
    var holdsScreenAwake: Bool {
        channel != nil && !controller.isPaused && !(audioOnly && !controller.nativeFailed)
    }

    /// `makeEngine`: how engines are built. Left out, they are the real
    /// ones (`realEngines(playlistResolver:)`), the native one resolving
    /// its playlist through `playlistResolver`.
    init(
        playlistResolver: any StreamPlaylistResolving = TwitchHLS.Resolver(),
        makeEngine: StreamEngineFactory? = nil
    ) {
        self.makeEngine = makeEngine ?? PlaybackCenter.realEngines(playlistResolver: playlistResolver)
        controller.onNativeFailure = { [weak self] in
            self?.nativeEngineGaveUp()
        }
        controller.staysOnNativeEngine = { [weak self] in
            self?.staysOnNativeEngine ?? false
        }
        // The broadcast is over: nothing is left to play or to fall back to.
        controller.onStreamEnded = { [weak self] in
            self?.stop()
        }
        controller.onPictureInPictureActiveChange = { [weak self] in
            self?.syncPictureInPictureFlags()
            self?.yieldBackgroundHoldToPictureInPicture()
            // A stream paused inside PiP isn't unloaded there; out of it
            // again and still paused, the countdown starts over.
            self?.schedulePauseUnload()
        }
        controller.onPausedChange = { [weak self] in
            self?.pausedDidChange()
        }
        controller.onResumeRequested = { [weak self] in
            self?.restoreUnloadedEngine()
        }
        lifecycle = PlaybackLifecycleObserver(center: self)
    }

    /// The factory `init` uses unless it's handed another: the web player,
    /// or the native one on `playlistResolver`.
    static func realEngines(playlistResolver: any StreamPlaylistResolving) -> StreamEngineFactory {
        return { (request: StreamEngineRequest, controller: StreamPlayerController) -> any StreamEngine in
            switch request {
            case .native(let login, let audioOnly, let quality):
                return NativeStreamEngine(
                    login: login,
                    audioOnly: audioOnly,
                    quality: quality,
                    controller: controller,
                    resolver: playlistResolver
                )
            case .web(let login, let recycled):
                return WebStreamEngine(login: login, controller: controller, reusing: recycled)
            }
        }
    }

    // MARK: Per-channel PiP

    /// One observable flag per channel with a mounted reader
    /// (`pictureInPictureFlag(for:)`). Not observed itself: reading the
    /// dictionary registers no dependency, only reading a flag's
    /// `isActive` does.
    @ObservationIgnored private var pictureInPictureFlags: [String: ChannelPictureInPictureFlag] = [:]
    /// Mounted views holding each channel's flag
    /// (`retainsPictureInPictureFlag(for:in:)`). A flag goes once its last
    /// holder unmounts, so channels visited once don't keep one for the
    /// app's lifetime.
    @ObservationIgnored private var pictureInPictureFlagOwners: [String: Int] = [:]
    /// The channel whose flag is currently set, if any.
    @ObservationIgnored private var pictureInPictureChannelID: String?

    /// Whether `channelId`'s stream is in the PiP window, as a value only
    /// that channel's readers observe. `controller.isPictureInPictureActive`
    /// is one global flag: every pre-mounted chat page reading it would
    /// re-render on any PiP transition. A PiP start or stop here writes at
    /// most two flags — the channel leaving PiP and the one entering — so
    /// only the affected page re-evaluates.
    ///
    /// Read from `body`: allocates only the first time a channel is asked
    /// for. Readers keep it with `retainsPictureInPictureFlag(for:in:)`.
    func pictureInPictureFlag(for channelId: String) -> ChannelPictureInPictureFlag {
        if let flag = pictureInPictureFlags[channelId] { return flag }
        let flag = ChannelPictureInPictureFlag()
        flag.isActive = pictureInPictureChannelID == channelId
        pictureInPictureFlags[channelId] = flag
        return flag
    }

    /// A view reading `channelId`'s flag mounted. Refcount, like
    /// `claim` / `release` for hosts.
    func retainPictureInPictureFlag(for channelId: String) {
        _ = pictureInPictureFlag(for: channelId)
        pictureInPictureFlagOwners[channelId, default: 0] += 1
    }

    /// A view reading `channelId`'s flag unmounted. With no holder left the
    /// flag is queued for dropping on the next main-actor turn
    /// (`drainPendingEvictions`), not here: a remount (or a pager window
    /// shift) runs the new view's `body` — reading the existing flag —
    /// before the old view's disappear and the new one's appear. Dropping
    /// it in between would leave the new view observing a flag that's no
    /// longer written.
    func releasePictureInPictureFlag(for channelId: String) {
        guard let owners = pictureInPictureFlagOwners[channelId] else { return }
        guard owners <= 1 else {
            pictureInPictureFlagOwners[channelId] = owners - 1
            return
        }
        pictureInPictureFlagOwners[channelId] = nil
        let wasIdle = pendingFlagEvictions.isEmpty
        pendingFlagEvictions.insert(channelId)
        // One drain per turn, however many flags were released in it.
        guard wasIdle else { return }
        Task { @MainActor [weak self] in
            self?.drainPendingEvictions()
        }
    }

    /// Channels whose flag lost its last holder, awaiting
    /// `drainPendingEvictions`.
    @ObservationIgnored private var pendingFlagEvictions: Set<String> = []

    /// Drops each queued flag that's still unowned; a flag retained again
    /// since its release (a remount) stays. Scheduled by
    /// `releasePictureInPictureFlag`; tests call it directly instead of
    /// relying on task timing.
    func drainPendingEvictions() {
        let pending = pendingFlagEvictions
        pendingFlagEvictions.removeAll()
        for channelId in pending where pictureInPictureFlagOwners[channelId] == nil {
            pictureInPictureFlags[channelId] = nil
        }
    }

    /// Flags held by mounted views — for tests.
    var pictureInPictureFlagCount: Int { pictureInPictureFlags.count }

    private func syncPictureInPictureFlags() {
        let current = controller.isPictureInPictureActive ? channel?.channelId : nil
        guard current != pictureInPictureChannelID else { return }
        if let previous = pictureInPictureChannelID {
            pictureInPictureFlags[previous]?.isActive = false
        }
        pictureInPictureChannelID = current
        if let current {
            pictureInPictureFlags[current]?.isActive = true
        }
    }

    /// Play `channel` (or keep playing it if it already is). Rebuilds the
    /// engine only when the channel or engine-shaping settings change.
    func play(
        _ channel: ChannelDescriptor,
        title: String,
        profileImageURL: URL?,
        native: Bool,
        audioOnly: Bool,
        quality: PlayerQuality
    ) {
        // Guarded: the header calls `play` for the already-playing stream
        // whenever its playback key changes, and an unconditional write
        // re-notifies every reader (the mini player) with identical values.
        if self.title != title { self.title = title }
        if self.profileImageURL != profileImageURL { self.profileImageURL = profileImageURL }
        // The user just asked to listen: audio-only surfaces have no mute
        // control, so a muted video (Wi-Fi autoplay) must not stay muted.
        let entersAudioOnly = audioOnly && !self.audioOnly
        let audioOnlyChanged = self.audioOnly != audioOnly
        if audioOnlyChanged { self.audioOnly = audioOnly }
        lastQuality = quality
        lastNative = native
        // Asked to play: it's live (or it's another stream altogether), so
        // the offline reading didn't hold.
        clearLingeringStream()

        // A native failure for this channel sticks — fall back to web.
        // The kill switch is read here and nowhere else decides the
        // engine: off, nothing takes the native path, audio-only included.
        let sameChannel = self.channel?.channelId == channel.channelId
        let nativeEnabled = PlayerSettings.isNativePlaybackEnabled
        let useNative = native && nativeEnabled && !(sameChannel && controller.nativeFailed)
        // Native audio-only ↔ video switches happen in place on the running
        // `NativeStreamEngine`, so `audioOnly` doesn't force an engine rebuild.
        let key = "\(channel.channelLoginName)|\(useNative)"
        guard key != engineKey else {
            if audioOnlyChanged {
                if entersAudioOnly, controller.isMuted {
                    controller.setMuted(false)
                }
                if useNative {
                    engine?.setAudioOnly(audioOnly, quality: quality)
                } else {
                    controller.applyQuality(quality)
                }
                refreshNowPlaying()
            } else {
                controller.applyQuality(quality)
            }
            return
        }

        let previous = engine
        engine = nil
        var recycledWebView: WKWebView?
        if !useNative, let web = previous as? WebStreamEngine {
            // Web to web is a channel change: keep the web view and
            // navigate it, rather than build another one.
            recycledWebView = web.releaseWebView()
        } else {
            previous?.teardown()
        }
        // The audio session outlives a native engine replaced by another
        // native one (a channel change); the next start reconfigures it.
        // Replaced by the web player, native playback has really stopped.
        if previous?.kind == .native, !useNative {
            PlaybackAudioSession.shared.deactivate()
        }
        if !sameChannel {
            controller.nativeFailed = false
            lastLiveStream = nil
            // A new stream starts out meant to play.
            controller.wantsPlayback = true
            // A new stream isn't the one that was held.
            advanceGeneration()
        }
        // Switched off, the native engine counts as failed for whoever
        // asked for it: every surface already shows a failed audio-only
        // stream as video on the web player.
        if native, !nativeEnabled { controller.nativeFailed = true }
        // A rebuild of the same stream (engine fallback) keeps its mute
        // state — `isMuted` carries the requested mute even if the old
        // engine never got as far as an AVPlayer (see `reset()`). Switching
        // to audio-only unmutes. A new stream starts muted only for autoplay.
        if sameChannel {
            controller.startsMuted = controller.isMuted && !entersAudioOnly
        } else {
            controller.startsMuted = startNextStreamMuted
        }
        startNextStreamMuted = false
        controller.reset()
        self.channel = channel
        syncPictureInPictureFlags()
        engineKey = key
        let request: StreamEngineRequest = useNative
            ? .native(login: channel.channelLoginName, audioOnly: audioOnly, quality: quality)
            : .web(login: channel.channelLoginName, reusing: recycledWebView)
        engine = makeEngine(request, controller)
        // Re-render hosts so the new engine view gets attached.
        activeHostID = hostStack.last
        hostRevision += 1
        refreshNowPlaying()
        schedulePauseUnload()
    }

    /// Native engine gave up — rebuild the same channel on the web engine.
    func fallBackToWeb(quality: PlayerQuality) {
        guard let channel else { return }
        controller.nativeFailed = true
        play(channel, title: title, profileImageURL: profileImageURL,
             native: false, audioOnly: audioOnly, quality: quality)
    }

    /// The native engine is out of tries (`PlaybackRecovery`).
    private func nativeEngineGaveUp() {
        // Audio-only in the background has nothing to fall back to — the
        // web player can't play there — so it stops cleanly instead.
        if staysOnNativeEngine {
            stop()
        } else {
            fallBackToWeb(quality: lastQuality)
        }
    }

    /// Audio-only on the native engine with the app in the background:
    /// the one place a stream plays where the web player can't.
    private var staysOnNativeEngine: Bool {
        audioOnly && engine?.kind == .native && (lifecycle?.isInBackground ?? false)
    }

    func stop() {
        advanceGeneration()
        pauseUnloadTask?.cancel()
        pauseUnloadTask = nil
        let wasNative = engine?.kind == .native
        engine?.teardown()
        engine = nil
        engineKey = nil
        channel = nil
        clearLingeringStream()
        lastLiveStream = nil
        controller.startsMuted = false
        controller.wantsPlayback = true
        controller.reset()
        controller.nativeFailed = false
        if wasNative { PlaybackAudioSession.shared.deactivate() }
        nowPlaying.clear()
        syncPictureInPictureFlags()
        hostRevision += 1
    }

    // MARK: Offline readings

    /// The stream to show for `channelId`: the polled one, or — while its
    /// engine plays on through a poll that left it out — the last one seen.
    /// Read from `body`; a page whose channel is live registers nothing
    /// here.
    func stream(for channelId: String, live: TwitchStream?) -> TwitchStream? {
        if let live { return live }
        guard let lingering = lingeringStream, lingering.userId == channelId else { return nil }
        return lingering
    }

    /// A poll dropped `stream`, which was live a moment ago. If it's the
    /// one playing, keep it on screen for now.
    func noteWentOffline(_ stream: TwitchStream) {
        guard engine != nil, channel?.channelId == stream.userId else { return }
        if lingeringStream != stream { lingeringStream = stream }
    }

    /// The header asked to play `stream` (right after `play`). Remembered
    /// so the first offline reading keeps the stream up whichever of the
    /// header's two reactions to it runs first: its `onChange`
    /// (`noteWentOffline`, with the freshest copy) or its playback task
    /// (`offlineReadingConfirmed`). SwiftUI doesn't promise that order.
    func noteLive(_ stream: TwitchStream) {
        guard channel?.channelId == stream.userId else { return }
        lastLiveStream = stream
    }

    /// Whether the offline reading taken at `fetchedAt` should stop the
    /// playing stream. The first one doesn't: `/streams` now and then
    /// leaves a live channel out of a single response, and stopping on it
    /// cost a rebuild a minute later. A later reading that still says
    /// offline does. (A stream that really ended stops sooner where the
    /// engine can tell — `StreamPlayerController.onStreamEnded`.)
    func offlineReadingConfirmed(at fetchedAt: Date) -> Bool {
        // Asked before `noteWentOffline` (or without it: a header mounted
        // after the drop): the stream as last played stands in.
        if lingeringStream == nil, let lastLiveStream { noteWentOffline(lastLiveStream) }
        guard lingeringStream != nil else { return true }
        guard let first = firstOfflineReadingAt else {
            firstOfflineReadingAt = fetchedAt
            return false
        }
        return fetchedAt != first
    }

    private func clearLingeringStream() {
        firstOfflineReadingAt = nil
        if lingeringStream != nil { lingeringStream = nil }
    }

    // MARK: Long pause

    private func pausedDidChange() {
        refreshNowPlaying()
        schedulePauseUnload()
    }

    /// (Re)starts the countdown to `unloadAfterLongPause` while the stream
    /// sits paused; any play cancels it.
    private func schedulePauseUnload() {
        pauseUnloadTask?.cancel()
        pauseUnloadTask = nil
        guard channel != nil, engine != nil, controller.isPaused else { return }
        pauseUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackCenter.pauseUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.unloadAfterLongPause()
        }
    }

    /// A stream left paused this long gives up its engine — a web view and
    /// its content process, or a player and the audio session — while
    /// staying the loaded stream: same channel, same surfaces, a play
    /// button. Pressing it builds the engine again
    /// (`restoreUnloadedEngine`). Not while a hold is out (a clip, the
    /// background: those pauses end by themselves) or in picture in
    /// picture (tearing the engine down would close the window).
    ///
    /// Internal so tests can run it without the wait.
    func unloadAfterLongPause() {
        pauseUnloadTask = nil
        guard channel != nil, let engine, controller.isPaused,
              !controller.isHeld, !controller.isPictureInPictureActive
        else { return }
        let wasNative = engine.kind == .native
        engine.teardown()
        self.engine = nil
        // `engineKey` stays: the header asking for this same stream again
        // (a swipe away and back) must not build a player just to sit
        // paused.
        controller.startsMuted = controller.isMuted
        // However it came to be paused, by now it's the user's.
        controller.wantsPlayback = false
        controller.reset()
        if wasNative { PlaybackAudioSession.shared.deactivate() }
        refreshNowPlaying()
        hostRevision += 1
    }

    /// Play was pressed on a stream unloaded by `unloadAfterLongPause`.
    private func restoreUnloadedEngine() {
        guard engine == nil, let channel else { return }
        engineKey = nil
        play(channel, title: title, profileImageURL: profileImageURL,
             native: lastNative, audioOnly: audioOnly, quality: lastQuality)
    }

    // MARK: Now Playing

    /// Lock screen / Control Center info and play / pause, for the one
    /// stream that plays with the app in the background: audio-only on the
    /// native engine. Cleared for anything else, and on teardown.
    private func refreshNowPlaying() {
        guard let channel, audioOnly, engine?.kind == .native else {
            nowPlaying.clear()
            return
        }
        nowPlaying.publish(
            title: title,
            channelName: channel.channelDisplayName,
            isPaused: controller.isPaused,
            controller: controller
        )
    }

    func isPlaying(_ channelId: String) -> Bool {
        channel?.channelId == channelId
    }

    // MARK: Holds

    /// Pause the stream for `reason` and hand it back later with
    /// `releaseHold`. The one pause-and-resume mechanism: a clip playing
    /// over the stream (`.clip`) and the app leaving without PiP
    /// (`.background`, `PlaybackLifecycleObserver`) both use it. Explicit
    /// intent, not a toggle:
    ///
    /// - It works while the engine is still loading (no `AVPlayer` yet, or
    ///   the web page not ready): the load won't start playback while any
    ///   hold is out (`StreamPlayerController.startsPlaying`), so the
    ///   stream can't come up behind a clip or in the background.
    /// - Returns nil when nothing is playing or a hold for `reason` is
    ///   already out. Holds for different reasons stack; the stream
    ///   resumes only when the last one goes.
    /// - The hold records, as it begins, whether releasing it resumes
    ///   (`resumesOnRelease(_:)`): only if the stream was meant to be
    ///   playing — we resume only what we paused. A user pause, including
    ///   one made while the stream was buffering before its first frame
    ///   (`StreamPlayerController.wantsPlayback`), is never undone. A hold
    ///   taken while another is out inherits that one's decision: the
    ///   stream is paused because of the first hold, not the user. The
    ///   hold still keeps the stream from starting while it's out.
    /// - It's tied to the playback generation: if the stream stops or
    ///   another channel starts meanwhile, the hold lapses and releasing it
    ///   does nothing.
    func holdPlayback(_ reason: PlaybackHoldReason) -> PlaybackHold? {
        guard isPlaying, currentHolds[reason] == nil else { return nil }
        let resumeOnRelease = currentHolds.isEmpty
            ? Self.resumesOnRelease(controller)
            : currentHolds.values.contains { $0.resumeOnRelease }
        let hold = PlaybackHold(
            id: UUID(),
            reason: reason,
            generation: generation,
            resumeOnRelease: resumeOnRelease
        )
        currentHolds[reason] = hold
        controller.beginHold(reason)
        return hold
    }

    func releaseHold(_ hold: PlaybackHold) {
        guard currentHolds[hold.reason] == hold, hold.generation == generation else { return }
        currentHolds[hold.reason] = nil
        // `wantsPlayback` again: a user pause made during the hold (lock
        // screen, say) wins over the hold's own resume. Another hold still
        // out keeps the stream paused (`endHold` checks `startsPlaying`).
        controller.endHold(hold.reason, resume: hold.resumeOnRelease && controller.wantsPlayback)
        // Still paused with the hold gone (the user's own pause): the long
        // pause countdown, which a hold suspends, starts over.
        schedulePauseUnload()
    }

    /// Whether a hold taken now should resume the stream on release: the
    /// user means it to play (`wantsPlayback`), and it isn't sitting paused
    /// after having started (a pause from outside our controls — PiP
    /// window, lock screen — that `wantsPlayback` didn't see). A stream
    /// still loading toward autoplay resumes; one the user paused doesn't.
    static func resumesOnRelease(_ controller: StreamPlayerController) -> Bool {
        controller.wantsPlayback && !(controller.hasStarted && controller.isPaused)
    }

    /// PiP started while a `.background` hold is out: the app left before
    /// the web page's `pipStart` arrived (the cached PiP flag lagged), so
    /// the lifecycle observer took a hold. PiP owns playback now — drop the
    /// hold without resuming, so a play from the PiP window isn't paused
    /// again. The observer's copy lapses (`releaseHold` ignores it).
    private func yieldBackgroundHoldToPictureInPicture() {
        guard controller.isPictureInPictureActive, currentHolds[.background] != nil else { return }
        currentHolds[.background] = nil
        controller.endHold(.background, resume: false)
    }

    private func advanceGeneration() {
        generation += 1
        currentHolds.removeAll()
        controller.endAllHolds()
    }

    // MARK: Hosts

    /// Bumped when the engine changes so hosts re-attach.
    private(set) var hostRevision = 0

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
