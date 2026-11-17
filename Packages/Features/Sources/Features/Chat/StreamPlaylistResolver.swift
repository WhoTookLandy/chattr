import Foundation

/// A channel's live HLS playlist, resolved for the native player.
struct StreamPlaylist: Equatable, Sendable {
    let url: URL
    /// `url` is Twitch's audio-only rendition. False for the full stream —
    /// including when audio-only was asked for and Twitch offered no such
    /// rendition, so the video plays (unseen) alongside the audio.
    let isAudioOnlyRendition: Bool
}

/// Why a playlist couldn't be resolved, as far as Twitch said.
enum StreamPlaylistError: Error, Equatable {
    /// The channel isn't live.
    case offline
    /// Twitch won't hand this stream out (no playback token, or 401 / 403).
    case forbidden
    /// An answer that made no sense. Unlike the two above, worth asking again.
    case unavailable
}

/// Resolves a channel's playlist for the native player. A protocol so the
/// native engine doesn't name Twitch's unofficial endpoints itself
/// (`TwitchHLS` is the default) and tests can stand one in.
protocol StreamPlaylistResolving: Sendable {
    func playlist(login: String, audioOnly: Bool) async throws -> StreamPlaylist
}

/// The one thing the native player reads out of an HLS master playlist
/// itself.
enum HLSMasterPlaylist {
    /// The `audio_only` variant's playlist in `text`, resolved against
    /// `master`. nil when the master playlist doesn't list one.
    static func audioOnlyVariant(in text: String, relativeTo master: URL) -> URL? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        for (index, line) in lines.enumerated()
        where line.hasPrefix("#EXT-X-STREAM-INF") && line.contains("audio_only") {
            guard index + 1 < lines.count else { return nil }
            let uri = lines[index + 1].trimmingCharacters(in: .whitespaces)
            return URL(string: uri, relativeTo: master)?.absoluteURL
        }
        return nil
    }
}
