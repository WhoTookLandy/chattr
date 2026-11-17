import Foundation

/// Domain-agnostic error envelope used at high-level boundaries (UI surfaces,
/// store actors, public APIs returned to view code).
///
/// ## Why a struct with a `Kind` enum vs a plain `enum AppError`
///
/// A plain enum (`enum AppError { case sessionExpired(String); ... }`) would
/// give us pattern-matching for free, but breaks every existing call site
/// that constructs errors with a free-form message:
///
///     throw AppError(message: "Callback URL missing access_token")
///
/// Migrating ~20+ call sites at once is risky. Instead we split:
///
///   - `Kind` (enum) — structured cases for the errors we want to handle
///     programmatically (e.g., "session expired → show sign-in banner").
///   - `init(message:)` — existing free-form constructor, sets
///     `kind = .unknown(message:)`. Untouched call sites keep working.
///   - Static factories — `AppError.sessionExpired(login:)` etc. — the
///     preferred API for new code.
///
/// ## How to use this at catch sites
///
/// ```swift
/// catch let error as AppError {
///     switch error.kind {
///     case .sessionExpired:
///         // Drive UI back to SignInView with a banner.
///     case .bridgeRefreshFailed, .network, .timeout:
///         // Transient — show retry affordance.
///     case .decoding:
///         // Server/client schema mismatch — log + show generic.
///     case .unknown(let message):
///         // Free-form fallback.
///         showToast(message)
///     }
/// }
/// ```
public struct AppError: Error, Sendable, Equatable {
    public let kind: Kind
    public let underlying: String?

    /// Structured error categories. Add cases as new patterns emerge —
    /// every case here should map to a distinct UI treatment, otherwise
    /// it doesn't earn its own case.
    public enum Kind: Sendable, Equatable {
        /// The user's OAuth session is irrecoverably dead (refresh token
        /// revoked, expired, or both stores empty). UI should transition
        /// back to SignInView with a session-expired banner.
        case sessionExpired(login: String)

        /// chattr's Vercel OAuth bridge returned a non-200 that doesn't say
        /// the refresh token is invalid (that case is `.sessionExpired`).
        /// Transient, whatever the status: the credential is probably still
        /// good. Caller decides retry.
        case bridgeRefreshFailed(status: Int)

        /// Network-layer failure (DNS, timeout, no connection, server
        /// gone). UI typically shows "Try again" affordance.
        case network(URLError.Code)

        /// A response decoded oddly. Usually a server schema drift or a
        /// malformed payload — should be rare in production.
        case decoding(reason: String)

        /// Request exceeded its timeout. Distinguished from `.network`
        /// because the UI treatment differs (retry, vs "you're offline").
        case timeout

        /// Free-form message — the historical `AppError(message:)` path.
        /// Used when we don't yet have a structured case OR when the
        /// error is genuinely one-off (server-provided text, malformed
        /// OAuth callback, etc.).
        case unknown(message: String)
    }

    // MARK: - User-facing message
    //
    // Derived from `kind` so callers don't have to construct localized
    // messages by hand. When a case needs a different message in a
    // specific context, the call site can use `init(message:)` directly
    // or extend this switch.

    public var message: String {
        switch kind {
        case .sessionExpired(let login):
            return "Session expired for @\(login) — please sign in again"
        case .bridgeRefreshFailed(let status):
            return "Token refresh failed (HTTP \(status))"
        case .network(let code):
            return "Network error (\(code.rawValue))"
        case .decoding(let reason):
            return "Couldn't decode response: \(reason)"
        case .timeout:
            return "The request timed out"
        case .unknown(let message):
            return message
        }
    }

    // MARK: - Initializers

    /// Structured constructor. Preferred for new code.
    public init(kind: Kind, underlying: Error? = nil) {
        self.kind = kind
        self.underlying = underlying.map { "\($0)" }
    }

    /// Legacy free-form constructor. Sets `kind = .unknown(message:)`.
    ///
    /// Kept for source-compat with existing call sites that don't
    /// (yet) have a structured `Kind` to use. New code should prefer
    /// the static factories below or a `Kind` case directly.
    public init(message: String, underlying: Error? = nil) {
        self.kind = .unknown(message: message)
        self.underlying = underlying.map { "\($0)" }
    }

    // MARK: - Static factories
    //
    // Sugar for the common structured cases. `AppError.sessionExpired(login:)`
    // reads better at the throw site than `AppError(kind: .sessionExpired(login:))`.

    public static func sessionExpired(login: String) -> AppError {
        AppError(kind: .sessionExpired(login: login))
    }

    public static func bridgeRefreshFailed(status: Int, underlying: Error? = nil) -> AppError {
        AppError(kind: .bridgeRefreshFailed(status: status), underlying: underlying)
    }

    public static func network(_ code: URLError.Code, underlying: Error? = nil) -> AppError {
        AppError(kind: .network(code), underlying: underlying)
    }

    public static func decoding(reason: String, underlying: Error? = nil) -> AppError {
        AppError(kind: .decoding(reason: reason), underlying: underlying)
    }

    public static func timeout(underlying: Error? = nil) -> AppError {
        AppError(kind: .timeout, underlying: underlying)
    }
}

extension AppError: LocalizedError {
    /// The user-facing string. Pulled from `kind`-derived message so
    /// `error.localizedDescription` shows the expected text whether the
    /// error was constructed via legacy `init(message:)` or via a
    /// structured factory.
    public var errorDescription: String? { message }
}
