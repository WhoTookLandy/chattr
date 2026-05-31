import Foundation
import SwiftUI
import Accounts
import Channels
import TwitchKit
import Core
import Nuke
import os

private let logger = AppLogger.make("Features.ChatImagePrefetcher")

/// Warms Nuke's image cache with the assets chat will need to render —
/// Twitch global emotes, the signed-in user's subscribed emotes, global
/// badges (mod/VIP/Prime/etc.), and per-channel badges (tier-specific
/// subscriber art).
///
/// ## Why prefetch
///
/// Without prefetch, every chat-row image fetches+decodes the first
/// time it scrolls into view. For frequently-used emotes/badges,
/// that's a 200-500ms perceptual delay per first display (network +
/// decode). With prefetch, the network work happens once at boot (or
/// channel entry) in the background, and every subsequent display
/// hits a warm cache.
///
/// ## Two destinations
///
/// Nuke's `ImagePrefetcher` can target the memory cache (download +
/// decode + ready-to-render) OR the disk cache (download + store-on-
/// disk, no decode). We use both:
///
///   - **`.memoryCache`** for assets that appear in nearly every
///     chat message: global emotes (~50 unique) and global badges
///     (~30 unique). Worth keeping decoded in RAM.
///   - **`.diskCache`** for assets the user might or might not see
///     in this session: subscribed-channel emotes (potentially
///     hundreds), per-channel badges. Disk-only saves RAM; decode
///     happens lazily on first display.
///
/// ## Priority
///
/// All prefetch requests run at `.veryLow` priority so they never
/// win races against actual on-screen `LazyImage` requests
/// (`.normal` by default). Foreground always feels instant; prefetch
/// is background opportunism.
@MainActor
public final class ChatImagePrefetcher {

    /// Prefetches into Nuke's memory cache (download + decode +
    /// memory store). For hot assets that appear in almost every message.
    private let memoryPrefetcher: ImagePrefetcher

    /// Prefetches into Nuke's disk cache only (download + disk store,
    /// no decode). For cold-tail assets we might not see immediately.
    private let diskPrefetcher: ImagePrefetcher

    public init() {
        // Bounded concurrency — bumping default 2 to 4 lets us saturate
        // Twitch's CDN faster on cold launch without competing with
        // foreground (which is on the same shared ImagePipeline).
        self.memoryPrefetcher = ImagePrefetcher(
            destination: .memoryCache,
            maxConcurrentRequestCount: 4
        )
        self.diskPrefetcher = ImagePrefetcher(
            destination: .diskCache,
            maxConcurrentRequestCount: 4
        )
        // `.veryLow` priority so prefetch never wins races against
        // actual on-screen LazyImage requests (which default to
        // `.normal`). On-screen always feels instant; prefetch is
        // background opportunism.
        memoryPrefetcher.priority = .veryLow
        diskPrefetcher.priority = .veryLow
    }

    // MARK: - Global emotes (launch-time)

