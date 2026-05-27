import Foundation
import SwiftData
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.AccountStore")

/// Local registry of signed-in Twitch accounts. Single source of truth for "who is signed in"
/// and which account is currently active.
///
/// Persistence: SwiftData (`Account` rows).
/// Per-account `TwitchClient` instances are constructed lazily and cached in-memory.
///
/// Isolation: `@MainActor` rather than `actor`. SwiftData's main `ModelContext` is
/// `@MainActor`-bound by design (it backs `@Query` and `@Environment(\.modelContext)`),
/// and `@Model` instances aren't `Sendable` — passing them across an `actor` boundary
/// triggers strict-concurrency violations. `@MainActor` keeps `Account` instances inside
/// the isolation domain they already live in. Operations are lightweight and HTTP calls
/// are `async`-and-awaited, so suspending on main doesn't block the thread.
@MainActor
public final class AccountStore {
    private let modelContainer: ModelContainer
    private let clientId: String

    /// Cached per-account TwitchClient instances. Keyed by `userId`.
    private var clients: [String: TwitchClient] = [:]

    /// Currently active account's userId. Drives which client/identity drives the UI.
    private var activeUserId: String?

    public init(modelContainer: ModelContainer, clientId: String) {
        self.modelContainer = modelContainer
        self.clientId = clientId
    }

    // MARK: - Public API

    /// All known accounts, newest-first.
    public func allAccounts() async throws -> [Account] {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Account>()
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .reverse)]
        return try context.fetch(descriptor)
    }

    /// The currently active account, if any.
    public func activeAccount() async throws -> Account? {
        guard let activeUserId else { return nil }
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.userId == activeUserId })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Set which account is active.
    public func setActive(userId: String) {
        self.activeUserId = userId
        logger.info("Active account → \(userId)")
    }

    /// Returns (constructing if needed) the TwitchClient for the given account.
    public func client(for account: Account) -> TwitchClient {
        if let existing = clients[account.userId] {
            return existing
        }
        let client = TwitchClient(
            clientId: clientId,
            tokenNamespace: account.tokenNamespace
        )
        clients[account.userId] = client
        return client
    }

    /// Persists a new account after a successful OAuth flow. Returns the inserted Account.
    /// `token` is set on the new client's auth before returning so the first Helix call works.
    public func add(token: OAuthToken, scopes: [TwitchScope]) async throws -> Account {
        // 1. Use a temporary TwitchClient with an in-memory store to call /users and learn who we are.
        //    This avoids polluting Keychain with tokens until we know the userId.
        let probe = TwitchClient(
            clientId: clientId,
            tokenStore: InMemoryTokenStore()
        )
        try await probe.auth.setToken(token)
        let user = try await probe.api.fetchUser()

        // 2. Construct the canonical tokenNamespace from userId.
        let namespace = Self.namespace(for: user.id)

        // 3. Build the persistent client (Keychain-backed) and seed it with the token.
        let persistent = TwitchClient(
            clientId: clientId,
            tokenNamespace: namespace
        )
        try await persistent.auth.setToken(token)
        clients[user.id] = persistent

        // 4. Persist the Account row.
        // Note: TwitchUser.profileImageUrl uses lowercase 'url' (Codable from snake_case).
        // Account.profileImageURL uses uppercase 'URL' (Swift convention on stored model property).
        let account = Account(
            userId: user.id,
            login: user.login,
            displayName: user.displayName,
            profileImageURL: user.profileImageUrl,
            tokenNamespace: namespace
        )
        let context = ModelContext(modelContainer)
        context.insert(account)
        try context.save()
        activeUserId = user.id

        logger.info("Added account @\(user.login) (\(user.id))")
        return account
    }

    /// Removes an account: clears its Keychain entries, drops cached client, deletes SwiftData row.
    public func remove(account: Account) async throws {
        let client = client(for: account)
        // TwitchAuth.logout() delegates to tokenProvider.logout() internally.
        try await client.auth.logout()
        clients[account.userId] = nil
        if activeUserId == account.userId {
            activeUserId = nil
        }
        let context = ModelContext(modelContainer)
        context.delete(account)
        try context.save()
        logger.info("Removed account @\(account.login)")
    }

    // MARK: - Helpers

    /// The canonical tokenNamespace string for a given Twitch userId.
    /// Stays stable across launches so Keychain entries persist.
    public static func namespace(for userId: String) -> String {
        "chattr.account.\(userId)"
    }
}

