#if os(iOS)
import MediaPlayer

/// Lock screen / Control Center presence for a stream that keeps playing
/// with the app in the background (audio-only on the native engine): what's
/// playing, and play / pause. Owned by `PlaybackCenter`, which publishes
/// while such a stream is loaded and clears when it goes.
@MainActor
final class StreamNowPlaying {
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var isPublished = false

    func publish(title: String, channelName: String, isPaused: Bool, controller: StreamPlayerController) {
        if !isPublished {
            isPublished = true
            let commands = MPRemoteCommandCenter.shared()
            register(commands.playCommand) { [weak controller] in controller?.remotePlay() }
            register(commands.pauseCommand) { [weak controller] in controller?.remotePause() }
            register(commands.togglePlayPauseCommand) { [weak controller] in controller?.togglePlay() }
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? channelName : title,
            MPMediaItemPropertyArtist: channelName,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func clear() {
        guard isPublished else { return }
        isPublished = false
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func register(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable () -> Void) {
        command.isEnabled = true
        let target = command.addTarget(handler: Self.handler(action))
        commandTargets.append((command, target))
    }

    /// Built outside the main actor: MediaPlayer doesn't promise the queue
    /// it calls a command handler on, and a closure made in a main-actor
    /// context would trap when called off it.
    nonisolated private static func handler(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        { _ in
            Task { @MainActor in action() }
            return .success
        }
    }
}
#endif
