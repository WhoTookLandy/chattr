/// Where the app's one stream is, as a single value: read-only, derived
/// from the flags `PlaybackCenter` and its `StreamPlayerController` already
/// keep (`PlaybackCenter.phase`). Something to switch on instead of
/// combining those flags; nothing is stored or driven from it.
///
/// Two things it doesn't say. Which engine is playing: a stream that fell
/// back to the web player is still loading, playing or paused, and
/// `StreamPlayerController.nativeFailed` says the rest. And "ended": a
/// broadcast that ends stops the player (`PlaybackCenter.stop`), so it
/// reads as `.idle`.
enum PlaybackPhase: Equatable, Sendable {
    /// Nothing is loaded.
    case idle
    /// A stream is loaded and on its way to its first frame: the web page
    /// loading, the playlist resolving, the first buffer filling.
    case loading
    /// It was playing and the native player is waiting on the network: a
    /// stall, or the wait between tries after a failure.
    case buffering
    case playing
    /// Paused with its engine in place — by the user, or by a hold
    /// (`PlaybackCenter.holdPlayback`).
    case paused
    /// Paused so long its engine was given up
    /// (`PlaybackCenter.unloadAfterLongPause`). Still the loaded stream;
    /// play builds the engine again.
    case unloaded

    /// - Parameters:
    ///   - isLoaded: `PlaybackCenter.channel` is set.
    ///   - hasEngine: `PlaybackCenter.engine` is.
    ///   - isPaused, hasStarted, isBuffering: the controller's flags of the
    ///     same names.
    static func resolve(
        isLoaded: Bool,
        hasEngine: Bool,
        isPaused: Bool,
        hasStarted: Bool,
        isBuffering: Bool
    ) -> PlaybackPhase {
        guard isLoaded else { return .idle }
        guard hasEngine else { return .unloaded }
        // Before `isPaused`: between tries the failed player reports
        // paused, and the stream is still on its way back.
        if isBuffering { return hasStarted ? .buffering : .loading }
        if isPaused { return .paused }
        return hasStarted ? .playing : .loading
    }
}

#if os(iOS)
extension PlaybackCenter {
    /// Where playback is right now. Observable like the flags it's made
    /// of: a view that reads it re-renders when it changes.
    var phase: PlaybackPhase {
        // `engine` isn't observed. `hostRevision` is, and is bumped with
        // every change of engine, so reading it keeps `.unloaded` (which no
        // observed flag need change for) in step for an observer.
        _ = hostRevision
        return PlaybackPhase.resolve(
            isLoaded: channel != nil,
            hasEngine: engine != nil,
            isPaused: controller.isPaused,
            hasStarted: controller.hasStarted,
            isBuffering: controller.isBuffering
        )
    }
}
#endif
