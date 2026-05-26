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
public actor AccountStore {
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
