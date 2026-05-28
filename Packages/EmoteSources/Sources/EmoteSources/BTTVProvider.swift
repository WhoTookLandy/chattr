import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.BTTV")

/// BetterTTV emote provider.
///
/// API endpoints:
///   - Global:  https://api.betterttv.net/3/cached/emotes/global
///   - Channel: https://api.betterttv.net/3/cached/users/twitch/<broadcasterId>
///              → user object with `channelEmotes[]` + `sharedEmotes[]`.
///
/// BTTV uses PNG (static) or GIF (animated) — both are decoded natively by
/// AsyncImage on iOS. URL pattern is:
///   https://cdn.betterttv.net/emote/<id>/{1x,2x,3x}
///
/// Note: BTTV's largest size is "3x", not "4x". We map that asset to our
/// `Emote.Size.x4` slot for consistent API across providers.
public struct BTTVProvider: EmoteProvider {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func globalEmotes() async throws -> [Emote] {
        let url = URL(string: "https://api.betterttv.net/3/cached/emotes/global")!
        let (data, _) = try await urlSession.data(from: url)
        let emotes = try JSONDecoder().decode([EmoteJSON].self, from: data)
        return emotes.compactMap { Self.map($0, ownerChannelId: nil) }
    }

    public func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote] {
        // BTTV keys by Twitch broadcaster id; login is ignored.
        let url = URL(string: "https://api.betterttv.net/3/cached/users/twitch/\(broadcasterId)")!
        let (data, response) = try await urlSession.data(from: url)
        // BTTV returns 404 for channels that don't have BTTV emotes configured.
        // That's the common case — most Twitch channels skip BTTV entirely —
        // so we treat 404 as "no emotes" rather than an error condition.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return [] }
        let user = try JSONDecoder().decode(UserResponse.self, from: data)
        // `sharedEmotes` are emotes added to the channel by other users.
        // Both arrays are channel-scope for our purposes — merge them.
        return (user.channelEmotes + user.sharedEmotes).compactMap {
            Self.map($0, ownerChannelId: broadcasterId)
        }
    }

    // MARK: - Private decoding shapes

    private struct UserResponse: Decodable {
        let channelEmotes: [EmoteJSON]
        let sharedEmotes: [EmoteJSON]
    }

    private struct EmoteJSON: Decodable {
        let id: String
        /// BTTV uses `code` (vs 7TV's `name`) — same concept: the chat token.
        let code: String
        /// "png" (static) or "gif" (animated). BTTV doesn't ship WebP.
        let imageType: String
    }

    private static func map(_ j: EmoteJSON, ownerChannelId: String?) -> Emote? {
        // BTTV's CDN URLs are predictable from the id, so we construct
        // rather than decode them. The pattern hasn't changed since BTTV
        // launched and isn't likely to.
        let base = "https://cdn.betterttv.net/emote/\(j.id)"
        guard
            let x1 = URL(string: "\(base)/1x"),
            let x2 = URL(string: "\(base)/2x"),
            let x4 = URL(string: "\(base)/3x")  // BTTV's largest size is "3x".
        else { return nil }

        return Emote(
            id: "bttv:\(j.id)",
            name: j.code,
            urls: [.x1: x1, .x2: x2, .x4: x4],
            isAnimated: j.imageType == "gif",
            isZeroWidth: false,                 // BTTV has no zero-width emotes.
            source: .bttv,
            ownerChannelId: ownerChannelId
        )
    }
}
