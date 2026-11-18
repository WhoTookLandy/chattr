import Foundation
import Network
import SwiftUI
import Accounts
import Channels
import TwitchKit
import Core
import Nuke
import os

private let logger = AppLogger.make("Features.ChatImagePrefetcher")

/// Warms Nuke's image cache with the assets chat will need to render —
/// Twitch global emotes, the signed-in user's subscribed emotes, the
/// commonest global badges (mod/VIP/Prime/etc.), and per-channel badges
/// (tier-specific subscriber art).
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
///     chat message: static global emotes and the handful of global
///     badge sets most chatters wear (`commonGlobalBadgeSets`). Worth
///     keeping decoded in RAM. (Animated globals go to disk — their
///     renderer reads raw bytes, not decoded images.)
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
///
/// ## Doing it once, and only when it's free
///
/// - Every URL handed to Nuke is remembered for the life of the process,
///   so remounting a chat or switching accounts doesn't resubmit tables
///   that are already queued or cached.
/// - The subscribed-emote walk (every Helix page, then hundreds of images)
///   runs at most once a day per account.
/// - Nothing is prefetched on an expensive (cellular, hotspot) or
///   constrained (Low Data Mode) network: the methods skip while the
///   current path is one, and each request also forbids those networks in
///   case the path changes while the queue drains.
@MainActor
public final class ChatImagePrefetcher {

    /// Prefetches into Nuke's memory cache (download + decode +
    /// memory store). For hot assets that appear in almost every message.
    private let memoryPrefetcher: ImagePrefetcher

    /// Prefetches into Nuke's disk cache only (download + disk store,
    /// no decode). For cold-tail assets we might not see immediately.
    private let diskPrefetcher: ImagePrefetcher

    /// The subscribed-emote queue, in a prefetcher of its own so an
    /// account switch can drop the old account's downloads without
    /// touching the account-independent ones above.
    private var userEmotePrefetcher: ImagePrefetcher?

    /// The account whose subscribed-emote queue is still downloading.
    private var userEmoteQueueAccount: String?

    /// Every global-emote and badge URL already handed to Nuke.
    private var submitted: Set<URL> = []

    /// The whole global badge table, so the per-channel prefetch can tell
    /// a channel's own badges from the globals merged into its table.
    private var globalBadgeURLs: Set<URL> = []

    public init() {
        self.memoryPrefetcher = ChatImagePrefetcher.makePrefetcher(.memoryCache)
        self.diskPrefetcher = ChatImagePrefetcher.makePrefetcher(.diskCache)
        // Start watching the network now, so the path is known by the time
        // the first prefetch (after the global catalog loads) asks.
        _ = ChatImagePrefetcher.pathMonitor
    }

    /// Bounded concurrency — bumping default 2 to 4 lets us saturate
    /// Twitch's CDN faster on cold launch without competing with
    /// foreground (which is on the same shared ImagePipeline).
    ///
    /// `.veryLow` priority so prefetch never wins races against
    /// actual on-screen LazyImage requests (which default to
    /// `.normal`). On-screen always feels instant; prefetch is
    /// background opportunism.
    private static func makePrefetcher(_ destination: ImagePrefetcher.Destination) -> ImagePrefetcher {
        let prefetcher = ImagePrefetcher(destination: destination, maxConcurrentRequestCount: 4)
        prefetcher.priority = .veryLow
        return prefetcher
    }

    // MARK: - Global emotes (launch-time)

