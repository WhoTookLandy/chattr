import Foundation
import Observation
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.ChatBadgeStore")

/// Stable composite key matching `ChatBadge`'s identity pair. Public so
/// `GlobalCatalog` can expose pre-flattened global badges with the same type.
public struct ChatBadgeKey: Hashable, Sendable {
    public let setId: String
    public let id: String
    public init(setId: String, id: String) {
        self.setId = setId
        self.id = id
    }
}

/// Image URL + human-readable title (used as the VoiceOver label so screen
/// readers say "Moderator" instead of "image, image, image"). Public for
/// the same reason as `ChatBadgeKey`.
public struct ChatBadgeEntry: Sendable, Equatable {
    public let url: URL
    public let title: String?
    public init(url: URL, title: String?) {
        self.url = url
        self.title = title
    }
}

/// Looks up chat-badge images for a single channel session.
///
/// Background: every chat message includes a `[ChatBadge]` array describing
/// the chatter's status (moderator, VIP, subscriber tier, broadcaster, etc.).
/// Each `ChatBadge` carries only the IDs (`set_id`, `id`) — not the image URL.
/// To render badges we have to call two Helix endpoints once per channel:
///
///   - `GET /chat/badges/global`  → generic badges (mod, prime, turbo, vip, …)
///     (cached at app launch in `GlobalCatalog` — we read from there when present)
///   - `GET /chat/badges?broadcaster_id=…` → custom subscriber tiers, founder,
///     game-specific, etc. (always fetched per channel)
///
/// Channel badges override global badges with the same `setId` — the channel's
/// custom subscriber art replaces the generic global icon, for example.
///
/// We populate `entries` once on `load(...)` and expose a synchronous
/// `entries(for:)` lookup so `ChatRow` can resolve images per-message without
/// awaiting. Errors during the fetch are non-fatal — missing badges simply
/// don't render (the username still shows).
@MainActor
@Observable
public final class ChatBadgeStore {

    /// `(setId, id) → entry`. Mutated once on `load()` completion.
    public private(set) var entries: [ChatBadgeKey: ChatBadgeEntry] = [:]

    /// Memoizes `entries(for:)` results keyed by the message's badge set.
    ///
    /// Most messages share an identical badge combination (empty, or e.g.
    /// "subscriber + moderator"), and `ChatScreen.body` re-evaluates on every
    /// new message — so the same set was being re-resolved (dictionary
    /// lookups + a fresh array allocation) for every visible row on every
    /// append. Caching collapses repeats to one resolution per distinct set
    /// and hands back a copy-on-write-shared array.
    ///
    /// `@ObservationIgnored` is load-bearing: `entries(for:)` is called *during*
    /// view-body evaluation (`ChatRow`), so if this cache were observation-
    /// tracked, mutating it on a miss would be "modifying state during view
    /// update." It's a pure memo, not model state, so it's correctly excluded.
    ///
    /// Distinct badge combinations are naturally bounded (a finite set of badge
    /// types, each user shows a handful), so the cache stays small; it's
    /// cleared whenever `entries` is republished by `load(...)`.
    ///
    /// Keyed by a hash of the `(setId, id)` pairs, computed straight off the
    /// message's `[ChatBadge]`, with the full key kept in the bucket for an
    /// exact comparison. A hit therefore allocates nothing — the previous
    /// `[[ChatBadgeKey]: …]` shape had to build the key array (one heap
    /// allocation per row per pass) just to look itself up.
    @ObservationIgnored private var resolvedCache: [Int: [ResolvedBadgeSet]] = [:]
    @ObservationIgnored private var resolvedCount = 0

    private struct ResolvedBadgeSet {
        let keys: [ChatBadgeKey]
        let entries: [ChatBadgeEntry]
    }

    /// Idempotency key — the channel id we last successfully loaded for.
    /// Multiple ChatScreen mounts for the same channel each call `load(...)`,
    /// but only the first triggers Helix calls. Public reset via
    /// `forceReload(...)` if a refresh becomes useful (not exposed today).
    private var loadedChannelId: String?

    /// The load currently fetching, if any. Set synchronously — before the
    /// first `await` — so a second mount's `load(...)` for the same channel
    /// joins it instead of starting a duplicate pair of Helix fetches (the
    /// `loadedChannelId` guard alone is only set after those awaits, so two
    /// overlapping mounts both used to pass it).
    @ObservationIgnored private var inFlightLoad: (channelId: String, task: Task<Void, Never>)?

    public init() {}

