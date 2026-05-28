import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.SevenTV")

/// 7TV emote provider.
///
/// API endpoints:
///   - Global:  https://7tv.io/v3/emote-sets/global
///   - Channel: https://7tv.io/v3/users/twitch/<broadcasterId> → user object
///              whose `emote_set.emotes` is the channel set.
///
/// 7TV serves emotes primarily as WebP (animated) with AVIF as a fallback.
/// We pick the WebP variants for x1/x2/x4 sizes and rely on iOS's native
/// ImageIO WebP decoding (static-only on iOS — the first frame is shown).
/// Animation lands in a follow-up; the `isAnimated` flag is preserved on
/// the `Emote` for the renderer to act on later.
public struct SevenTVProvider: EmoteProvider {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func globalEmotes() async throws -> [Emote] {
        let url = URL(string: "https://7tv.io/v3/emote-sets/global")!
        let (data, _) = try await urlSession.data(from: url)
        let response = try JSONDecoder().decode(EmoteSetResponse.self, from: data)
        return response.emotes.compactMap { Self.map($0, ownerChannelId: nil) }
    }

    public func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        // 7TV keys channel endpoints by Twitch broadcaster id — login is ignored
        // here (FFZ is the provider that needs login; the unified signature
        // exists so EmoteIndex can call all three providers the same way).
        let url = URL(string: "https://7tv.io/v3/users/twitch/\(broadcasterId)")!
        let (data, response) = try await urlSession.data(from: url)
        // 7TV returns 404 if the Twitch user hasn't connected to 7TV. Graceful empty.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return [] }
        let user = try JSONDecoder().decode(UserResponse.self, from: data)
        return user.emote_set?.emotes.compactMap { Self.map($0, ownerChannelId: broadcasterId) } ?? []
    }

    // MARK: - Private decoding shapes
    //
    // These mirror 7TV v3's JSON only as far as we need. Adding more fields
    // here is cheap — but every field we declare is a contract we must
    // keep working if the API drifts, so we keep the surface minimal.

    private struct UserResponse: Decodable {
        let emote_set: EmoteSetResponse?
    }

    private struct EmoteSetResponse: Decodable {
        let emotes: [EmoteJSON]
    }

    private struct EmoteJSON: Decodable {
        let id: String
        let name: String
        /// Bit flags. 0x01 = zero-width (overlays previous emote).
        let flags: Int?
        let data: EmoteData?
    }

    private struct EmoteData: Decodable {
        let host: EmoteHost?
        /// `true` when at least one variant is animated. 7TV exposes this
        /// at the data level (not per-file) since animation is a property
        /// of the source asset.
        let animated: Bool?
    }

    private struct EmoteHost: Decodable {
        /// CDN base URL. Sometimes returned as `//cdn.7tv.app/emote/<id>`
        /// (protocol-relative) — we normalize to `https://` in `map(...)`.
        let url: String
        let files: [EmoteFile]
    }

    private struct EmoteFile: Decodable {
        /// File leaf, e.g. "1x.webp", "2x.webp", "4x.webp", "1x.avif".
        let name: String
        /// "WEBP", "AVIF", "PNG", etc.
        let format: String
    }

    /// Convert a raw 7TV emote JSON record into our unified `Emote` value.
    /// Returns nil for records we can't fully resolve (missing host or no
    /// usable size variants) — better to skip than emit a half-rendered
    /// row that later 404s in the UI.
    private static func map(_ j: EmoteJSON, ownerChannelId: String?) -> Emote? {
        guard let host = j.data?.host else { return nil }
        // 7TV's CDN URLs sometimes come back protocol-relative ("//cdn...").
        // Normalize to https:// so URL(string:) doesn't choke.
        let hostURL = host.url.hasPrefix("//") ? "https:" + host.url : host.url

        // Pick the WebP variants for x1/x2/x4. WebP is 7TV's primary
        // delivery format (AVIF is a fallback and the gif equivalents are
        // historical). iOS 14+ ImageIO can decode static WebP natively, so
        // AsyncImage handles these without an extra dependency.
        var urls: [Emote.Size: URL] = [:]
        let webpFiles = host.files.filter { $0.format == "WEBP" }
        for file in webpFiles {
            let size: Emote.Size? = switch file.name {
            case "1x.webp": .x1
            case "2x.webp": .x2
            case "4x.webp": .x4
            default: nil
            }
            if let size, let url = URL(string: "\(hostURL)/\(file.name)") {
                urls[size] = url
            }
        }

        guard !urls.isEmpty else { return nil }

        let flags = j.flags ?? 0
        let isZeroWidth = (flags & 0x01) != 0
        let isAnimated = j.data?.animated ?? false

        return Emote(
            id: "7tv:\(j.id)",
            name: j.name,
            urls: urls,
            isAnimated: isAnimated,
            isZeroWidth: isZeroWidth,
            source: .sevenTV,
            ownerChannelId: ownerChannelId
        )
    }
}
