#if os(iOS)
import Foundation
import Core

/// Resolves a channel's live HLS playlist the way twitch.tv's own web
/// player does: a playback access token from Twitch's GQL endpoint (public
/// web client ID), then the usher playlist signed with it.
///
/// Not an official third-party API — Twitch can change or block it at any
/// time, which is why the native player is opt-in, falls back to the web
/// player when it keeps failing, and can be switched off altogether
/// (`PlayerSettings.isNativePlaybackEnabled`). The native engine reaches it
/// only through `StreamPlaylistResolving`.
enum TwitchHLS {
    /// The resolver the native engine uses unless it's handed another.
    struct Resolver: StreamPlaylistResolving {
        func playlist(login: String, audioOnly: Bool) async throws -> StreamPlaylist {
            try await TwitchHLS.playlist(login: login, audioOnly: audioOnly)
        }
    }

    private static let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    private static let query = """
    query PlaybackAccessToken($login: String!) {
      streamPlaybackAccessToken(channelName: $login, params: {platform: "ios", playerBackend: "mediaplayer", playerType: "site"}) {
        value
        signature
      }
    }
    """

    private struct Response: Decodable {
        struct DataField: Decodable {
            struct Token: Decodable {
                let value: String
                let signature: String
            }
            let streamPlaybackAccessToken: Token?
        }
        let data: DataField?
    }

    static func playlist(login: String, audioOnly: Bool = false) async throws -> StreamPlaylist {
        var request = URLRequest(url: Endpoints.TwitchPlayer.playbackAccessToken)
        request.httpMethod = "POST"
        request.setValue(webClientID, forHTTPHeaderField: "Client-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": query,
            "variables": ["login": login],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        // Refused outright: not worth asking again, unlike an answer that
        // made no sense.
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 401 || status == 403 {
            throw StreamPlaylistError.forbidden
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let fields = try JSONDecoder().decode(Response.self, from: data).data
        else { throw StreamPlaylistError.unavailable }
        // Answered, but with no token: a channel that doesn't exist, or
        // one Twitch won't play for this client.
        guard let token = fields.streamPlaybackAccessToken else { throw StreamPlaylistError.forbidden }

        guard let playlistURL = Endpoints.TwitchPlayer.livePlaylist(login: login),
              var components = URLComponents(url: playlistURL, resolvingAgainstBaseURL: false)
        else { throw StreamPlaylistError.unavailable }
        components.queryItems = [
            URLQueryItem(name: "sig", value: token.signature),
            URLQueryItem(name: "token", value: token.value),
            URLQueryItem(name: "allow_source", value: "true"),
            URLQueryItem(name: "allow_audio_only", value: "true"),
            URLQueryItem(name: "fast_bread", value: "true"),
            URLQueryItem(name: "player_backend", value: "mediaplayer"),
            URLQueryItem(name: "playlist_include_framerate", value: "true"),
            URLQueryItem(name: "supported_codecs", value: "avc1"),
            URLQueryItem(name: "p", value: String(Int.random(in: 1_000_000...9_999_999))),
        ]
        guard let url = components.url else { throw StreamPlaylistError.unavailable }
        guard audioOnly else { return StreamPlaylist(url: url, isAudioOnlyRendition: false) }
        // Audio-only: pick the `audio_only` variant out of the master
        // playlist. If Twitch didn't offer one, the full stream still plays.
        if let variant = try await audioOnlyVariant(in: url) {
            return StreamPlaylist(url: variant, isAudioOnlyRendition: true)
        }
        return StreamPlaylist(url: url, isAudioOnlyRendition: false)
    }

    /// nil when the master playlist lists no audio-only variant, or
    /// couldn't be read at all (the player then loads it itself). Throws
    /// only for what Twitch's status says outright: offline, or refused.
    private static func audioOnlyVariant(in master: URL) async throws -> URL? {
        guard let (data, response) = try? await URLSession.shared.data(from: master) else { return nil }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 404: throw StreamPlaylistError.offline
        case 401, 403: throw StreamPlaylistError.forbidden
        default: break
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: master)
    }
}
#endif
