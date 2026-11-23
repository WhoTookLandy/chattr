#if os(iOS)
/// Why the stream is held paused (`PlaybackCenter.holdPlayback(_:)`).
enum PlaybackHoldReason: Hashable, Sendable {
    /// A clip is playing over the stream (`ClipPlayerSheet`).
    case clip
    /// The app is in the background and the stream can't continue there
    /// (no PiP, not audio-only with sound — `PlaybackLifecycleObserver`).
    case background
    /// The user unmuted an inline Home feed preview while another stream was
    /// playing (e.g. in the audio-only mini player).
    case feedPreview
}
#endif
