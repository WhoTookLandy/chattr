import Foundation

/// A channel's live HLS playlist, resolved for the native player.
struct StreamPlaylist: Equatable, Sendable {
    let url: URL
    /// `url` is Twitch's audio-only rendition. False for the full stream —
    /// including when audio-only was asked for and Twitch offered no such
    /// rendition, so the video plays (unseen) alongside the audio.
    let isAudioOnlyRendition: Bool
    /// The channel's master HLS playlist (containing all video + audio
    /// variants). Kept alongside an audio-only rendition so switching back to
    /// video skips auth, GQL token and Usher round-trips.
    let masterURL: URL
    /// Twitch's `audio_only` media playlist URL when already extracted from
    /// `masterURL`, so switching from video to audio-only skips re-resolving.
    let audioOnlyURL: URL?
    /// True once `masterURL` has been inspected for an `audio_only` variant
    /// (whether one was found or confirmed absent).
    let didProbeAudioOnly: Bool

    init(
        url: URL,
        isAudioOnlyRendition: Bool,
        masterURL: URL? = nil,
        audioOnlyURL: URL? = nil,
        didProbeAudioOnly: Bool? = nil
    ) {
        self.url = url
        self.isAudioOnlyRendition = isAudioOnlyRendition
        self.masterURL = masterURL ?? url
        let resolvedAudioOnly = audioOnlyURL ?? (isAudioOnlyRendition ? url : nil)
        self.audioOnlyURL = resolvedAudioOnly
        self.didProbeAudioOnly = didProbeAudioOnly ?? (resolvedAudioOnly != nil)
    }
}

/// Result of inspecting a master HLS playlist for an `audio_only` variant.
enum AudioOnlyVariantProbe: Equatable, Sendable {
    /// The master playlist listed an `audio_only` media playlist.
    case available(URL)
    /// The master playlist was fetched cleanly and listed no `audio_only` variant.
    case unavailable
    /// The master playlist couldn't be fetched transiently; try again later.
    case failed
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
    /// Probes an already-resolved master playlist for its `audio_only` variant
    /// and caches the result when confirmed.
    func warmAudioOnlyVariant(for masterURL: URL, login: String) async throws -> AudioOnlyVariantProbe
    /// Evicts any cached playlist for `login` so the next resolve fetches a
    /// fresh playback token.
    func invalidate(login: String) async
}

extension StreamPlaylistResolving {
    func warmAudioOnlyVariant(for masterURL: URL, login: String) async throws -> AudioOnlyVariantProbe {
        .failed
    }

    func invalidate(login: String) async {}
}

/// Short-lived per-channel cache of resolved HLS master + audio-only URLs.
///
/// Twitch playback tokens stay valid for ~15–20 minutes; keeping the resolved
/// master URL and parsed `audio_only` variant URL for a few minutes lets
/// audio-only ↔ video switches skip Keychain/cookie reads, GQL token requests,
/// and Usher master-playlist fetches. Any playback failure invalidates the
/// entry so retries always fetch fresh credentials.
actor StreamPlaylistCache {
    struct Entry: Equatable, Sendable {
        let masterURL: URL
        var audioOnlyURL: URL?
        var didProbeAudioOnly: Bool
        let authFingerprint: String
        let fetchedAt: ContinuousClock.Instant
    }

    static let defaultTTL: Duration = .seconds(600)

    private var entries: [String: Entry] = [:]
    private let ttl: Duration

    init(ttl: Duration = defaultTTL) {
        self.ttl = ttl
    }

    func entry(
        for login: String,
        authFingerprint: String,
        now: ContinuousClock.Instant = .now
    ) -> Entry? {
        let key = login.lowercased()
        guard let entry = entries[key] else { return nil }
        guard entry.authFingerprint == authFingerprint, now - entry.fetchedAt < ttl else {
            entries[key] = nil
            return nil
        }
        return entry
    }

    func store(
        login: String,
        masterURL: URL,
        audioOnlyURL: URL?,
        didProbeAudioOnly: Bool,
        authFingerprint: String,
        now: ContinuousClock.Instant = .now
    ) {
        entries[login.lowercased()] = Entry(
            masterURL: masterURL,
            audioOnlyURL: audioOnlyURL,
            didProbeAudioOnly: didProbeAudioOnly,
            authFingerprint: authFingerprint,
            fetchedAt: now
        )
    }

    func recordAudioOnlyProbe(
        login: String,
        masterURL: URL,
        audioOnlyURL: URL?
    ) {
        let key = login.lowercased()
        guard var existing = entries[key], existing.masterURL == masterURL else { return }
        existing.audioOnlyURL = audioOnlyURL
        existing.didProbeAudioOnly = true
        entries[key] = existing
    }

    func invalidate(login: String) {
        entries[login.lowercased()] = nil
    }

    func invalidateAll() {
        entries.removeAll()
    }
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
