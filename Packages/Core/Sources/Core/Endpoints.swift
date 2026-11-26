import Foundation

/// Single audit point for every URL chattr talks to.
///
/// ## Why this exists
///
/// Hardcoded URLs scattered across providers/views make three things hard:
///
///   1. **Audit**: "what services does this app contact?" → required for
///      App Store privacy disclosures, security review, debugging
///      connectivity issues. A grep is fragile when URLs are templated.
///
///   2. **Environment switching**: staging the OAuth bridge to a different
///      Vercel deployment, or pointing third-party emote APIs at a local
///      mirror for offline development. Centralized URLs become one-line
///      changes; scattered URLs become a refactor.
///
///   3. **Drift risk**: if 7TV moves their endpoint (they did, once —
///      pre-v3), only one file needs updating.
///
/// ## What's NOT here
///
///   - SPM dependency URLs in `Package.swift` (those are build-time, not
///     runtime — different audit category)
///   - Test fixture URLs (tests SHOULD pin to specific endpoints; abstracting
///     them defeats the purpose of fixture-based mocking)
///   - URLs that come from server responses (e.g., 7TV's `host.url` field —
///     those are data, not code)
public enum Endpoints {

    // MARK: - chattr's OAuth bridge
    //
    // The Vercel-deployed backend that holds Twitch's `client_secret`
    // server-side. iOS only knows about the public-safe redirect URI and
    // refresh proxy — the secret never appears in any iOS binary.

    public enum ChattrAuth {
        /// Twitch redirects the OAuth code here. Must match the URL
        /// registered in the Twitch dev portal.
        public static let callback = URL(string: "https://chattr-auth.vercel.app/oauth/callback")!

        /// POST refresh_token here to exchange for fresh tokens.
        public static let refresh = URL(string: "https://chattr-auth.vercel.app/oauth/refresh")!
    }

    // MARK: - Twitch identity (Device Code Grant)
    //
    // Called directly from the device with only the client_id. Twitch documents
    // these requests without a client_secret even for confidential clients,
    // but that's unverified for this client: if Twitch rejects the client,
    // sign-in falls back to the browser flow. Refreshes of the resulting
    // tokens still go through `ChattrAuth.refresh`.

    public enum TwitchID {
        /// POST client_id + scopes → device_code / user_code / verification_uri.
        public static let device = URL(string: "https://id.twitch.tv/oauth2/device")!

        /// POST the device_code (grant_type=device_code) to poll for tokens.
        public static let token = URL(string: "https://id.twitch.tv/oauth2/token")!

        /// GET with `Authorization: OAuth <token>` → the token's login,
        /// client ID and remaining lifetime.
        public static let validate = URL(string: "https://id.twitch.tv/oauth2/validate")!
    }

    // MARK: - Twitch native emote CDN
    //
    // Twitch's static-cdn serves emote images by id + format + theme + scale.

    public enum TwitchCDN {
        private static let emotesBase = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2")!

        /// Construct a CDN URL for a Twitch native emote.
        /// - Parameters:
        ///   - id: Emote ID from `EmoteReference.id`.
        ///   - format: "static" or "animated". Animated falls back to
        ///     static when the emote has no animated variant.
        ///   - theme: "light" or "dark". Affects emote outline coloring.
        ///   - scale: "1.0", "2.0", "3.0". 2.0 matches typical chat row height.
        public static func emote(
            id: String,
            format: String,
            theme: String = "dark",
            scale: String = "2.0"
        ) -> URL {
            emotesBase
                .appending(component: id)
                .appending(component: format)
                .appending(component: theme)
                .appending(component: scale)
        }
    }

    // MARK: - 7TV
    //
    // Largest third-party emote provider. v3 API.

    public enum SevenTV {
        private static let usersBase = URL(string: "https://7tv.io/v3/users/twitch")!

        /// Global emote set — available across every channel.
        public static let globalEmoteSet = URL(string: "https://7tv.io/v3/emote-sets/global")!

        /// Per-channel emote set, keyed by Twitch broadcaster id.
        /// Returns a user object whose `emote_set.emotes` is the channel set.
        public static func userByTwitchID(_ id: String) -> URL {
            usersBase.appending(component: id)
        }
    }

    // MARK: - BetterTTV (BTTV)

    public enum BTTV {
        private static let usersBase = URL(string: "https://api.betterttv.net/3/cached/users/twitch")!
        private static let emoteCDNBase = URL(string: "https://cdn.betterttv.net/emote")!

        /// Global emotes.
        public static let globalEmotes = URL(string: "https://api.betterttv.net/3/cached/emotes/global")!

        /// Per-channel emote set, keyed by Twitch broadcaster id. Returns
        /// a user object with `channelEmotes[]` + `sharedEmotes[]`.
        /// 404 means the channel hasn't configured BTTV (very common).
        public static func userByTwitchID(_ id: String) -> URL {
            usersBase.appending(component: id)
        }

        /// CDN URL for a BTTV emote image. Sizes: "1x", "2x", "3x"
        /// (BTTV's "3x" is the largest; no "4x").
        public static func emoteCDN(id: String, size: String = "2x") -> URL {
            emoteCDNBase
                .appending(component: id)
                .appending(component: size)
        }
    }

