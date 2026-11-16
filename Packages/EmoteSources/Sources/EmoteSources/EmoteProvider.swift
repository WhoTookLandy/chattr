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

    /// Key under which `GlobalEmoteCatalog` caches and coalesces this
    /// provider's globals. A requirement (not just an extension member) so
    /// conformances that override it are honored through `any EmoteProvider`.
    /// Defaults to the concrete type name — see the extension below.
    var globalCatalogKey: String { get }
}

extension EmoteProvider {
    /// Default `globalCatalogKey`. Global sets are a property of the
    /// provider *kind*, not the instance — every channel's 7TV provider sees
    /// the same global set — so the default keys by concrete type. Test
    /// doubles that stand in for several providers with one type override
    /// this with a per-instance key.
    public var globalCatalogKey: String { String(reflecting: Self.self) }
}

/// Failures a provider raises itself (as opposed to transport errors from
/// `URLSession` or `DecodingError`s from a malformed body).
public enum EmoteProviderError: Error, Equatable, Sendable {
    /// Upstream answered with a non-success HTTP status — typically 429
    /// (rate limited) or 5xx (outage). Raised *before* decoding so an error
    /// page body isn't misreported as a schema drift `DecodingError`.
    case httpStatus(Int)
}

/// Shared HTTP status policy for the three providers.
enum ProviderHTTP {
    /// Throws `EmoteProviderError.httpStatus` unless the response is 2xx.
    /// Non-HTTP responses (only seen with exotic URL schemes) pass.
    static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw EmoteProviderError.httpStatus(http.statusCode)
        }
    }

    /// Channel-endpoint variant: 404 means "this channel never set the
    /// provider up" (the common case) and returns `true` so the caller can
    /// answer `[]`; any other non-2xx status throws.
    static func isNotFound(_ response: URLResponse) throws -> Bool {
        if (response as? HTTPURLResponse)?.statusCode == 404 { return true }
        try requireSuccess(response)
        return false
    }
}
