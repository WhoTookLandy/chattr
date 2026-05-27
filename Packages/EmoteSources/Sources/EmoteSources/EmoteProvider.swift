import Foundation

/// Abstraction over an emote provider's REST API.
///
/// Each conformance owns:
///   - the HTTP shape (URL construction, request building)
///   - the JSON decoding (provider-specific response types)
///   - the mapping from provider-specific fields to the unified `Emote` value type
///
/// Semantics:
///
/// - Both methods are `async throws`. Failures bubble up to the caller; conformances
///   should NOT internally retry. `EmoteIndex` decides whether to swallow per-provider
///   failures (typical — a single dead provider shouldn't break the channel load).
///
/// - Conformances should NOT cache. Caching is `EmoteIndex`'s responsibility; that
///   way the cache strategy lives in one place rather than three.
///
/// - The `broadcasterLogin` parameter on `channelEmotes` exists because **FFZ keys
///   channel emote endpoints by Twitch login**, not by broadcaster_user_id. SevenTV
///   and BTTV use the id and ignore the login. Rather than splitting the protocol
///   into provider-specific overloads or making `EmoteIndex` know which providers
///   need which inputs, the protocol accepts both — providers use what they need.
public protocol EmoteProvider: Sendable {

    /// The set of emotes this provider considers "global" — available in every channel.
    /// Typically fetched once per app lifecycle (or when a refresh is forced via
    /// `EmoteIndex` reload).
    ///
    /// - Returns: All global emotes from this provider, or an empty array if the
    ///   provider has no globals (rare).
    /// - Throws: Network or decoding errors. `EmoteIndex` logs and swallows these.
    func globalEmotes() async throws -> [Emote]

    /// Emotes specific to a given Twitch channel.
    ///
    /// - Parameters:
    ///   - broadcasterId: The Twitch `broadcaster_user_id` (numeric string). Used by
    ///     providers that key endpoints by id (SevenTV, BTTV).
    ///   - broadcasterLogin: The Twitch broadcaster login (lowercase username, e.g. "xqc").
    ///     Used by providers that key endpoints by login (FFZ).
    /// - Returns: Channel-specific emotes from this provider, or empty array if the
    ///   channel has no provider-specific emotes (very common — most Twitch channels
    ///   don't have BTTV or FFZ emotes set up).
    /// - Throws: Network or decoding errors.
    func channelEmotes(broadcasterId: String, broadcasterLogin: String) async throws -> [Emote]
}
