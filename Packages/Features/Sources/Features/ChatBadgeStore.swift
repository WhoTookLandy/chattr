import Foundation
import SwiftUI
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ChatBadgeStore")

/// Looks up chat-badge images for a single channel session.
///
/// Background: every chat message includes a `[ChatBadge]` array describing
/// the chatter's status (moderator, VIP, subscriber tier, broadcaster, etc.).
/// Each `ChatBadge` carries only the IDs (`set_id`, `id`) — not the image URL.
/// To render badges we have to call two Helix endpoints once per channel:
///
///   - `GET /chat/badges/global`  → generic badges (mod, prime, turbo, vip, …)
///   - `GET /chat/badges?broadcaster_id=…` → custom subscriber tiers, founder,
///     game-specific, etc.
///
/// Channel badges override global badges with the same `setId` — the channel's
/// custom subscriber art replaces the generic global icon, for example.
///
/// We populate `entries` once on `load(...)` and expose a synchronous
/// `urls(for:)` lookup so `ChatRow` can resolve images per-message without
/// awaiting. Errors during the fetch are non-fatal — missing badges simply
/// don't render (the username still shows).
@MainActor
@Observable
final class ChatBadgeStore {

    /// `(setId, id) → entry`. Mutated once on `load()` completion.
    private(set) var entries: [BadgeKey: BadgeEntry] = [:]

    /// Stable composite key matching `ChatBadge`'s identity pair.
    struct BadgeKey: Hashable, Sendable {
        let setId: String
        let id: String
    }

    /// Image URL + human-readable title (used as the VoiceOver label so
    /// screen readers say "Moderator" instead of "image, image, image").
    struct BadgeEntry: Sendable {
        let url: URL
        let title: String?
    }

    /// Fetches global + channel badge sets sequentially and populates `entries`.
    /// Safe to call multiple times — the merge is total, not incremental.
    ///
    /// We could parallelize the two fetches with `async let`, but `Account` is a
    /// SwiftData `@Model` (non-Sendable), and passing it through `async let`
    /// trips Swift 6 strict-concurrency's sending check. The total cost is only
    /// a few hundred ms during a fire-and-forget background load — sequential
    /// keeps the code simple and avoids the userId/login-string workaround
    /// pattern used elsewhere in this codebase.
    func load(account: Account, accountStore: AccountStore, channelId: String) async {
        let client = accountStore.client(for: account)

        let global = await fetchGlobal(client: client, accountStore: accountStore, account: account)
        let channel = await fetchChannel(client: client, accountStore: accountStore, account: account, channelId: channelId)

        // Channel overrides global at the (setId, id) granularity. This matches
        // Twitch's documented behavior: a channel's custom "subscriber" badge
        // versions replace the global ones; everything else stays global.
        var merged = global
        for (key, entry) in channel {
            merged[key] = entry
        }
        entries = merged
        logger.info("Loaded \(merged.count) badge entries for channel \(channelId)")
    }

    /// Resolves a per-message badge list to drawable entries, preserving order
    /// and dropping any whose `(setId, id)` aren't in our cached sets (rare —
    /// happens when Twitch ships a new badge type after our last fetch).
    func entries(for badges: [ChatBadge]) -> [BadgeEntry] {
        badges.compactMap { entries[BadgeKey(setId: $0.setId, id: $0.id)] }
    }

    // MARK: - Private fetch helpers

    private func fetchGlobal(
        client: TwitchClient,
        accountStore: AccountStore,
        account: Account
    ) async -> [BadgeKey: BadgeEntry] {
        do {
            let sets = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchGlobalBadges()
            }
            return Self.flatten(sets: sets)
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
    ) async -> [BadgeKey: BadgeEntry] {
        do {
            let sets = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.fetchChannelBadges(forBroadcasterID: channelId)
            }
            return Self.flatten(sets: sets)
        } catch {
            logger.error("Failed to load channel badges for \(channelId): \(error.localizedDescription)")
            return [:]
        }
    }

    /// Flattens `[TwitchBadgeSet] → [BadgeKey: BadgeEntry]` using the 4x image
    /// (72×72) so badges render crisply at 18pt on @3x iPhones — 18pt × 3 = 54
    /// physical pixels, well under 72 so the scaler downsamples cleanly. The 1x
    /// (18×18) version would look pixelated on Retina; 2x is borderline. Memory
    /// cost is trivial — badges are PNGs of a few KB.
    private static func flatten(sets: [TwitchBadgeSet]) -> [BadgeKey: BadgeEntry] {
        var out: [BadgeKey: BadgeEntry] = [:]
        for set in sets {
            for version in set.versions {
                guard let url = URL(string: version.imageUrl4x) else { continue }
                out[BadgeKey(setId: set.setId, id: version.id)] = BadgeEntry(
                    url: url,
                    title: version.title
                )
            }
        }
        return out
    }
}
