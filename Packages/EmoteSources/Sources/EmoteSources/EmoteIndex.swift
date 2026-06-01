import Foundation
import Core
import os

private let logger = AppLogger.make("EmoteSources.Index")

/// Per-channel emote resolver. Owns the merged result of:
///   - 7TV global + channel
///   - BTTV global + channel
///   - FFZ global + channel
///
/// ## Resolution semantics
///
/// On name collision (same `name` from multiple providers/scopes), the
/// precedence is:
///
///   1. **Channel emotes > global emotes** — broadcasters configure
///      channel-specific emotes intentionally, so they should always
///      win against a global of the same name.
///   2. **Within the same scope**: 7TV > BTTV > FFZ. This matches
///      community convention (7TV has the deepest catalog and is most
///      likely to be the user's expected source for a given name).
///
/// ## Isolation
///
/// `actor` — the merged map is mutated during async refresh and must be
/// protected from concurrent writes. Reads happen on the hot chat
/// message path (every incoming message tokenizes against the index),
/// so the `snapshot` property below mirrors `byName` for cross-actor
/// access without an `await` on every lookup.
///
/// ## Per-provider failure handling
///
/// `withTaskGroup` runs all three providers in parallel for both global
/// and channel loads. Per-provider failures are logged and swallowed —
/// 7TV could be down and we still want to render BTTV+FFZ emotes for
/// the user. The index emits what it could load, even if partial.
public actor EmoteIndex {

    /// Resolved emotes keyed by `name`. Slice-2 uses exact-case match —
    /// Twitch native emotes are case-sensitive ("Kappa" ≠ "kappa") and
    /// all three providers follow the same convention.
    private var byName: [String: Emote] = [:]

    /// Idempotency key: the `broadcasterId` we most recently loaded for.
    /// If `load(...)` is called again with the same id, it's a no-op.
    /// This is what makes the index registry-friendly — multiple view
    /// mounts of the same channel call `load(...)` but the network work
    /// happens once.
    private var loadedBroadcasterId: String?

    private let providers: [any EmoteProvider]

    /// Disk cache for this channel's merged snapshot. Keyed by broadcasterId.
    private let cache: JSONDiskCache

    /// Cross-launch freshness window. In-session refetch is already prevented
    /// by `loadedBroadcasterId`; this TTL governs only disk-restored data.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60

    /// Lock-protected mirror of `byName` for nonisolated reads. Renderer
    /// code (e.g. a future `Normalizer` in Phase 2.2) reads this on the
    /// hot path and shouldn't have to cross the actor boundary for each
    /// emote lookup.
    ///
    /// Why `OSAllocatedUnfairLock` (not `nonisolated(unsafe)`): Swift 6
    /// strict-concurrency rejects `nonisolated(unsafe)` mutable
    /// dictionaries even though dictionary copy-on-write makes the read
    /// safe in practice. The lock costs us a single atomic op per
    /// lookup but keeps the compiler happy and the semantics
    /// provably-correct.
    public let snapshotLock = OSAllocatedUnfairLock<[String: Emote]>(initialState: [:])

    /// Snapshot accessor for consumers (e.g., Normalizer in Phase 2.2).
    /// Read-only by design — only `EmoteIndex.load(...)` writes back.
    public nonisolated func snapshot() -> [String: Emote] {
        snapshotLock.withLock { $0 }
    }

    /// Default initializer: stands up all three providers with a shared
    /// URLSession. Tests can inject custom providers (e.g., to test
    /// failure handling without hitting the network) via the second init.
    public init(cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)) {
        self.providers = [SevenTVProvider(), BTTVProvider(), FFZProvider()]
        self.cache = cache
    }

    /// Inject-providers (and cache) initializer for tests.
    public init(
        providers: [any EmoteProvider],
        cache: JSONDiskCache = JSONDiskCache(subdirectory: CacheSubdirectory.emoteChannels)
    ) {
        self.providers = providers
        self.cache = cache
    }

    /// Loads global + per-channel emotes for the given (id, login) pair.
    /// Each provider is queried in parallel via `TaskGroup`; per-provider
    /// failures are logged and swallowed so a single dead provider doesn't
    /// fail the whole index.
    ///
    /// **Idempotent**: calling with the same `broadcasterId` we already
    /// loaded for is a no-op. This is the key property that makes the
    /// registry-owned pattern work — multiple ChatScreen mounts for the
    /// same channel each call `load(...)` but the network round-trip
    /// happens once.
    ///
    /// Call `forceReload(...)` if you need a refresh.
    public func load(broadcasterId: String, broadcasterLogin: String) async {
        if loadedBroadcasterId == broadcasterId {
            // Already loaded for this channel — re-mounts get the existing
            // snapshot for free. Skip the 6 HTTP calls.
            return
        }

        // Disk: restore + render instantly if present. If still fresh, skip the
        // network entirely. If stale, fall through and revalidate below.
        if let hit = await cache.load(
            key: broadcasterId, as: ChannelEmoteCachePayload.self,
            version: ChannelEmoteCachePayload.cacheVersion, ttl: Self.cacheTTL
        ), hit.payload.broadcasterId == broadcasterId {
            let restored = hit.payload.byName
            self.byName = restored
            snapshotLock.withLock { $0 = restored }
            if hit.isFresh {
                loadedBroadcasterId = broadcasterId
                logger.info("EmoteIndex restored fresh from disk for \(broadcasterLogin): \(restored.count) emote(s)")
                return
            }
        }

        var merged: [String: Emote] = [:]

        // Step 1: global emotes from all providers, in parallel.
        await withTaskGroup(of: [Emote].self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return try await provider.globalEmotes()
                    } catch {
                        logger.error("Global emotes failed for \(String(describing: type(of: provider))): \(error.localizedDescription)")
                        return []
                    }
                }
            }
            for await emotes in group {
                for emote in emotes {
                    Self.merge(into: &merged, emote: emote, isChannelLevel: false)
                }
            }
        }

        // Step 2: channel emotes from all providers, also in parallel.
        // These override globals on name collision (channel > global).
        await withTaskGroup(of: [Emote].self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return try await provider.channelEmotes(broadcasterId: broadcasterId, broadcasterLogin: broadcasterLogin)
                    } catch {
                        logger.error("Channel emotes failed for \(String(describing: type(of: provider))) (\(broadcasterLogin)): \(error.localizedDescription)")
                        return []
                    }
                }
            }
            for await emotes in group {
                for emote in emotes {
                    Self.merge(into: &merged, emote: emote, isChannelLevel: true)
                }
            }
        }

        // If the parent Task was cancelled mid-flight, every provider call
        // returned `[]` (each provider's catch swallowed the CancellationError
        // — see `withTaskGroup` blocks above). Publishing here would do two
        // wrong things at once:
        //
        //   1. Set `byName` and the snapshot to empty, wiping any prior load
        //      (would only happen if a freshly-mounted index raced its own
        //      cancellation — defensive, but cheap to guard against).
        //   2. Set `loadedBroadcasterId = broadcasterId`, which would cause
        //      the next caller's idempotency check to return early *as if*
        //      we successfully loaded zero emotes — breaking emote rendering
        //      until the channel is closed and reopened.
        //
        // Bail without publishing. The next caller (typically a fresh
        // `.task` from a remounted ChatScreen) sees `loadedBroadcasterId`
        // still nil and retries the load cleanly.
        guard !Task.isCancelled else {
            logger.info("EmoteIndex load cancelled for \(broadcasterLogin); not publishing partial snapshot")
            return
        }

        // Atomic publish: actor-isolated mutation + lock-protected snapshot.
        //
        // `merged` is bound to a `let` here before being captured by the
        // `withLock` closure — Swift 6 strict-concurrency rejects capturing
        // a `var` in a Sendable closure even when the call site is
        // synchronous and the lock provides exclusion. The immutable
        // alias satisfies the compiler with no runtime cost.
        let finalSnapshot = merged
        // All providers failed or returned nothing. Don't clobber a
        // disk-restored snapshot (or a prior load) with emptiness, and don't
        // mark loaded — let the next mount retry.
        guard !finalSnapshot.isEmpty else {
            logger.info("EmoteIndex produced no emotes for \(broadcasterLogin); keeping existing snapshot")
            return
        }
        self.byName = finalSnapshot
        snapshotLock.withLock { $0 = finalSnapshot }

        await cache.save(
            key: broadcasterId,
            value: ChannelEmoteCachePayload(broadcasterId: broadcasterId, byName: finalSnapshot),
            version: ChannelEmoteCachePayload.cacheVersion)

        // Mark as loaded for idempotency. Future load() calls with the same
        // broadcasterId return immediately. Set AFTER the snapshot publish so
        // a Task cancellation mid-load (rare) leaves the index in an unloaded
        // state and the next attempt will retry.
        loadedBroadcasterId = broadcasterId
        logger.info("EmoteIndex loaded for \(broadcasterLogin): \(finalSnapshot.count) emote(s)")
    }

    /// O(1) lookup. Returns nil if the name isn't a known emote.
    /// Prefer the nonisolated `snapshot()` for high-frequency renderer
    /// lookups (avoids actor-hop cost per message token).
    public func resolve(name: String) -> Emote? {
        byName[name]
    }

    // MARK: - Private

    /// Merge with precedence: channel > global; 7TV > BTTV > FFZ.
    private static func merge(
        into map: inout [String: Emote],
        emote: Emote,
        isChannelLevel: Bool
    ) {
        if let existing = map[emote.name] {
            let existingIsChannel = existing.ownerChannelId != nil

            // Scope precedence wins first.
            if !existingIsChannel && isChannelLevel {
                map[emote.name] = emote
                return
            }
            if existingIsChannel && !isChannelLevel {
                return  // Keep existing — channel beats global.
            }

            // Same scope — apply source precedence (7TV > BTTV > FFZ).
            if priority(of: emote.source) < priority(of: existing.source) {
                map[emote.name] = emote
            }
        } else {
            map[emote.name] = emote
        }
    }

    private static func priority(of source: Emote.Source) -> Int {
        switch source {
        case .sevenTV: return 0
        case .bttv:    return 1
        case .ffz:     return 2
        }
    }
}
