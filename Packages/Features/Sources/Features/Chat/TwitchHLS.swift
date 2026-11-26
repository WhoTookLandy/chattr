#if os(iOS)
import Foundation
import Core
import Accounts

/// Resolves a channel's live HLS playlist the way twitch.tv's own web
/// player does: a playback access token from Twitch's GQL endpoint (public
/// web client ID), then the usher playlist signed with it.
///
/// Not an official third-party API — Twitch can change or block it at any
/// time, which is why the native player is opt-in, falls back to the web
/// player when it keeps failing, and can be switched off altogether
/// (`PlayerSettings.isNativePlaybackEnabled`). The native engine reaches it
/// only through `StreamPlaylistResolving`.
///
/// Signed in for ad-free playback (`TwitchPlaybackSession`, or a twitch.tv
/// website session, `TwitchWebSession`), the token is asked for as that
/// viewer, so their subscriptions and Turbo apply and ads don't play where
/// those cover them. Otherwise, or if Twitch won't take the session, it's
/// asked for logged out.
enum TwitchHLS {
    /// Who a playback token is asked for as: a token and the client it was
    /// issued to, which GQL wants to match.
    struct Auth: Equatable, Sendable {
        let token: String
        let clientId: String
    }

    /// Shared short-lived playlist cache across native playback surfaces.
    static let sharedCache = StreamPlaylistCache()

    /// The resolver the native engine uses unless it's handed another.
    struct Resolver: StreamPlaylistResolving {
        /// Read per playlist, so signing in or out applies to the next
        /// stream. nil: logged out.
        var auth: @Sendable () async -> Auth? = { await TwitchHLS.currentAuth() }
        /// A renewed `Auth` after Twitch rejected one, or nil.
        var renewAuth: @Sendable (Auth) async -> Auth? = { await TwitchHLS.renewedAuth(after: $0) }
        var cache: StreamPlaylistCache = TwitchHLS.sharedCache

        func playlist(login: String, audioOnly: Bool) async throws -> StreamPlaylist {
            try await TwitchHLS.playlist(
                login: login,
                audioOnly: audioOnly,
                auth: await auth(),
                renewAuth: renewAuth,
                cache: cache
            )
        }

        func warmAudioOnlyVariant(for masterURL: URL, login: String) async throws -> AudioOnlyVariantProbe {
            let probe = try await TwitchHLS.probeAudioOnlyVariant(in: masterURL)
            switch probe {
            case .available(let variant):
                await cache.recordAudioOnlyProbe(login: login, masterURL: masterURL, audioOnlyURL: variant)
            case .unavailable:
                await cache.recordAudioOnlyProbe(login: login, masterURL: masterURL, audioOnlyURL: nil)
            case .failed:
                break
            }
            return probe
        }

        func invalidate(login: String) async {
            await cache.invalidate(login: login)
        }
    }

    static let webClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    /// The ad-free session to play as: the device-code sign-in first, then
    /// a twitch.tv website session from the sign-in page fallback.
    static func currentAuth() async -> Auth? {
        // A Keychain read: kept off the main actor.
        let session = await Task.detached(priority: .userInitiated) { TwitchPlaybackSession.current() }.value
        if let session {
            return Auth(token: session.accessToken, clientId: session.clientId)
        }
        if let web = await TwitchWebSession.current() {
            return Auth(token: web.token, clientId: webClientID)
        }
        return nil
    }

    /// Only the device-code session can be renewed; a website session
    /// that's been rejected needs signing in again.
    static func renewedAuth(after rejected: Auth) async -> Auth? {
        guard rejected.clientId == TwitchPlaybackSession.clientId,
              let renewed = await TwitchPlaybackSession.refresh(rejected: rejected.token)
        else { return nil }
        return Auth(token: renewed.accessToken, clientId: renewed.clientId)
    }

    /// GQL said the attached token itself is no good (HTTP 401).
    private struct AuthRejected: Error {}

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