    /// Loads channel-specific badges and merges them on top of the supplied
    /// global slice. The global slice typically comes from `GlobalCatalog`
    /// (pre-fetched at app launch); when it's empty, we fall back to fetching
    /// global ourselves so chat still works if the catalog hasn't loaded yet.
    ///
    /// We could parallelize the two fetches with `async let`, but `Account` is
    /// a SwiftData `@Model` (non-Sendable), and passing it through `async let`
    /// trips Swift 6 strict-concurrency's sending check. The total cost is only
    /// a few hundred ms on a fire-and-forget background load — sequential
    /// keeps the code simple.
    public func load(
        account: Account,
        accountStore: AccountStore,
        channelId: String,
        globalBadges: [ChatBadgeKey: ChatBadgeEntry]
    ) async {
        if loadedChannelId == channelId {
            // Idempotent — already loaded for this channel. Subsequent view
            // mounts get the existing entries for free without re-hitting
            // Helix's /chat/badges endpoint.
            return
        }
        if let inFlight = inFlightLoad, inFlight.channelId == channelId {
            // A peer mount is already fetching this channel — share it.
            await inFlight.task.value
            return
        }

        // Only Sendable values cross into the load task: the client, the
        // account's stable userId (not the SwiftData @Model), and the
        // MainActor-isolated store itself.
        let client = accountStore.client(for: account)
        let userId = account.userId
        // Unstructured on purpose: the fetch belongs to this registry-owned
        // store, not to whichever view's `.task` asked first. A mount torn
        // down mid-fetch (tab swipe) no longer cancels it, so the next mount
        // finds the badges loaded instead of starting over.
        let task = Task { @MainActor in
            await self.performLoad(
                client: client,
                accountStore: accountStore,
                userId: userId,
                channelId: channelId,
                globalBadges: globalBadges
            )
        }
        inFlightLoad = (channelId, task)
        await task.value
    }

    private func performLoad(
        client: TwitchClient,
        accountStore: AccountStore,
        userId: String,
        channelId: String,
        globalBadges: [ChatBadgeKey: ChatBadgeEntry]
    ) async {
        defer {
            if inFlightLoad?.channelId == channelId { inFlightLoad = nil }
        }

        // Use the catalog's global slice when present; fall back to fetching
        // ourselves so first-channel-open before the catalog finishes still
        // gets badges (rare but possible on a slow network).
        let global: [ChatBadgeKey: ChatBadgeEntry]
        if !globalBadges.isEmpty {
            global = globalBadges
        } else {
            global = await fetchGlobal(client: client, accountStore: accountStore, userId: userId)
        }
        let channel = await fetchChannel(client: client, accountStore: accountStore, userId: userId, channelId: channelId)

        // Same cancellation-safety guard as `EmoteIndex.load`: if the load
        // was cancelled mid-flight, both fetch helpers returned `[:]` (their
        // `catch is CancellationError` swallows the cancel). Publishing here
        // would set `entries = [:]` (wiping any prior load) and mark
        // `loadedChannelId = channelId`, causing the next caller to short-
        // circuit and the channel's badges to stay permanently empty. The
        // load no longer runs inside a view's `.task`, so this is now a
        // belt-and-braces check rather than the common path.
        guard !Task.isCancelled else {
            logger.info("ChatBadgeStore load cancelled for channel \(channelId, privacy: .public); not publishing partial entries")
            return
        }

        // Channel overrides global at the (setId, id) granularity. This matches
        // Twitch's documented behavior: a channel's custom "subscriber" badge
        // versions replace the global ones; everything else stays global.
        var merged = global
        for (key, entry) in channel {
            merged[key] = entry
        }
        publish(entries: merged)
        loadedChannelId = channelId
        logger.info("Loaded \(merged.count) badge entries for channel \(channelId, privacy: .public) (global=\(global.count), channel=\(channel.count))")
    }

    /// Replaces the resolved table and drops memoized resolutions, which
    /// depend on it. Internal so tests can seed a table without Helix.
    func publish(entries merged: [ChatBadgeKey: ChatBadgeEntry]) {
        entries = merged
        resolvedCache.removeAll(keepingCapacity: true)
        resolvedCount = 0
    }

