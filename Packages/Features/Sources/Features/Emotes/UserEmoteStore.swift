import Foundation
import SwiftUI
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.UserEmoteStore")

/// One Twitch emote returned by `GET /chat/emotes/user`.
///
/// Modeled separately from `TwitchKit.TwitchEmote` because TwitchKit 0.3.4's
/// `TwitchEmote` omits `owner_id` — which is the field Twitch uses to tell us
/// which broadcaster each subscriber / bits-tier / follower emote belongs to.
public struct UserTwitchEmote: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// `"subscriptions"`, `"bitstier"`, `"follower"`, `"globals"`, `"smilies"`,
    /// `"prime"`, `"turbo"`, `"hypetrain"`, `"rewards"`, `"limitedtime"`,
    /// `"channelpoints"`, `"twofactor"`, `"none"`, etc.
    public let emoteType: String
    public let emoteSetId: String
    /// Broadcaster user ID who owns this emote, or `"0"` / `"twitch"` for
    /// Twitch-owned globals & special emotes.
    public let ownerId: String
    public let format: [String]
    public let scale: [String]
    public let themeMode: [String]

    /// True when the emote is owned by Twitch itself rather than a specific
    /// broadcaster (global, Prime, Turbo, Hype Train, Smilies, etc.).
    public var isTwitchOwned: Bool {
        ownerId.isEmpty || ownerId == "0" || ownerId == "twitch"
    }

    public init(
        id: String,
        name: String,
        emoteType: String = "",
        emoteSetId: String = "",
        ownerId: String = "0",
        format: [String] = ["static"],
        scale: [String] = ["1.0", "2.0", "3.0"],
        themeMode: [String] = ["dark", "light"]
    ) {
        self.id = id
        self.name = name
        self.emoteType = emoteType
        self.emoteSetId = emoteSetId
        self.ownerId = ownerId
        self.format = format
        self.scale = scale
        self.themeMode = themeMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, emoteType, emoteSetId, ownerId, format, scale, themeMode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.emoteType = try container.decodeIfPresent(String.self, forKey: .emoteType) ?? ""
        self.emoteSetId = try container.decodeIfPresent(String.self, forKey: .emoteSetId) ?? ""
        self.ownerId = try container.decodeIfPresent(String.self, forKey: .ownerId) ?? "0"
        self.format = try container.decodeIfPresent([String].self, forKey: .format) ?? ["static"]
        self.scale = try container.decodeIfPresent([String].self, forKey: .scale) ?? ["1.0", "2.0", "3.0"]
        self.themeMode = try container.decodeIfPresent([String].self, forKey: .themeMode) ?? ["dark", "light"]
    }
}

/// Broadcaster identity for grouping subscribed-channel emotes in the picker
/// (section header title + channel avatar in the quick-jump rail).
public struct EmoteChannelInfo: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let login: String
    public let displayName: String
    public let profileImageURL: URL?

    public init(id: String, login: String, displayName: String, profileImageURL: URL? = nil) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.profileImageURL = profileImageURL
    }
}

/// On-disk payload for one account's accessible Twitch emotes and resolved
/// channel owner metadata.
struct UserEmotesCachePayload: Codable, Sendable {
    static let cacheVersion = 1

    let userId: String
    let fetchedAt: Date
    let emotes: [UserTwitchEmote]
    let owners: [String: EmoteChannelInfo]
}

/// App-wide store of the active account's accessible Twitch emotes from
/// `GET /chat/emotes/user` — subscriber emotes from every channel the user is
/// subscribed to, bits-tier emotes, unlocked Prime/Turbo/Hype Train emotes,
/// plus resolved broadcaster names and avatars for grouping them in the picker.
///
/// Owned by `RootView` and injected via `@Environment(\.userEmoteStore)` so
/// every open chat tab shares one warm copy and never re-paginates Helix.
///
/// ## Caching & freshness
///
/// Persisted per account in `JSONDiskCache(subdirectory: CacheSubdirectory.emoteUsers)`:
/// - Cold launch restores from disk immediately (0ms in the picker).
/// - Inside `revalidateAfter` (1 hour) the network is skipped unless the user
///   explicitly taps Refresh in the picker (`force: true`).
/// - Past `revalidateAfter` (up to `cacheTTL` = 24 hours), the cached set
///   renders immediately while a fresh fetch updates it in the background.
@MainActor
@Observable
public final class UserEmoteStore {

