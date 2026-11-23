import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.FFZ")

/// FrankerFaceZ emote provider.
///
/// API endpoints:
///   - Global:  https://api.frankerfacez.com/v1/set/global
///   - Channel: https://api.frankerfacez.com/v1/room/<broadcasterLogin>
///
/// **FFZ keys channel endpoints by Twitch login**, not by broadcaster_user_id —
/// the reason the unified `EmoteProvider.channelEmotes(broadcasterId:broadcasterLogin:)`
/// signature exists. 7TV and BTTV ignore the login; this provider uses it.
///
/// FFZ ships static PNG by default; some emotes have animated variants
/// (newer addition). We prefer the animated URL set when present so a
/// future animated renderer has access; static-only rendering today
/// shows the first frame via ImageIO's WebP/GIF decode.
public struct FFZProvider: EmoteProvider {
    private let urlSession: URLSession

    public var emoteSource: Emote.Source? { .ffz }

    public init(urlSession: URLSession = EmoteProviderTransport.session) {
        self.urlSession = urlSession
    }

    public func globalEmotes() async throws -> [Emote] {
        let (data, response) = try await urlSession.data(from: Endpoints.FFZ.globalSet)
        try ProviderHTTP.requireSuccess(response)
        let body = try JSONDecoder().decode(GlobalResponse.self, from: data)
        // Only load `default_sets` when FFZ provides them (other sets in the
        // payload are user/tier-restricted sets, not truly global). Fall back
        // to sorted keys when `default_sets` is absent (e.g. minimal fixtures).
        let orderedSets: [EmoteSet]
        if let defaultIds = body.default_sets, !defaultIds.isEmpty {
            orderedSets = defaultIds.compactMap { body.sets[String($0)] }
        } else {
            orderedSets = body.sets.keys.sorted().compactMap { body.sets[$0] }
        }
        return orderedSets.flatMap {
            $0.emoticons.compactMap { Self.map($0, ownerChannelId: nil) }
        }
    }

    public func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        // FFZ requires login (lowercase Twitch username), not id.
        let (data, response) = try await urlSession.data(from: Endpoints.FFZ.roomByLogin(broadcasterLogin))
        // FFZ returns 404 if the channel hasn't been registered with FFZ —
        // common, like BTTV's 404 case. Other non-2xx statuses throw.
        if try ProviderHTTP.isNotFound(response) { return [] }
        let body = try JSONDecoder().decode(RoomResponse.self, from: data)
        return body.sets.keys.sorted().compactMap { body.sets[$0] }.flatMap {
            $0.emoticons.compactMap { Self.map($0, ownerChannelId: broadcasterId) }
        }
    }

    // MARK: - Private decoding shapes

    private struct GlobalResponse: Decodable {
        let default_sets: [Int]?
        let sets: [String: EmoteSet]
    }

    private struct RoomResponse: Decodable {
        let sets: [String: EmoteSet]
    }

    private struct EmoteSet: Decodable {
        let emoticons: [EmoteJSON]
    }

    private struct EmoteJSON: Decodable {
        /// FFZ ids are integers (vs 7TV/BTTV's hex strings) — we stringify
        /// at the `Emote.id` boundary to keep the unified type uniform.
        let id: Int
        let name: String
        /// Static URL set, keyed by size: "1" / "2" / "4" → URL string.
        let urls: [String: String]?
        /// Animated URL set (added in a later FFZ API revision). Present
        /// only for animated emotes; nil for the majority.
        let animated: [String: String]?
        /// 1x pixel dimensions, reported at the emoticon level. Drives
        /// `Emote.aspectRatio` for natural-width rendering.
        let width: Int?
        let height: Int?
    }

    private static func map(_ j: EmoteJSON, ownerChannelId: String?) -> Emote? {
        // Prefer animated URLs when the emote actually has non-empty animated
        // variants (some FFZ responses send `"animated": {}`). Fall back to
        // static `urls` otherwise so the emote isn't silently dropped.
        let animatedURLs = j.animated.map(Self.sizedURLs) ?? [:]
        let staticURLs = Self.sizedURLs(j.urls ?? [:])
        let hasAnimated = !animatedURLs.isEmpty
        let urls = hasAnimated ? animatedURLs : staticURLs
        guard !urls.isEmpty else { return nil }

        let aspectRatio: Double? = if let w = j.width, let h = j.height, w > 0, h > 0 {
            Double(w) / Double(h)
        } else {
            nil
        }

        return Emote(
            id: "ffz:\(j.id)",
            name: j.name,
            urls: urls,
            isAnimated: hasAnimated,
            isZeroWidth: false,                 // FFZ has no zero-width emotes.
            source: .ffz,
            ownerChannelId: ownerChannelId,
            aspectRatio: aspectRatio,
            staticURLs: hasAnimated && !staticURLs.isEmpty ? staticURLs : nil
        )
    }

    /// FFZ's size-keyed URL map ("1" / "2" / "4") as `Emote.Size` → URL.
    private static func sizedURLs(_ urlMap: [String: String]) -> [Emote.Size: URL] {
        var urls: [Emote.Size: URL] = [:]
        for (key, value) in urlMap {
            let size: Emote.Size? = switch key {
            case "1": .x1
            case "2": .x2
            case "4": .x4
            default: nil
            }
            // FFZ URLs sometimes come back protocol-relative ("//cdn..."),
            // mirror 7TV's normalization.
            let normalized = value.hasPrefix("//") ? "https:" + value : value
            if let size, let url = URL(string: normalized) {
                urls[size] = url
            }
        }
        return urls
    }
}
