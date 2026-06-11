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

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func globalEmotes() async throws -> [Emote] {
        let (data, _) = try await urlSession.data(from: Endpoints.FFZ.globalSet)
        let response = try JSONDecoder().decode(GlobalResponse.self, from: data)
        // `sets` is a dict keyed by set ID — flatten emoticons across all sets.
        // FFZ may use multiple global sets for organization, but for chat
        // resolution they all behave the same.
        return response.sets.values.flatMap {
            $0.emoticons.compactMap { Self.map($0, ownerChannelId: nil) }
        }
    }

    public func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        // FFZ requires login (lowercase Twitch username), not id.
        let (data, response) = try await urlSession.data(from: Endpoints.FFZ.roomByLogin(broadcasterLogin))
        // FFZ returns 404 if the channel hasn't been registered with FFZ —
        // common, like BTTV's 404 case.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return [] }
        let body = try JSONDecoder().decode(RoomResponse.self, from: data)
        return body.sets.values.flatMap {
            $0.emoticons.compactMap { Self.map($0, ownerChannelId: broadcasterId) }
        }
    }

    // MARK: - Private decoding shapes

    private struct GlobalResponse: Decodable {
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
        // Prefer animated URLs when the emote has them — even in static-only
        // rendering mode, the first frame is what gets shown. Falling back
        // to `urls` (static set) when no animated variant exists.
        let urlMap = j.animated ?? j.urls ?? [:]
        guard !urlMap.isEmpty else { return nil }

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
            isAnimated: j.animated != nil,
            isZeroWidth: false,                 // FFZ has no zero-width emotes.
            source: .ffz,
            ownerChannelId: ownerChannelId,
            aspectRatio: aspectRatio
        )
    }
}
