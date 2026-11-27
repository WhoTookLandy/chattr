#if os(iOS)
import MediaPlayer

/// Lock screen / Control Center presence for native audio streams that keep
/// playing with the app in the background (pinned background audio slots,
/// plus primary when in native audio-only mode).
///
/// Remote command targets resolve current eligible slots dynamically through
/// `PlaybackCenter` rather than capturing a single `StreamPlayerController`,
/// so promoting/demoting or pinning/unpinning never leaves stale handlers,
/// and mixed paused/playing slots are unified rather than inverted.
@MainActor
final class StreamNowPlaying {
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var isPublished = false

    struct Summary: Equatable, Sendable {
        let title: String
        let artist: String
        let isPaused: Bool
    }

    static func summarize(slots: [PlaybackSlot]) -> Summary? {
        guard let first = slots.first else { return nil }
        let anyPlaying = slots.contains { !$0.controller.isPaused }
        if slots.count == 1 {
            let name = first.channel.channelDisplayName
            let trimmed = first.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Summary(
                title: trimmed.isEmpty ? name : trimmed,
                artist: name,
                isPaused: !anyPlaying
            )
        }
        let others = slots.count - 1
        let firstName = first.channel.channelDisplayName
        return Summary(
            title: "\(firstName) + \(others) more",
            artist: "chattr · \(slots.count) live streams",
            isPaused: !anyPlaying
        )
    }

    func publish(summary: Summary, center: PlaybackCenter) {
        if !isPublished {
            isPublished = true
            let commands = MPRemoteCommandCenter.shared()
            register(commands.playCommand) { [weak center] in center?.remotePlayBackgroundAudio() }
            register(commands.pauseCommand) { [weak center] in center?.remotePauseBackgroundAudio() }
            register(commands.togglePlayPauseCommand) { [weak center] in center?.remoteTogglePlayPauseBackgroundAudio() }
        }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: summary.title,
            MPMediaItemPropertyArtist: summary.artist,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: summary.isPaused ? 0.0 : 1.0,
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