    /// Warm the memory cache with every URL behind Twitch's global
    /// emote set. Called by `RootView` after `GlobalCatalog.load`
    /// completes — by then we have the emote IDs to build URLs from.
    public func prefetchGlobalEmotes(_ emotes: [TwitchEmote]) {
        let requests = emotes.compactMap { emote -> ImageRequest? in
            guard let url = Self.emoteCDNURL(for: emote) else { return nil }
            return ImageRequest(url: url, priority: .veryLow)
        }
        guard !requests.isEmpty else { return }
        memoryPrefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) global emote images (memory)")
    }

    // MARK: - Global badges (launch-time)

    /// Warm the memory cache with global badge images (moderator, VIP,
    /// Prime, Turbo, subscriber default tiers, etc.). `GlobalCatalog`
    /// pre-flattens them into a dict keyed by `(setId, id)`; we just
    /// pluck the URLs.
    ///
    /// ~30-40 URLs total. Tiny. Worth the memory.
    public func prefetchGlobalBadges(_ entries: [ChatBadgeKey: ChatBadgeEntry]) {
        let requests = entries.values.map { entry in
            ImageRequest(url: entry.url, priority: .veryLow)
        }
        guard !requests.isEmpty else { return }
        memoryPrefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) global badge images (memory)")
    }

    // MARK: - User-subscribed emotes (launch-time)

    /// Walk the paginated `GET /chat/emotes/user` endpoint and disk-
    /// cache prefetch every URL. The endpoint returns every emote the
    /// user can use — subscribed channels' tiered emotes, Prime/Turbo
    /// global slots, etc.
    ///
    /// Errors handled silently:
    ///   - `HelixError.unauthorized` → user signed in before we added
    ///     `user:read:emotes` scope. Log a note suggesting reauth and
    ///     move on. The app still works.
    ///   - Other errors (network blip, server hiccup) → log and exit.
    ///     Next launch retries; in the meantime images fetch on first
    ///     display.
    public func prefetchUserSubscribedEmotes(
        account: Account,
        accountStore: AccountStore
    ) async {
        // Account is a SwiftData @Model (non-Sendable). Extract the
        // userId BEFORE the @Sendable withTokenRefresh closure so we
        // don't capture the Account itself across the boundary —
        // mirrors the pattern used elsewhere in the codebase.
        let userId = account.userId
        let client = accountStore.client(for: account)
        var requests: [ImageRequest] = []
        var cursor: String? = nil
        var pageCount = 0

        // Walk pages until cursor returns nil. Each page is ~25-100
        // emotes; users with many subs can have several pages worth.
        // No artificial cap — Twitch's pagination naturally terminates.
        repeat {
            do {
                let page = try await accountStore.withTokenRefresh(for: account) { [cursor, userId] in
                    try await client.api.fetchUserEmotesPage(
                        userID: userId,
                        after: cursor
                    )
                }
                pageCount += 1
                for emote in page.data {
                    if let url = Self.emoteCDNURL(for: emote) {
                        requests.append(ImageRequest(url: url, priority: .veryLow))
                    }
                }
                cursor = page.nextCursor
            } catch HelixError.unauthorized {
                // Sign-in pre-dates the `user:read:emotes` scope. Bail
                // silently — the next sign-in (or sign-out + back-in)
                // will pick it up. App continues normally.
                logger.notice("User emote prefetch skipped: missing user:read:emotes scope (existing account, no reauth yet)")
                return
            } catch is CancellationError {
                // RootView .task cancelled by view tear-down (account
                // swap, app close). Silent exit — partial prefetch is
                // fine, anything that did land is cached for next time.
                return
            } catch {
                logger.warning("User emote prefetch failed at page \(pageCount): \(error.localizedDescription, privacy: .public)")
                break
            }
        } while cursor != nil

        guard !requests.isEmpty else { return }
        diskPrefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) user emote images (disk) across \(pageCount) page(s)")
    }

    // MARK: - Channel badges (per-channel entry)

    /// Warm the disk cache with every URL in the merged badge dict
    /// for a channel — tier-1/2/3 subscriber art, channel-custom
    /// moderator/founder badges, cheer-tier badges, etc.
    ///
    /// Called by `ChatScreen`'s badge-load `.task` after
    /// `ChatBadgeStore.load` completes. The store returns the FULL
    /// merged dictionary (global + channel-specific URLs); we take
    /// it as-is since:
    ///
    ///   - Some "channel" badges override globals with new art
    ///     (e.g., a channel's custom subscriber tier-1 icon), and
    ///     we don't track which-is-which at this layer.
    ///   - The global slice was already prefetched at launch into
    ///     memory cache, so re-requesting those URLs is a cheap
    ///     no-op (Nuke's cache short-circuits the request).
    ///
    /// Disk cache (not memory) because channel-specific badges only
    /// appear when someone WITH that badge chats — could be every
    /// message, could be never. Decoding lazily keeps memory bounded.
    public func prefetchChannelBadges(_ entries: [ChatBadgeKey: ChatBadgeEntry]) {
        let requests = entries.values.map { entry in
            ImageRequest(url: entry.url, priority: .veryLow)
        }
        guard !requests.isEmpty else { return }
        diskPrefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) channel badge images (disk)")
    }

    // MARK: - URL construction

    /// Build a CDN URL for a given emote, preferring animated when
    /// available. The 2x scale matches our row-render size (24-28pt
    /// on @2x/@3x displays).
    ///
    /// We use the same URL pattern as `TwitchEmoteImage` so the
    /// prefetch results land in the cache under the same key the
    /// runtime `LazyImage` will look them up by.
    private static func emoteCDNURL(for emote: TwitchEmote) -> URL? {
        let format = emote.format.contains("animated") ? "animated" : "static"
        return Endpoints.TwitchCDN.emote(id: emote.id, format: format)
    }
}

// MARK: - Environment plumbing

/// Default is nil because `ChatImagePrefetcher()` is `@MainActor`-isolated
/// (the class is) and `EnvironmentKey.defaultValue` is evaluated in a
/// nonisolated context. The Optional shape is the idiomatic SwiftUI
/// workaround — same pattern used by `GlobalCatalog` and
/// `ChannelSessionRegistry`.
private struct ChatImagePrefetcherKey: EnvironmentKey {
    static let defaultValue: ChatImagePrefetcher? = nil
}

public extension EnvironmentValues {
    /// App-wide chat image prefetcher. Injected by `RootView`. Callers
    /// (`ChatScreen` for channel-badge prefetch on mount) read this and
    /// call the appropriate `prefetch...` method. Reading `nil` from
    /// previews / detached views is fine — the call site just skips.
    var chatImagePrefetcher: ChatImagePrefetcher? {
        get { self[ChatImagePrefetcherKey.self] }
        set { self[ChatImagePrefetcherKey.self] = newValue }
    }
}
