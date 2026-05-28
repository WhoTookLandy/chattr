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

    private let providers: [any EmoteProvider]

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
    public init() {
        self.providers = [SevenTVProvider(), BTTVProvider(), FFZProvider()]
    }

    /// Inject-providers initializer for tests.
    public init(providers: [any EmoteProvider]) {
        self.providers = providers
    }

    /// Loads global + per-channel emotes for the given (id, login) pair.
    /// Each provider is queried in parallel via `TaskGroup`; per-provider
    /// failures are logged and swallowed so a single dead provider doesn't
    /// fail the whole index.
    ///
    /// Call this once per session start (and on user-initiated refresh).
    /// Subsequent calls overwrite the previous snapshot atomically.
    public func load(broadcasterId: String, broadcasterLogin: String) async {
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

        // Atomic publish: actor-isolated mutation + lock-protected snapshot.
        //
        // `merged` is bound to a `let` here before being captured by the
        // `withLock` closure — Swift 6 strict-concurrency rejects capturing
        // a `var` in a Sendable closure even when the call site is
        // synchronous and the lock provides exclusion. The immutable
        // alias satisfies the compiler with no runtime cost.
        let finalSnapshot = merged
        self.byName = finalSnapshot
        snapshotLock.withLock { $0 = finalSnapshot }
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