    /// Warm the caches for every URL behind Twitch's global emote set.
    /// Called by `RootView` after `GlobalCatalog.load` completes — by then
    /// we have the emote IDs to build URLs from.
    ///
    /// Split by how each emote is rendered:
    ///   - **static** → memory cache (decoded `UIImage`), which is exactly
    ///     what `LazyImage` reads.
    ///   - **animated** → disk (data) cache only. `AnimatedImageView` never
    ///     reads Nuke's decoded-image memory cache — it pulls raw bytes via
    ///     `ImagePipeline.data(for:)` and runs its own ImageIO frame decode —
    ///     so a memory prefetch decoded a first-frame image nobody used and
    ///     spent RAM on it.
    public func prefetchGlobalEmotes(_ emotes: [TwitchEmote]) {
        guard !Self.networkIsCostly else { return }
        // The same resolver the rows use, with the same playback setting,
        // so what lands in the cache is what a row will ask for.
        let animate = Self.rowsAnimateEmotes()
        var staticRequests: [ImageRequest] = []
        var animatedRequests: [ImageRequest] = []
        for emote in emotes {
            let source = EmoteImageSource.twitch(id: emote.id, formats: emote.format, animate: animate)
            guard let url = source.url, submitted.insert(url).inserted else { continue }
            let request = Self.prefetchRequest(for: url)
            if source.isAnimated {
                animatedRequests.append(request)
            } else {
                staticRequests.append(request)
            }
        }
        if !staticRequests.isEmpty {
            memoryPrefetcher.startPrefetching(with: staticRequests)
        }
        if !animatedRequests.isEmpty {
            diskPrefetcher.startPrefetching(with: animatedRequests)
        }
        guard !staticRequests.isEmpty || !animatedRequests.isEmpty else { return }
        logger.info("Prefetching \(staticRequests.count) static (memory) + \(animatedRequests.count) animated (disk) global emote images")
    }

    // MARK: - Global badges (launch-time)

    /// Global badge sets worn by a large share of chatters, most likely
    /// first. Only these are decoded into memory at launch: the full global
    /// table runs to hundreds of versions (event, game and bits-tier
    /// badges), nearly all of which a session never shows. Set ids are
    /// Twitch's; one that isn't in the table simply matches nothing.
    nonisolated static let commonGlobalBadgeSets = [
        "broadcaster", "moderator", "vip", "partner", "premium", "turbo",
        "staff", "founder", "no_audio", "no_video", "subscriber",
    ]

    /// Backstop on the memory prefetch, whatever the table holds — the
    /// multi-version sets (`subscriber`) are last in the list and take
    /// what room is left.
    nonisolated static let maxMemoryPrefetchedBadges = 48

    /// The badge URLs worth decoding into memory up front, in
    /// `commonGlobalBadgeSets` order, capped at `maxMemoryPrefetchedBadges`.
    nonisolated static func commonBadgeURLs(
        in entries: [ChatBadgeKey: ChatBadgeEntry],
        sets: [String],
        limit: Int
    ) -> [URL] {
        var urls: [URL] = []
        for setId in sets {
            let versions = entries
                .filter { $0.key.setId == setId }
                .sorted { $0.key.id.compare($1.key.id, options: .numeric) == .orderedAscending }
            for version in versions where urls.count < limit {
                urls.append(version.value.url)
            }
        }
        return urls
    }

