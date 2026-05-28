import Foundation
import SwiftUI
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ChatBadgeStore")

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
public struct ChatBadgeEntry: Sendable {
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

    /// Idempotency key — the channel id we last successfully loaded for.
    /// Multiple ChatScreen mounts for the same channel each call `load(...)`,
    /// but only the first triggers Helix calls. Public reset via
    /// `forceReload(...)` if a refresh becomes useful (not exposed today).
    private var loadedChannelId: String?

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
        let client = accountStore.client(for: account)

        // Use the catalog's global slice when present; fall back to fetching
        // ourselves so first-channel-open before the catalog finishes still
        // gets badges (rare but possible on a slow network).
        let global: [ChatBadgeKey: ChatBadgeEntry]
        if !globalBadges.isEmpty {
            global = globalBadges
        } else {
            global = await fetchGlobal(client: client, accountStore: accountStore, account: account)
        }
        let channel = await fetchChannel(client: client, accountStore: accountStore, account: account, channelId: channelId)

        // Same cancellation-safety guard as `EmoteIndex.load`: if the parent
        // task was cancelled mid-flight, both fetch helpers returned `[:]`
        // (their `catch is CancellationError` swallows the cancel). Publishing
        // here would set `entries = [:]` (wiping any prior load) and mark
        // `loadedChannelId = channelId`, causing the next caller to short-
        // circuit and the channel's badges to stay permanently empty.
        //
        // Registry-owned ChatBadgeStore makes this guard essential — under
        // SwiftUI view churn the `.task` modifier can cancel us mid-flight,
        // and the next-mount needs to retry from a clean slate.
        guard !Task.isCancelled else {
            logger.info("ChatBadgeStore load cancelled for channel \(channelId); not publishing partial entries")
            return
        }

        // Channel overrides global at the (setId, id) granularity. This matches
        // Twitch's documented behavior: a channel's custom "subscriber" badge
        // versions replace the global ones; everything else stays global.
        var merged = global
        for (key, entry) in channel {
            merged[key] = entry
        }
        entries = merged
        loadedChannelId = channelId
        logger.info("Loaded \(merged.count) badge entries for channel \(channelId) (global=\(global.count), channel=\(channel.count))")
    }

    /// Resolves a per-message badge list to drawable entries, preserving order
    /// and dropping any whose `(setId, id)` aren't in our cached sets (rare —
    /// happens when Twitch ships a new badge type after our last fetch).
    public func entries(for badges: [ChatBadge]) -> [ChatBadgeEntry] {
        badges.compactMap { entries[ChatBadgeKey(setId: $0.setId, id: $0.id)] }
    }

    // MARK: - Private fetch helpers

    private func fetchGlobal(
        client: TwitchClient,
        accountStore: AccountStore,
        account: Account
    ) async -> [ChatBadgeKey: ChatBadgeEntry] {
        do {
            let sets = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchGlobalBadges()
            }
            return Self.flatten(sets: sets)
        } catch is CancellationError {
            // Expected on view tear-down — silently exit.
            return [:]
        } catch {
            // Non-fatal: chat still renders without badges.
            logger.error("Failed to load global badges: \(error.localizedDescription)")
            return [:]
        }
    }

    private func fetchChannel(
        client: TwitchClient,
        accountStore: AccountStore,
        account: Account,
        channelId: String
    ) async -> [ChatBadgeKey: ChatBadgeEntry] {
        do {
            let sets = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchChannelBadges(forBroadcasterID: channelId)
            }
            return Self.flatten(sets: sets)
        } catch is CancellationError {
            // Expected when ChatScreen unmounts mid-fetch — the dual-mount
            // transition on openChannel cancels the badge .task on the first
            // ChatScreen instance. Silently exit instead of polluting logs.
            return [:]
        } catch {
            logger.error("Failed to load channel badges for \(channelId): \(error.localizedDescription)")
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