    /// Resolves a per-message badge list to drawable entries, preserving order
    /// and dropping any whose `(setId, id)` aren't in our cached sets (rare —
    /// happens when Twitch ships a new badge type after our last fetch).
    public func entries(for badges: [ChatBadge]) -> [ChatBadgeEntry] {
        // Badge-less chatters are common; an empty array literal is a shared
        // singleton, so this path allocates nothing either.
        guard !badges.isEmpty else { return [] }

        var hasher = Hasher()
        hasher.combine(badges.count)
        for badge in badges {
            hasher.combine(badge.setId)
            hasher.combine(badge.id)
        }
        let hash = hasher.finalize()

        if let bucket = resolvedCache[hash] {
            for candidate in bucket where Self.sameKeys(candidate.keys, as: badges) {
                return candidate.entries
            }
        }

        let keys = badges.map { ChatBadgeKey(setId: $0.setId, id: $0.id) }
        let resolved = keys.compactMap { entries[$0] }
        // Safety valve: distinct badge combinations are normally well under this
        // cap, but a long session on a large channel can keep minting new ones.
        // Drop an arbitrary bucket rather than grow without bound — every entry
        // is equally cheap to re-resolve (pure dictionary lookups).
        if resolvedCount >= Self.resolvedCacheCapacity, let evict = resolvedCache.first {
            resolvedCache.removeValue(forKey: evict.key)
            resolvedCount -= evict.value.count
        }
        resolvedCache[hash, default: []].append(ResolvedBadgeSet(keys: keys, entries: resolved))
        resolvedCount += 1
        return resolved
    }

    /// Exact `(setId, id)`-sequence comparison, without building a key array.
    private static func sameKeys(_ keys: [ChatBadgeKey], as badges: [ChatBadge]) -> Bool {
        guard keys.count == badges.count else { return false }
        for (key, badge) in zip(keys, badges) where key.setId != badge.setId || key.id != badge.id {
            return false
        }
        return true
    }

    /// Upper bound on memoized badge-combination resolutions. Generous — a real
    /// channel shows far fewer distinct combinations than this; the cap exists
    /// only to stop unbounded growth over a multi-hour session.
    private static let resolvedCacheCapacity = 512

    // MARK: - Private fetch helpers

    private func fetchGlobal(
        client: TwitchClient,
        accountStore: AccountStore,
        userId: String
    ) async -> [ChatBadgeKey: ChatBadgeEntry] {
        do {
            let sets = try await accountStore.withTokenRefresh(forUserId: userId) {
                try await client.api.fetchGlobalBadges()
            }
            return Self.flatten(sets: sets)
        } catch is CancellationError {
            // Expected on view tear-down — silently exit.
            return [:]
        } catch {
            // Non-fatal: chat still renders without badges.
            logger.error("Failed to load global badges: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func fetchChannel(
        client: TwitchClient,
        accountStore: AccountStore,
        userId: String,
        channelId: String
    ) async -> [ChatBadgeKey: ChatBadgeEntry] {
        do {
            let sets = try await accountStore.withTokenRefresh(forUserId: userId) {
                try await client.api.fetchChannelBadges(forBroadcasterID: channelId)
            }
            return Self.flatten(sets: sets)
        } catch is CancellationError {
            // Expected when ChatScreen unmounts mid-fetch — the dual-mount
            // transition on openChannel cancels the badge .task on the first
            // ChatScreen instance. Silently exit instead of polluting logs.
            return [:]
        } catch {
            logger.error("Failed to load channel badges for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    /// Flattens `[TwitchBadgeSet] → [ChatBadgeKey: ChatBadgeEntry]` using the
    /// 4x image (72×72) so badges render crisply at 18pt on @3x iPhones —
    /// 18pt × 3 = 54 physical pixels, well under 72 so the scaler downsamples
    /// cleanly. The 1x (18×18) version would look pixelated on Retina; 2x is
    /// borderline. Memory cost is trivial — badges are PNGs of a few KB.
    ///
    /// `public` because `GlobalCatalog` (Features module) reuses it to
    /// pre-flatten the global badge sets it fetches at app launch. Before T11
    /// this lived in Features alongside GlobalCatalog and was `internal`;
    /// the move to Channels widens visibility because the cross-module
    /// reuse is still wanted.
    public static func flatten(sets: [TwitchBadgeSet]) -> [ChatBadgeKey: ChatBadgeEntry] {
        var out: [ChatBadgeKey: ChatBadgeEntry] = [:]
        for set in sets {
            for version in set.versions {
                guard let url = URL(string: version.imageUrl4x) else { continue }
                out[ChatBadgeKey(setId: set.setId, id: version.id)] = ChatBadgeEntry(
                    url: url,
                    title: version.title
                )
            }
        }
        return out
    }
}