    // MARK: - rustlog (community chat archive)
    //
    // Public read-only API that archives Twitch chat 24/7 via IRC. We use
    // it for "backfill" — fetching recent messages when a user joins a
    // channel so chat isn't empty for the first minute. Twitch's own API
    // does NOT expose chat history; rustlog is the standard
    // community-run solution.
    //
    // Failure handling: backfill is nice-to-have, not must-have. If
    // rustlog is down or slow, we skip and the channel still joins —
    // the user just doesn't see history.

    public enum Rustlog {
        private static let recentBase = URL(string: "https://recent-messages.robotty.de/api/v2/recent-messages")!

        /// Fetch the most recent N messages for a channel, by login
        /// (lowercase Twitch username). Returns JSON with a `messages`
        /// array of raw IRC-format strings.
        public static func recentMessages(channelLogin: String, limit: Int = 150) -> URL {
            let base = recentBase.appending(component: channelLogin)
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
            return components?.url ?? base
        }
    }

    // MARK: - FrankerFaceZ (FFZ)

    public enum FFZ {
        private static let roomBase = URL(string: "https://api.frankerfacez.com/v1/room")!

        /// Global emote sets — flatten emoticons across all sets.
        public static let globalSet = URL(string: "https://api.frankerfacez.com/v1/set/global")!

        /// Per-channel emote room, keyed by Twitch broadcaster *login*
        /// (lowercase username), NOT id. This is why
        /// `EmoteProvider.channelEmotes(broadcasterId:broadcasterLogin:)`
        /// takes both — 7TV/BTTV use the id, FFZ uses the login.
        public static func roomByLogin(_ login: String) -> URL {
            roomBase.appending(component: login)
        }
    }

    // MARK: - Twitch clips
    //
    // The clip pages chattr opens or shares. Slugs come from Twitch (chat
    // links, `POST /clips`) and are validated by `TwitchClipLink`.

    public enum TwitchClips {
        /// A clip's canonical page — what Share / Open in Twitch use.
        public static func page(slug: String) -> URL? {
            var components = URLComponents(string: "https://clips.twitch.tv")
            components?.path = "/\(slug)"
            return components?.url
        }

        /// Twitch's embeddable clip player, loaded top-level in the in-app
        /// clip sheet. `parent` is required by Twitch but only enforced
        /// against framing ancestors — same as the live player.
        public static func embed(slug: String) -> URL? {
            var components = URLComponents(string: "https://clips.twitch.tv/embed")
            components?.queryItems = [
                URLQueryItem(name: "clip", value: slug),
                URLQueryItem(name: "parent", value: "chattr.app"),
                URLQueryItem(name: "autoplay", value: "true"),
                URLQueryItem(name: "muted", value: "false"),
            ]
            return components?.url
        }
    }

    // MARK: - Twitch web pages
    //
    // Pages chattr hands to the system (Open in Twitch, Share, Subscribe).

    public enum TwitchWeb {
        private static let root = URL(string: "https://www.twitch.tv")!
        private static let subsBase = URL(string: "https://www.twitch.tv/subs")!

        /// A channel's (or user's) page on twitch.tv.
        public static func channel(login: String) -> URL? {
            guard !login.isEmpty else { return nil }
            return root.appending(component: login)
        }

        /// The channel's subscribe page.
        public static func subscribe(login: String) -> URL? {
            guard !login.isEmpty else { return nil }
            return subsBase.appending(component: login)
        }
    }

    // MARK: - Twitch stream playback

    public enum TwitchPlayer {
        private static let hlsBase = URL(string: "https://usher.ttvnw.net/api/channel/hls")!

        /// Twitch's embeddable live player, loaded top-level by the web
        /// engine. Callers add the `channel` / `parent` / `autoplay` items.
        public static let embed = URL(string: "https://player.twitch.tv/")!

        /// Where the native player gets a playback access token. Not an
        /// official third-party API: it can change or be blocked at any time.
        public static let playbackAccessToken = URL(string: "https://gql.twitch.tv/gql")!

        /// A live channel's HLS master playlist. Callers add the signed
        /// token and player options as query items.
        public static func livePlaylist(login: String) -> URL? {
            let trimmed = login.lowercased()
            guard !trimmed.isEmpty else { return nil }
            return hlsBase.appending(component: "\(trimmed).m3u8")
        }
    }

    // MARK: - Twitch chat over IRC (guest mode)

    public enum TwitchIRC {
        /// Twitch's IRC-over-WebSocket endpoint, which guest mode reads
        /// anonymously. Signed-in chat uses EventSub, not this.
        public static let webSocket = URL(string: "wss://irc-ws.chat.twitch.tv:443")!
    }

    // MARK: - Helix (requests TwitchKit has no wrapper for)

    public enum Helix {
        /// `GET /moderation/banned`: one user's ban state in a channel.
        public static let bannedUsers = URL(string: "https://api.twitch.tv/helix/moderation/banned")!

        /// `GET /chat/emotes/user`: every Twitch emote the signed-in user can
        /// use (subscriptions, bits tiers, follower emotes, globals, specials),
        /// including `owner_id` so the picker can group subscriber emotes by
        /// channel (TwitchKit's `TwitchEmote` omits `owner_id`).
        public static let userEmotes = URL(string: "https://api.twitch.tv/helix/chat/emotes/user")!
    }
}