    /// The playback access token request for `login`, as `auth` when
    /// there is one, otherwise logged out under the web client.
    static func tokenRequest(login: String, auth: Auth?) throws -> URLRequest {
        var request = URLRequest(url: Endpoints.TwitchPlayer.playbackAccessToken)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth, !auth.token.isEmpty {
            request.setValue(auth.clientId, forHTTPHeaderField: "Client-ID")
            request.setValue("OAuth \(auth.token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(webClientID, forHTTPHeaderField: "Client-ID")
        }
        let body: [String: Any] = [
            "query": query,
            "variables": ["login": login],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func playlist(
        login: String,
        audioOnly: Bool = false,
        auth: Auth? = nil,
        renewAuth: @Sendable (Auth) async -> Auth? = { _ in nil },
        cache: StreamPlaylistCache? = nil
    ) async throws -> StreamPlaylist {
        let fingerprint = authFingerprint(for: auth)
        if let cache, let cached = await cache.entry(for: login, authFingerprint: fingerprint) {
            if !audioOnly {
                return StreamPlaylist(
                    url: cached.masterURL,
                    isAudioOnlyRendition: false,
                    masterURL: cached.masterURL,
                    audioOnlyURL: cached.audioOnlyURL,
                    didProbeAudioOnly: cached.didProbeAudioOnly
                )
            }
            if cached.didProbeAudioOnly {
                if let variant = cached.audioOnlyURL {
                    return StreamPlaylist(
                        url: variant,
                        isAudioOnlyRendition: true,
                        masterURL: cached.masterURL,
                        audioOnlyURL: variant,
                        didProbeAudioOnly: true
                    )
                }
                return StreamPlaylist(
                    url: cached.masterURL,
                    isAudioOnlyRendition: false,
                    masterURL: cached.masterURL,
                    audioOnlyURL: nil,
                    didProbeAudioOnly: true
                )
            }
            // Master URL is cached from video mode; try probing its audio_only
            // variant before falling back to a fresh GQL token.
            do {
                let probe = try await probeAudioOnlyVariant(in: cached.masterURL)
                switch probe {
                case .available(let variant):
                    await cache.recordAudioOnlyProbe(login: login, masterURL: cached.masterURL, audioOnlyURL: variant)
                    return StreamPlaylist(
                        url: variant,
                        isAudioOnlyRendition: true,
                        masterURL: cached.masterURL,
                        audioOnlyURL: variant,
                        didProbeAudioOnly: true
                    )
                case .unavailable:
                    await cache.recordAudioOnlyProbe(login: login, masterURL: cached.masterURL, audioOnlyURL: nil)
                    return StreamPlaylist(
                        url: cached.masterURL,
                        isAudioOnlyRendition: false,
                        masterURL: cached.masterURL,
                        audioOnlyURL: nil,
                        didProbeAudioOnly: true
                    )
                case .failed:
                    return StreamPlaylist(
                        url: cached.masterURL,
                        isAudioOnlyRendition: false,
                        masterURL: cached.masterURL,
                        audioOnlyURL: nil,
                        didProbeAudioOnly: false
                    )
                }
            } catch StreamPlaylistError.forbidden {
                // Cached token expired: clear and resolve a fresh one below.
                await cache.invalidate(login: login)
            }
        }

        let token = try await accessToken(login: login, auth: auth, renewAuth: renewAuth)

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
        guard audioOnly else {
            await cache?.store(
                login: login,
                masterURL: url,
                audioOnlyURL: nil,
                didProbeAudioOnly: false,
                authFingerprint: fingerprint
            )
            return StreamPlaylist(
                url: url,
                isAudioOnlyRendition: false,
                masterURL: url,
                audioOnlyURL: nil,
                didProbeAudioOnly: false
            )
        }
        // Audio-only: pick the `audio_only` variant out of the master
        // playlist. If Twitch didn't offer one, the full stream still plays.
        switch try await probeAudioOnlyVariant(in: url) {
        case .available(let variant):
            await cache?.store(
                login: login,
                masterURL: url,
                audioOnlyURL: variant,
                didProbeAudioOnly: true,
                authFingerprint: fingerprint
            )
            return StreamPlaylist(
                url: variant,
                isAudioOnlyRendition: true,
                masterURL: url,
                audioOnlyURL: variant,
                didProbeAudioOnly: true
            )
        case .unavailable:
            await cache?.store(
                login: login,
                masterURL: url,
                audioOnlyURL: nil,
                didProbeAudioOnly: true,
                authFingerprint: fingerprint
            )
            return StreamPlaylist(
                url: url,
                isAudioOnlyRendition: false,
                masterURL: url,
                audioOnlyURL: nil,
                didProbeAudioOnly: true
            )
        case .failed:
            await cache?.store(
                login: login,
                masterURL: url,
                audioOnlyURL: nil,
                didProbeAudioOnly: false,
                authFingerprint: fingerprint
            )
            return StreamPlaylist(
                url: url,
                isAudioOnlyRendition: false,
                masterURL: url,
                audioOnlyURL: nil,
                didProbeAudioOnly: false
            )
        }
    }

    private static func authFingerprint(for auth: Auth?) -> String {
        guard let auth, !auth.token.isEmpty else { return "anon" }
        return "\(auth.clientId):\(auth.token)"
    }

    /// As `auth`; renewed once if Twitch rejects it; failing that, logged
    /// out, so a stale session costs ad-free playback, not the stream.
    /// Signing in again in Settings brings ad-free back.
    private static func accessToken(
        login: String,
        auth: Auth?,
        renewAuth: @Sendable (Auth) async -> Auth?
    ) async throws -> (value: String, signature: String) {
        guard let auth else { return try await requestToken(login: login, auth: nil) }
        do {
            return try await requestToken(login: login, auth: auth)
        } catch is AuthRejected {
            if let renewed = await renewAuth(auth),
               let token = try? await requestToken(login: login, auth: renewed) {
                return token
            }
            return try await requestToken(login: login, auth: nil)
        } catch is StreamPlaylistError {
            // Twitch answered the session with no token (it may not take
            // this client's tokens at all): play logged out instead.
            return try await requestToken(login: login, auth: nil)
        }
    }

    private static func requestToken(login: String, auth: Auth?) async throws -> (value: String, signature: String) {
        let request = try tokenRequest(login: login, auth: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        if auth != nil, (response as? HTTPURLResponse)?.statusCode == 401 {
            throw AuthRejected()
        }
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
        return (token.value, token.signature)
    }

    /// Probes the master playlist for an `audio_only` variant, distinguishing
    /// a confirmed absence from a transient fetch error so callers only cache
    /// confirmed results. Throws only for what Twitch's status says outright:
    /// offline, or refused.
    static func probeAudioOnlyVariant(in master: URL) async throws -> AudioOnlyVariantProbe {
        guard let (data, response) = try? await URLSession.shared.data(from: master) else {
            return .failed
        }
        guard let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200:
            guard let text = String(data: data, encoding: .utf8) else { return .failed }
            if let variant = HLSMasterPlaylist.audioOnlyVariant(in: text, relativeTo: master) {
                return .available(variant)
            }
            return .unavailable
        case 404:
            throw StreamPlaylistError.offline
        case 401, 403:
            throw StreamPlaylistError.forbidden
        default:
            return .failed
        }
    }
}
#endif
