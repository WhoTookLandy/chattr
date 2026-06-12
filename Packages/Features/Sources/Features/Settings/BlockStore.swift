import Observation
import SwiftUI
import Accounts
import Core
import TwitchKit
import os

private let logger = AppLogger.make("Features.BlockStore")

/// One blocked user. Local `Codable` model (TwitchKit's `BlockedUser` is
/// `Decodable`-only, so it can't be persisted) — mapped from `TwitchKit.BlockedUser`
/// at the fetch boundary.
public struct BlockedChatter: Codable, Sendable, Identifiable, Equatable {
    public let id: String          // Twitch user id
    public let login: String
    public let displayName: String

    public init(id: String, login: String, displayName: String) {
        self.id = id
        self.login = login
        self.displayName = displayName
    }
}

/// Per-account, app-wide blocked-user state. Twitch is the source of truth
/// (`load()` fetches the authoritative list); a UserDefaults cache makes blocks
/// apply on next launch before that fetch returns. Mutations are optimistic with
/// rollback. `@Observable` so chat filtering + the Profile screen re-render on change.
@MainActor
@Observable
public final class BlockStore {
    public private(set) var blocked: [BlockedChatter] = []
    public private(set) var blockedIds: Set<String> = []

    private let accountUserId: String
    private let accountStore: AccountStore
    private let defaults: UserDefaults
    private var storageKey: String { "blockedUsers.\(accountUserId)" }

    public init(accountUserId: String, accountStore: AccountStore, defaults: UserDefaults = .standard) {
        self.accountUserId = accountUserId
        self.accountStore = accountStore
        self.defaults = defaults
        loadPersisted()
    }

    public func isBlocked(_ userId: String) -> Bool { blockedIds.contains(userId) }

    /// Seed from Twitch (authoritative), paginating the block list. Keeps the
    /// persisted cache on failure (best-effort).
    public func load() async {
        let client = accountStore.client(forUserId: accountUserId)
        do {
            var fetched: [BlockedChatter] = []
            var cursor: String? = nil
            repeat {
                let page = try await client.api.fetchUserBlockListPage(broadcasterID: accountUserId, first: nil, after: cursor)
                fetched.append(contentsOf: page.data.map {
                    BlockedChatter(id: $0.userId, login: $0.userLogin, displayName: $0.displayName)
                })
                cursor = page.pagination?.cursor
            } while cursor != nil
            reconcile(with: fetched)
        } catch {
            logger.debug("Block-list fetch failed for \(self.accountUserId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Block (optimistic). `reason` doubles as the report reason.
    public func block(userId: String, login: String, displayName: String, reason: UserBlockReason) async {
        guard !blockedIds.contains(userId) else { return }
        insert(BlockedChatter(id: userId, login: login, displayName: displayName))
        do {
            try await accountStore.client(forUserId: accountUserId).api.blockUser(
                targetUserID: userId, sourceContext: .chat, reason: reason
            )
        } catch {
            remove(id: userId)
            logger.error("block \(userId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unblock (optimistic).
    public func unblock(userId: String) async {
        guard let existing = blocked.first(where: { $0.id == userId }) else { return }
        remove(id: userId)
        do {
            try await accountStore.client(forUserId: accountUserId).api.unblockUser(targetUserID: userId)
        } catch {
            insert(existing)
            logger.error("unblock \(userId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Synchronous state ops (unit-tested)

    func reconcile(with fetched: [BlockedChatter]) {
        blocked = fetched.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        blockedIds = Set(fetched.map(\.id))
        persist()
    }

    private func insert(_ user: BlockedChatter) {
        guard !blockedIds.contains(user.id) else { return }
        blocked.append(user)
        blocked.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        blockedIds.insert(user.id)
        persist()
    }

    private func remove(id: String) {
        blocked.removeAll { $0.id == id }
        blockedIds.remove(id)
        persist()
    }

    private func loadPersisted() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([BlockedChatter].self, from: data) else { return }
        blocked = decoded
        blockedIds = Set(decoded.map(\.id))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(blocked) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Environment plumbing (mirrors GlobalCatalog's Optional/RootView-injected shape)

public extension EnvironmentValues {
    /// App-wide blocked-user store for the active account. Injected by RootView.
    /// `nil` outside a RootView ancestor (e.g. previews) — treat absence as
    /// "nothing blocked."
    @Entry var blockStore: BlockStore? = nil
}
