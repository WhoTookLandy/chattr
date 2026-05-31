import Foundation
import Accounts
import TwitchKit
import Core
import Nuke
import os

private let logger = AppLogger.make("Features.EmoteImagePrefetcher")

/// Warms Nuke's image cache with Twitch's global emotes (Kappa, LUL, etc.)
/// AND every emote the signed-in user has access to from their
/// subscriptions, Prime, and Turbo entitlements.
///
/// ## Why this exists
///
/// Without prefetch, every emote image fetches+decodes the first time
/// it scrolls into view. For frequently-typed emotes like global
/// favorites, that's a 200-500ms perceptual delay (network + decode)
/// before the row's emote pops in. For subscribed channels' emotes,
/// the first time you visit that channel after launch, you watch the
/// whole emote set load in.
///
/// Prefetching at launch makes that whole class of delay invisible:
/// the network work happens once at boot (parallel with other launch
/// work, in the background) and every subsequent display hits a warm
/// cache.
///
/// ## Two destinations, one prefetcher
///
/// Nuke's `ImagePrefetcher` can target either the memory cache
/// (download + decode + ready-to-render) OR the disk cache (download +
/// store-on-disk, no decode). We use both:
///
///   - **Global emotes → `.memoryCache`**: ~50 unique emotes that
///     appear in nearly every chat message. Worth keeping decoded in
///     RAM (~5 MB total for all 50 at 2x).
///   - **User emotes → `.diskCache`**: potentially hundreds of
///     subscribed-channel emotes the user might or might not see in
///     this session. Disk-only saves RAM; decode happens lazily on
///     first display, which is fast because the data is already
///     local.
///
/// ## Async, never-blocking
///
/// Every entry point is async, runs in a Task spawned by `RootView`'s
/// existing `.task(id:)` pattern. Failures are logged and swallowed —
/// the app falls back to per-display fetch on the way to chat.
@MainActor
public final class EmoteImagePrefetcher {

    /// Prefetches into Nuke's memory cache (download + decode +
    /// memory store). Used for global emotes.
    private let memoryPrefetcher: ImagePrefetcher

    /// Prefetches into Nuke's disk cache only (download + disk store,
    /// no decode). Used for user-subscribed emotes.
    private let diskPrefetcher: ImagePrefetcher

    public init() {
        // Bounded concurrency — Nuke defaults to 2, which is fine for a
        // background prefetch we don't want competing with the
        // foreground chat-row image loads. Bumping to 4 lets us
        // saturate Twitch's CDN a bit faster on cold launch without
        // blocking the higher-priority on-screen requests.
        self.memoryPrefetcher = ImagePrefetcher(
            destination: .memoryCache,
            maxConcurrentRequestCount: 4
        )
        self.diskPrefetcher = ImagePrefetcher(
            destination: .diskCache,
            maxConcurrentRequestCount: 4
        )
        // `.veryLow` priority so prefetch never wins races against
        // actual on-screen LazyImage requests (those default to
        // `.normal`). On-screen always feels instant; prefetch is
        // background opportunism.
        memoryPrefetcher.priority = .veryLow
        diskPrefetcher.priority = .veryLow
    }

    // MARK: - Global emotes

    /// Warm the memory cache with every URL behind Twitch's global
    /// emote set. Synchronous setup; the actual downloads run on
    /// Nuke's worker queue and update the cache as they complete.
    ///
    /// Called by `GlobalCatalog` after it finishes fetching the
    /// global emote metadata.
    public func prefetchGlobalEmotes(_ emotes: [TwitchEmote]) {
        let requests = emotes.compactMap { emote -> ImageRequest? in
            guard let url = Self.cdnURL(for: emote) else { return nil }
            return ImageRequest(url: url, priority: .veryLow)
        }
        guard !requests.isEmpty else { return }
        memoryPrefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) global emote images (memory)")
    }

    // MARK: - User emotes

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
                    if let url = Self.cdnURL(for: emote) {
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

    // MARK: - URL construction

    /// Build a CDN URL for a given emote, preferring animated when
    /// available. The 2x scale matches our row-render size (24-28pt
    /// on @2x/@3x displays).
    ///
    /// We use the same URL pattern as `TwitchEmoteImage` so the
    /// prefetch results land in the cache under the same key the
    /// runtime `LazyImage` will look them up by.
    private static func cdnURL(for emote: TwitchEmote) -> URL? {
        let format = emote.format.contains("animated") ? "animated" : "static"
        return Endpoints.TwitchCDN.emote(id: emote.id, format: format)
    }
}