// MARK: - Token Refresh

extension AccountStore {

    /// URL of chattr-auth's refresh endpoint. Mirrors the auth-flow constants in SignInView.
    private static var refreshURL: URL {
        URL(string: "https://chattr-auth.vercel.app/oauth/refresh")!
    }

    /// Refreshes the OAuth tokens for the given account via the Vercel bridge.
    ///
    /// Reads the current refresh_token from this account's TwitchAuth (which reads
    /// from Keychain via TokenStore), POSTs it to the bridge, parses the new tokens,
    /// and saves them. Throws `AppError` on any failure — caller decides whether to
    /// surface as "needs re-auth" UI vs a transient error banner.
    ///
    /// Side effects: persists the new OAuthToken via `TwitchAuth.setToken(_:)`, which
    /// also updates the in-memory cachedAccessToken / cachedRefreshToken.
    @discardableResult
    public func refreshTokens(for account: Account) async throws -> OAuthToken {
        try await refreshTokens(userId: account.userId, login: account.login)
    }

    /// Variant that accepts plain strings so `@Sendable` closures (e.g. in
    /// `ChannelSessionRegistry`) can capture stable IDs instead of the non-Sendable
    /// `Account` model object.
    @discardableResult
    public func refreshTokens(userId: String, login: String) async throws -> OAuthToken {
        // Build a throw-away TwitchClient using the canonical namespace for this userId.
        // `clients` is keyed by userId so this returns the already-cached client if one exists.
        let namespace = Self.namespace(for: userId)
        let twitchClient: TwitchClient
        if let existing = clients[userId] {
            twitchClient = existing
        } else {
            twitchClient = TwitchClient(clientId: clientId, tokenNamespace: namespace)
            clients[userId] = twitchClient
        }
        let currentToken = try await twitchClient.auth.tokenProvider.token()
        guard let refreshToken = currentToken.refreshToken, !refreshToken.isEmpty else {
            throw AppError(message: "No refresh token stored for @\(login) — must re-sign-in")
        }

        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct RequestBody: Encodable { let refresh_token: String }
        request.httpBody = try JSONEncoder().encode(RequestBody(refresh_token: refreshToken))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError(message: "Bridge refresh: no HTTP response")
        }

        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            logger.error("Bridge refresh failed for @\(login) (HTTP \(http.statusCode)): \(body)")
            // 4xx → refresh token likely invalid (revoked or expired). 5xx → bridge problem.
            // Either way: the caller decides whether to prompt re-auth.
            throw AppError(message: "Token refresh failed (HTTP \(http.statusCode))")
        }

        // Twitch's response is snake_case; decode to a local shape, then construct OAuthToken.
        struct TwitchRefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
            let scope: [String]?
            let token_type: String?
        }
        let parsed = try JSONDecoder().decode(TwitchRefreshResponse.self, from: data)
        let newToken = OAuthToken(
            accessToken: parsed.access_token,
            refreshToken: parsed.refresh_token,
            expiresIn: parsed.expires_in,
            scope: parsed.scope,
            tokenType: parsed.token_type
        )
        try await twitchClient.auth.setToken(newToken)
        logger.info("Refreshed tokens for @\(login) (expires_in=\(parsed.expires_in ?? -1))")
        return newToken
    }

    /// Wraps an async throwing operation with one retry-after-refresh-on-401.
    ///
    /// If `operation` throws `HelixError.unauthorized`, this method calls
    /// `refreshTokens(for:)`, then retries `operation` exactly once. Any throw
    /// from the refresh OR the retry bubbles to the caller (no infinite loops).
    ///
    /// Use at every chattr-side Helix call site to make tokens survive expiry.
    public func withTokenRefresh<T: Sendable>(
        for account: Account,
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch HelixError.unauthorized {
            logger.info("Helix call returned unauthorized for @\(account.login); refreshing tokens and retrying")
            try await refreshTokens(for: account)
            return try await operation()
        }
    }
}