    /// Warm the memory cache with the common global badge images
    /// (moderator, VIP, Prime, Turbo, subscriber default tiers, etc.).
    /// `GlobalCatalog` pre-flattens them into a dict keyed by
    /// `(setId, id)`; we pick the common sets out of it. The rest of the
    /// table loads when a badge is first shown.
    public func prefetchGlobalBadges(_ entries: [ChatBadgeKey: ChatBadgeEntry]) {
        for entry in entries.values {
            globalBadgeURLs.insert(entry.url)
        }
        guard !Self.networkIsCostly else { return }
        let urls = Self.commonBadgeURLs(
            in: entries, sets: Self.commonGlobalBadgeSets, limit: Self.maxMemoryPrefetchedBadges)
        let requests = urls
            .filter { submitted.insert($0).inserted }
            .map { Self.prefetchRequest(for: $0) }
        guard !requests.isEmpty else { return }
        memoryPrefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) of \(entries.count) global badge images (memory)")
    }

    // MARK: - User-subscribed emotes (launch-time)

    /// Walk the paginated `GET /chat/emotes/user` endpoint and disk-
    /// cache prefetch every URL. The endpoint returns every emote the
    /// user can use — subscribed channels' tiered emotes, Prime/Turbo
    /// global slots, etc.
    ///
    /// At most once a day per account (`walkInterval`): the set changes
    /// when the user subscribes somewhere, not between launches, and the
    /// images it found are on disk already.
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

        // Another account's queue is still downloading: those emotes are
        // for chats this account won't open. Stop it, and let that account
        // walk again next time since it never finished.
        if let queued = userEmoteQueueAccount, queued != userId {
            userEmotePrefetcher?.stopPrefetching()
            userEmotePrefetcher = nil
            userEmoteQueueAccount = nil
            Self.setWalkStamp(nil, forAccount: queued)
            logger.notice("Stopped the previous account's emote prefetch on account switch")
        }

        guard Self.isWalkDue(lastWalk: Self.walkStamp(forAccount: userId), now: Date()) else { return }
        guard !Self.networkIsCostly else {
            logger.info("User emote prefetch skipped: expensive or constrained network")
            return
        }

        let client = accountStore.client(for: account)
        let animate = Self.rowsAnimateEmotes()
        var requests: [ImageRequest] = []
        var cursor: String? = nil
        var pageCount = 0
        var walkFailed = false

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
                    let source = EmoteImageSource.twitch(id: emote.id, formats: emote.format, animate: animate)
                    if let url = source.url {
                        requests.append(Self.prefetchRequest(for: url))
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
                // swap, app close). Silent exit — nothing was submitted,
                // and the walk isn't stamped, so it runs again.
                return
            } catch {
                logger.warning("User emote prefetch failed at page \(pageCount): \(error.localizedDescription, privacy: .public)")
                walkFailed = true
                break
            }
        } while cursor != nil

        // Cancelled while the last page was in flight: the account may have
        // changed, so don't queue this one's images.
        guard !Task.isCancelled else { return }

        // Only a complete walk counts for the day; a partial one still
        // queues what it found and tries again on the next launch.
        if !walkFailed {
            Self.setWalkStamp(Date(), forAccount: userId)
        }

        guard !requests.isEmpty else { return }
        let prefetcher = Self.makePrefetcher(.diskCache)
        prefetcher.didComplete = { [weak self] in
            self?.userEmoteQueueDidDrain(forAccount: userId)
        }
        // Replacing the previous prefetcher releases it, which cancels
        // anything it still had outstanding.
        userEmotePrefetcher = prefetcher
        userEmoteQueueAccount = userId
        prefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) user emote images (disk) across \(pageCount) page(s)")
    }

    private func userEmoteQueueDidDrain(forAccount userId: String) {
        guard userEmoteQueueAccount == userId else { return }
        userEmoteQueueAccount = nil
        userEmotePrefetcher = nil
    }

    // MARK: - Channel badges (per-channel entry)

    /// Warm the disk cache with a channel's own badges — tier-1/2/3
    /// subscriber art, channel-custom moderator/founder badges, cheer-tier
    /// badges, etc.
    ///
    /// Called by `ChatScreen`'s badge-load `.task` after
    /// `ChatBadgeStore.load` completes, on every mount, with the FULL
    /// merged dictionary (global + channel-specific URLs). Two things keep
    /// that cheap:
    ///
    ///   - URLs from the global table are skipped: the common ones were
    ///     prefetched into memory at launch and the long tail loads on
    ///     first display. A channel badge that overrides a global one has
    ///     its own URL, so it isn't mistaken for it.
    ///   - URLs already submitted are skipped, so a remount (tab swipe,
    ///     pager recycling) submits nothing.
    ///
    /// Disk cache (not memory) because channel-specific badges only
    /// appear when someone WITH that badge chats — could be every
    /// message, could be never. Decoding lazily keeps memory bounded.
    public func prefetchChannelBadges(_ entries: [ChatBadgeKey: ChatBadgeEntry]) {
        guard !Self.networkIsCostly else { return }
        var requests: [ImageRequest] = []
        for entry in entries.values {
            guard !globalBadgeURLs.contains(entry.url), submitted.insert(entry.url).inserted else { continue }
            requests.append(Self.prefetchRequest(for: entry.url))
        }
        guard !requests.isEmpty else { return }
        diskPrefetcher.startPrefetching(with: requests)
        logger.info("Prefetching \(requests.count) channel badge images (disk)")
    }

    // MARK: - Cache reset

    /// Forget what was already prefetched. Called after Storage → Clear
    /// Cache: the images are gone, so the remembered URLs and the daily
    /// walk stamps no longer describe what is on disk.
    public func forgetSubmissions() {
        submitted.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.walkStampsKey)
    }

    // MARK: - Requests

    /// A prefetch request that never spends the user's metered data.
    ///
    /// The cellular flag is not only belt and braces: Nuke shares one
    /// download between requests with the same URL, cache policy and
    /// cellular flag, so without it an on-screen image could join a
    /// prefetch's download and fail with it on a network the prefetch
    /// refuses. Differing here keeps the two apart; the caches they fill
    /// are keyed by URL alone, so the result is still shared.
    nonisolated static func prefetchURLRequest(for url: URL) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.allowsExpensiveNetworkAccess = false
        urlRequest.allowsConstrainedNetworkAccess = false
        urlRequest.allowsCellularAccess = false
        return urlRequest
    }

    private static func prefetchRequest(for url: URL) -> ImageRequest {
        ImageRequest(urlRequest: prefetchURLRequest(for: url), priority: .veryLow)
    }

    /// Whether chat rows currently ask for animated variants
    /// (`ChatAppearance.animatedEmotes`, default on).
    private static func rowsAnimateEmotes() -> Bool {
        UserDefaults.standard.object(forKey: ChatAppearance.animatedEmotesKey) as? Bool ?? true
    }

    // MARK: - Network cost

    /// Process-wide path monitor; only `currentPath` is read. Main-actor
    /// state like the rest of the class.
    private static let pathMonitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        return monitor
    }()

    /// True on cellular / personal hotspot (expensive) or in Low Data Mode
    /// (constrained). Before the monitor's first update the path reports
    /// neither, and the per-request flags cover that window.
    private static var networkIsCostly: Bool {
        let path = pathMonitor.currentPath
        return path.isExpensive || path.isConstrained
    }

    // MARK: - Walk stamps

    /// How often the subscribed-emote walk may run for one account.
    nonisolated static let walkInterval: TimeInterval = 24 * 60 * 60

    /// `[account user id: time of the last complete walk]`, as seconds
    /// since 1970.
    private static let walkStampsKey = "chattr.prefetch.userEmoteWalks"

    nonisolated static func isWalkDue(lastWalk: Date?, now: Date) -> Bool {
        guard let lastWalk else { return true }
        let elapsed = now.timeIntervalSince(lastWalk)
        // A stamp from the future (the clock was set back) must not block
        // the walk indefinitely.
        return elapsed < 0 || elapsed >= walkInterval
    }

    private static func walkStamp(forAccount userId: String) -> Date? {
        let stamps = UserDefaults.standard.dictionary(forKey: walkStampsKey) as? [String: Double] ?? [:]
        return stamps[userId].map { Date(timeIntervalSince1970: $0) }
    }

    /// Sets (or with `nil`, clears) the account's stamp. Stamps past the
    /// interval mean the same as none, so they are dropped on the way —
    /// which also keeps removed accounts from accumulating.
    private static func setWalkStamp(_ date: Date?, forAccount userId: String) {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        var stamps = defaults.dictionary(forKey: walkStampsKey) as? [String: Double] ?? [:]
        stamps = stamps.filter { now - $0.value < walkInterval }
        stamps[userId] = date?.timeIntervalSince1970
        defaults.set(stamps, forKey: walkStampsKey)
    }
}

// MARK: - Environment plumbing

public extension EnvironmentValues {
    /// App-wide chat image prefetcher. Injected by `RootView`. Callers
    /// (`ChatScreen` for channel-badge prefetch on mount) read this and
    /// call the appropriate `prefetch...` method. Reading `nil` from
    /// previews / detached views is fine — the call site just skips.
    ///
    /// Default is nil because `ChatImagePrefetcher()` is `@MainActor`-isolated
    /// (the class is) and the entry's default value is evaluated in a
    /// nonisolated context. The Optional shape is the idiomatic SwiftUI
    /// workaround — same pattern used by `GlobalCatalog` and
    /// `ChannelSessionRegistry`.
    @Entry var chatImagePrefetcher: ChatImagePrefetcher? = nil
}