    /// Every Twitch emote the active user can use.
    public private(set) var emotes: [UserTwitchEmote] = []

    /// Resolved broadcaster display name + avatar for each non-global `ownerId`.
    public private(set) var owners: [String: EmoteChannelInfo] = [:]

    /// Monotonically bumped whenever `emotes` or `owners` changes — O(1) cache
    /// key for `EmoteCatalog`.
    public private(set) var version: Int = 0

    /// True while a foreground/initial fetch is running with nothing loaded yet.
    public private(set) var isLoading: Bool = false

    /// True when the active account's OAuth token lacks `user:read:emotes`
    /// (signed in before that scope was added). Surfaced gently in the picker
    /// instead of failing silently or triggering a forced sign-out.
    public private(set) var needsReauthForScope: Bool = false

    /// Account ID whose data this store currently holds.
    public private(set) var currentUserId: String?

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let revalidateAfter: TimeInterval = 60 * 60
    private static let maxPages = 50

    private let cache: JSONDiskCache
    private let session: URLSession

    @ObservationIgnored private var lastFetchedAt: Date?
    @ObservationIgnored private var inFlight: (userId: String, generation: Int, task: Task<Void, Never>)?
    @ObservationIgnored private var generation = 0

    public init(
        cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteUsers),
        session: URLSession = .shared
    ) {
        self.cache = cache
        self.session = session
    }

    /// Loads (or refreshes) the active account's emotes. Coalesced per account.
    ///
    /// - Parameter force: When `true` (e.g. Refresh button in the picker),
    ///   bypasses the freshness window and fetches fresh data from Helix.
    public func load(
        account: Account,
        accountStore: AccountStore,
        followsStore: FollowsStore? = nil,
        force: Bool = false
    ) async {
        let userId = account.userId
        let login = account.login

        prepare(forAccountUserId: userId)

        if let existing = inFlight, existing.userId == userId {
            await existing.task.value
            return
        }

        if !force,
           let fetchedAt = lastFetchedAt,
           Date().timeIntervalSince(fetchedAt) < Self.revalidateAfter,
           !emotes.isEmpty {
            return
        }

        let currentGen = generation
        let client = accountStore.client(for: account)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(
                userId: userId,
                login: login,
                client: client,
                accountStore: accountStore,
                followsStore: followsStore,
                force: force,
                expectedGeneration: currentGen
            )
        }
        inFlight = (userId, currentGen, task)
        await task.value
        if inFlight?.task == task {
            inFlight = nil
        }
    }

    // MARK: - Account scoping

    private func prepare(forAccountUserId userId: String) {
        guard currentUserId != userId else { return }
        let hadPrevious = currentUserId != nil
        currentUserId = userId
        generation &+= 1
        inFlight?.task.cancel()
        inFlight = nil
        lastFetchedAt = nil
        needsReauthForScope = false
        isLoading = false
        if hadPrevious {
            emotes = []
            owners = [:]
            version &+= 1
        }
    }

    // MARK: - Load implementation

    private func performLoad(
        userId: String,
        login: String,
        client: TwitchClient,
        accountStore: AccountStore,
        followsStore: FollowsStore?,
        force: Bool,
        expectedGeneration: Int
    ) async {
        // 1. Instant disk restore when memory is empty.
        var diskFreshForRevalidate = false
        if emotes.isEmpty,
           let hit = await cache.load(
            key: userId,
            as: UserEmotesCachePayload.self,
            version: UserEmotesCachePayload.cacheVersion,
            ttl: Self.cacheTTL
           ),
           hit.payload.userId == userId {
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            if !hit.payload.emotes.isEmpty {
                emotes = hit.payload.emotes
                owners = hit.payload.owners
                lastFetchedAt = hit.payload.fetchedAt
                version &+= 1
                logger.info("UserEmoteStore restored \(hit.payload.emotes.count) emote(s) and \(hit.payload.owners.count) channel(s) from disk for @\(login, privacy: .public)")
            }
            if !force, Date().timeIntervalSince(hit.payload.fetchedAt) < Self.revalidateAfter {
                diskFreshForRevalidate = true
            }
        }

        if diskFreshForRevalidate {
            // Opportunistically top up any missing avatars from FollowsStore
            // without touching the network.
            enrichOwnersFromFollows(followsStore)
            return
        }

        isLoading = true
        defer {
            if generation == expectedGeneration {
                isLoading = false
            }
        }

        // 2. Check stored token & scope safely before hitting Helix directly.
        var token: OAuthToken
        do {
            token = try await client.auth.tokenProvider.token()
        } catch HelixError.notAuthenticated {
            do {
                token = try await accountStore.refreshTokens(userId: userId, login: login)
            } catch {
                logger.warning("UserEmoteStore couldn't obtain token for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        } catch {
            logger.warning("UserEmoteStore token read failed for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        if let granted = token.scope, !granted.contains(TwitchScope.userReadEmotes.rawValue) {
            guard generation == expectedGeneration else { return }
            needsReauthForScope = true
            logger.notice("UserEmoteStore skipped for @\(login, privacy: .public): token lacks user:read:emotes scope")
            return
        }

        // 3. Walk paginated GET /chat/emotes/user?user_id=...
        var collected: [UserTwitchEmote] = []
        var seenIds: Set<String> = []
        var cursor: String? = nil
        var pageCount = 0
        var didRefreshToken = false

        repeat {
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            do {
                let page = try await fetchPage(
                    userId: userId,
                    cursor: cursor,
                    accessToken: token.accessToken,
                    clientId: client.clientId
                )
                pageCount += 1
                for emote in page.emotes where seenIds.insert(emote.id).inserted {
                    collected.append(emote)
                }
                cursor = page.nextCursor
            } catch FetchError.unauthorized {
                if !didRefreshToken {
                    didRefreshToken = true
                    do {
                        token = try await accountStore.refreshTokens(userId: userId, login: login)
                        continue
                    } catch {
                        logger.warning("UserEmoteStore token refresh failed for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return
                    }
                }
                // Still 401 after a fresh token → account predates user:read:emotes.
                guard generation == expectedGeneration else { return }
                needsReauthForScope = true
                logger.notice("UserEmoteStore unauthorized after refresh for @\(login, privacy: .public) (missing user:read:emotes)")
                return
            } catch is CancellationError {
                return
            } catch {
                logger.warning("UserEmoteStore page \(pageCount) failed for @\(login, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        } while cursor != nil && pageCount < Self.maxPages

        guard !Task.isCancelled, generation == expectedGeneration else { return }

        needsReauthForScope = false

        // 4. Resolve broadcaster names + avatars for every non-global ownerId.
        let ownerIds = Set(collected.compactMap { $0.isTwitchOwned ? nil : $0.ownerId })
        var resolvedOwners = owners.filter { ownerIds.contains($0.key) }

        // Seed instantly from FollowsStore (no network).
        if let followsStore {
            for channel in followsStore.channels where ownerIds.contains(channel.broadcasterId) {
                let avatar = followsStore.profileImageURLs[channel.broadcasterId]
                    ?? resolvedOwners[channel.broadcasterId]?.profileImageURL
                resolvedOwners[channel.broadcasterId] = EmoteChannelInfo(
                    id: channel.broadcasterId,
                    login: channel.broadcasterLogin,
                    displayName: channel.broadcasterName,
                    profileImageURL: avatar
                )
            }
        }

        // Publish emotes immediately with whatever owner metadata we already
        // have so the picker doesn't wait on `/users` enrichment.
        emotes = collected
        owners = resolvedOwners
        let now = Date()
        lastFetchedAt = now
        version &+= 1

        // Fetch any remaining unresolved owners (or owners still missing an
        // avatar) in batches of 100 via TwitchKit's `fetchUsers(ids:)`.
        let missingIds = ownerIds.filter { id in
            guard let info = resolvedOwners[id] else { return true }
            return info.profileImageURL == nil
        }.sorted()

        if !missingIds.isEmpty {
            let enriched = await fetchOwnerInfos(
                ids: missingIds,
                client: client,
                accountStore: accountStore,
                userId: userId
            )
            guard !Task.isCancelled, generation == expectedGeneration else { return }
            if !enriched.isEmpty {
                for (id, info) in enriched {
                    resolvedOwners[id] = info
                }
                owners = resolvedOwners
                version &+= 1
            }
        }

        await cache.save(
            key: userId,
            value: UserEmotesCachePayload(
                userId: userId,
                fetchedAt: now,
                emotes: collected,
                owners: resolvedOwners
            ),
            version: UserEmotesCachePayload.cacheVersion
        )
        logger.info("UserEmoteStore loaded \(collected.count) emote(s) across \(pageCount) page(s) (\(resolvedOwners.count) channel(s)) for @\(login, privacy: .public)")
    }

    /// Opportunistically fills in newly-loaded avatars from `FollowsStore`
    /// without hitting the network.
    private func enrichOwnersFromFollows(_ followsStore: FollowsStore?) {
        guard let followsStore, !owners.isEmpty else { return }
        var updated = owners
        var changed = false
        for (id, info) in owners where info.profileImageURL == nil {
            if let avatar = followsStore.profileImageURLs[id] {
                updated[id] = EmoteChannelInfo(
                    id: info.id,
                    login: info.login,
                    displayName: info.displayName,
                    profileImageURL: avatar
                )
                changed = true
            }
        }
        if changed {
            owners = updated
            version &+= 1
        }
    }

    // MARK: - HTTP helpers

    private enum FetchError: Error {
        case unauthorized
        case httpStatus(Int)
    }

    private func fetchPage(
        userId: String,
        cursor: String?,
        accessToken: String,
        clientId: String
    ) async throws -> (emotes: [UserTwitchEmote], nextCursor: String?) {
        var components = URLComponents(url: Endpoints.Helix.userEmotes, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "user_id", value: userId)]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "after", value: cursor))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw FetchError.httpStatus(400) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientId, forHTTPHeaderField: "Client-Id")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            throw FetchError.unauthorized
        }
        guard (200..<300).contains(status) else {
            throw FetchError.httpStatus(status)
        }
        return try Self.decodePage(data)
    }

    private func fetchOwnerInfos(
        ids: [String],
        client: TwitchClient,
        accountStore: AccountStore,
        userId: String
    ) async -> [String: EmoteChannelInfo] {
        var result: [String: EmoteChannelInfo] = [:]
        var index = 0
        while index < ids.count {
            guard !Task.isCancelled else { break }
            let end = min(index + 100, ids.count)
            let batch = Array(ids[index..<end])
            index = end
            do {
                let users = try await accountStore.withTokenRefresh(forUserId: userId) {
                    try await client.api.fetchUsers(ids: batch)
                }
                for user in users {
                    result[user.id] = EmoteChannelInfo(
                        id: user.id,
                        login: user.login,
                        displayName: user.displayName,
                        profileImageURL: URL(string: user.profileImageUrl)
                    )
                }
            } catch {
                logger.warning("UserEmoteStore owner batch lookup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    // MARK: - Decoding (nonisolated, unit-tested)

    private struct PageResponse: Decodable {
        let data: [UserTwitchEmote]
        let pagination: Pagination?

        struct Pagination: Decodable {
            let cursor: String?
        }
    }

    nonisolated static func decodePage(_ data: Data) throws -> (emotes: [UserTwitchEmote], nextCursor: String?) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let page = try decoder.decode(PageResponse.self, from: data)
        let next = page.pagination?.cursor
        return (page.data, (next?.isEmpty == false) ? next : nil)
    }
}

// MARK: - Environment plumbing

public extension EnvironmentValues {
    /// App-wide store of the active account's accessible Twitch emotes
    /// (subscriber emotes, bits-tier emotes, unlocked specials). Owned and
    /// injected by `RootView`.
    @Entry var userEmoteStore: UserEmoteStore? = nil
}
