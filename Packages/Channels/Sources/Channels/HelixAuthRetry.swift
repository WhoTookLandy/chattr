import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChannelSession")

/// Runs a Helix / EventSub operation; if it fails with an auth-refreshable
/// error, refreshes tokens via `refreshTokenHandler` and retries ONCE. A
/// second failure (or a refresh failure) propagates to the caller.
///
/// A stale access token reaches us in one of THREE shapes — not just
/// `.unauthorized`. In practice `.oauth` is the common one:
///   - .unauthorized      — the 401 surfaced to us directly.
///   - .oauth(...)        — TwitchKit's HelixClient intercepted the 401,
///                          tried its own `/oauth2/token` refresh, and
///                          Twitch rejected it ("missing client secret" —
///                          we ship no secret; it lives on the Vercel
///                          bridge). TwitchKit then wiped its own token
///                          store as it threw.
///   - .notAuthenticated  — that store-wipe already happened on an earlier
///                          call, so the token is simply gone.
/// All three mean "refresh via the bridge and retry once." This mirrors
/// `AccountStore.withTokenRefresh`, which nets the same three cases around
/// the Helix call sites outside `ChannelSession`. (Previously only the chat
/// subscribe handled all three; send / delete / chat-settings caught only
/// `.unauthorized`, so the common `.oauth` shape escaped them.)
///
/// The refresh itself is single-flight in `AccountStore`, so concurrent
/// retries across sessions share one bridge round-trip.
struct HelixAuthRetry: Sendable {

    /// Refreshes the account's tokens via the bridge. Injected at session
    /// construction by `ChannelSessionRegistry`, so this package doesn't need
    /// to know about `AccountStore` or `Account` directly.
    let refreshTokenHandler: @Sendable () async throws -> Void

    /// Which errors trigger the refresh + retry. Production uses
    /// `isHelixAuthRefreshable`; tests inject their own error type.
    let isAuthRefreshable: @Sendable (any Error) -> Bool

    init(
        refreshTokenHandler: @escaping @Sendable () async throws -> Void,
        isAuthRefreshable: @escaping @Sendable (any Error) -> Bool = { HelixAuthRetry.isHelixAuthRefreshable($0) }
    ) {
        self.refreshTokenHandler = refreshTokenHandler
        self.isAuthRefreshable = isAuthRefreshable
    }

    /// Runs `operation`, refreshing and retrying it once on an
    /// auth-refreshable error. Inherits the caller's isolation, so the
    /// operation needn't be `Sendable`.
    @discardableResult
    func run<T>(
        _ label: String,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let error where isAuthRefreshable(error) {
            logger.info("\(label, privacy: .public) needs a token refresh (\(error.localizedDescription, privacy: .public)); refreshing via bridge and retrying once")
            try await refreshTokenHandler()
            return try await operation()
        }
    }

    /// The three `HelixError` shapes a stale (or already-wiped) access token can
    /// take, all of which are recoverable by a bridge refresh + one retry.
    /// Centralizing the predicate keeps `run` in lockstep with
    /// `AccountStore.withTokenRefresh`, which guards every other Helix call site
    /// against exactly these cases.
    static func isHelixAuthRefreshable(_ error: any Error) -> Bool {
        switch error {
        case HelixError.unauthorized, HelixError.oauth, HelixError.notAuthenticated:
            return true
        default:
            return false
        }
    }
}
