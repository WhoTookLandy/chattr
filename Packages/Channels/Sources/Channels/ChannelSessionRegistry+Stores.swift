import Foundation
import EmoteSources
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Channels.Registry")

extension ChannelSessionRegistry {

    // MARK: - Per-channel view stores (T11)

    /// Returns the shared `EmoteIndex` for this account × channel pair, creating
    /// it on first access. Survives `ChatScreen` unmount/remount as long as the
    /// registry's refcount for the channel stays > 0 — i.e. as long as any
    /// `ChatTab` is keeping the channel alive.
    ///
    /// Idempotency: returns the same instance for repeated calls with the same
    /// key. Callers can then call `load(...)` on it freely; `EmoteIndex.load`
    /// short-circuits when it's already loaded for the given broadcaster.
    ///
    /// Lifetime: cleaned up automatically in `release(...)` when refcount hits
    /// zero, alongside the underlying `ChannelSession`.
    public func emoteIndex(forAccountUserId accountUserId: String, channelId: String) -> EmoteIndex {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let existing = emoteIndexes[key] {
            return existing
        }
        // Globals come from the process-wide catalog so N channels × M
        // accounts fetch each provider's global set once, not N×M times.
        let new = EmoteIndex(providers: Self.enabledEmoteProviders(), globalCatalog: .shared)
        emoteIndexes[key] = new
        // Every table the index publishes (interim provider results, a
        // background revalidation) reaches the channel's session, not only
        // the one `loadEmotes` waits for.
        Task { [weak self, weak new] in
            await new?.setPublishObserver { [weak self, weak new] in
                Task { @MainActor [weak self, weak new] in
                    guard let self, let new else { return }
                    self.scheduleEmoteRefresh(key: key, index: new)
                }
            }
        }
        return new
    }

    /// Coalesces a burst of publishes into one `emoteTableDidChange()`: the
    /// refresh that runs reads whatever table is current by then.
    private func scheduleEmoteRefresh(key: SessionKey, index: EmoteIndex) {
        guard emoteRefreshes[key] == nil else { return }
        emoteRefreshes[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            self.emoteRefreshes[key] = nil
            // The key may have been released (and re-opened with a fresh
            // index) meanwhile.
            guard self.emoteIndexes[key] === index else { return }
            await self.router.session(for: key)?.emoteTableDidChange()
        }
    }

    /// Loads the channel's registry-owned `EmoteIndex` and, when that
    /// published a new table, has the channel's session re-normalize the
    /// rows it built against the old one and re-send them to its subscribers
    /// (`ChannelSession.emoteTableDidChange()`).
    ///
    /// The registry starts this itself when it creates a session, so a tab
    /// with no chat page mounted still resolves emotes. Safe to call again
    /// (a chat page appearing, a retry after a partial load):
    /// `EmoteIndex.load` shares an in-flight load and is a no-op once fully
    /// loaded.
    public func loadEmotes(accountUserId: String, channelId: String, channelLoginName: String) async {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        let index = emoteIndex(forAccountUserId: accountUserId, channelId: channelId)
        // `load` reports nothing (and returns at once when already loaded);
        // the generation moves exactly when a table was published.
        let generationBefore = index.generation
        await dependencies.loadEmoteIndex(index, channelId, channelLoginName)
        guard index.generation != generationBefore else { return }
        // The key may have been released (and re-opened with a fresh index)
        // while the providers answered.
        guard emoteIndexes[key] === index else { return }
        // The router also holds a session that is still starting; it
        // ignores this until its join backfill is committed.
        await router.session(for: key)?.emoteTableDidChange()
    }

    /// The third-party providers the user has enabled (Settings → Chat →
    /// Emotes). Read at index construction, so a toggle change applies
    /// the next time a channel's index is built (channel reopen) — same
    /// at-attach lifecycle as the chat filters and highlight keywords.
    private static func enabledEmoteProviders() -> [any EmoteProvider] {
        var providers: [any EmoteProvider] = []
        if EmoteSourceSettings.sevenTVEnabled() { providers.append(SevenTVProvider()) }
        if EmoteSourceSettings.bttvEnabled() { providers.append(BTTVProvider()) }
        if EmoteSourceSettings.ffzEnabled() { providers.append(FFZProvider()) }
        return providers
    }

    /// Returns the shared `ChatBadgeStore` for this account × channel pair,
    /// creating it on first access. Same lifetime semantics as `emoteIndex(...)`.
    ///
    /// `ChatBadgeStore.load(...)` is also idempotent — second-mount cost for the
    /// same channel is a no-op rather than two Helix calls.
    public func badgeStore(forAccountUserId accountUserId: String, channelId: String) -> ChatBadgeStore {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let existing = badgeStores[key] {
            return existing
        }
        let new = ChatBadgeStore()
        badgeStores[key] = new
        return new
    }

    /// Returns the shared `ChannelTwitchEmotesStore` for this account × channel
    /// pair, creating it on first access. Same lifetime and idempotency
    /// semantics as `badgeStore(...)`.
    public func channelTwitchEmoteStore(
        forAccountUserId accountUserId: String,
        channelId: String
    ) -> ChannelTwitchEmotesStore {
        let key = Self.key(accountUserId: accountUserId, channelId: channelId)
        if let existing = channelTwitchEmoteStores[key] {
            return existing
        }
        let new = ChannelTwitchEmotesStore()
        channelTwitchEmoteStores[key] = new
        return new
    }

    /// Returns (creating if needed) the per-account connection-state store. A
    /// `ChatScreen` observes this to drive its "Reconnecting… / Live again"
    /// pill. Same lifetime as the account's event dispatcher: kept while the
    /// account's client lives, dropped when its streams end.
    public func connectionStatus(forAccountUserId accountUserId: String) -> ConnectionStatusStore {
        if let existing = connectionStatusStores[accountUserId] {
            return existing
        }
        let new = ConnectionStatusStore()
        connectionStatusStores[accountUserId] = new
        return new
    }

    // MARK: - Moderated channels (mod-affordance pre-seed)

    /// Returns the set of channel ids the account moderates, fetched once
    /// per account from `GET /moderation/channels` and cached for the
    /// registry's lifetime. The endpoint is the user-side inverse of
    /// `/moderation/moderators`: it needs only the signed-in user's own
    /// token (`user:read:moderated_channels` scope), not broadcaster auth.
    ///
    /// `ChatTranscriptModel.attach` consults this (via the provider closure
    /// `ChatScreen` hands it) to show mod-only affordances the moment a
    /// channel opens, instead of waiting for the user's own message echo
    /// to carry a mod badge.
    ///
    /// Graceful degradation: any fetch error — most commonly unauthorized
    /// on accounts signed in before the scope was added — returns an empty
    /// set ("no pre-knowledge") and is NOT cached, so a later open retries.
    /// The badge-observation upgrade path in `ChatTranscriptModel` still works, so
    /// mod tools appear after the first sent message exactly as they did
    /// before this fetch existed.
    public func moderatedChannelIds(forAccountUserId accountUserId: String) async -> Set<String> {
        // Joiner path — a fetch is cached or in flight; share its result.
        // Joiners never evict: only the creator below manages the entry,
        // which keeps eviction from racing a fresh task another caller
        // stored after this one suspended.
        if let existing = moderatedChannelsTasks[accountUserId] {
            return await existing.value ?? []
        }

        let client = dependencies.client(accountUserId)
        let task = Task<Set<String>?, Never> {
            do {
                var ids: Set<String> = []
                var cursor: String? = nil
                repeat {
                    let page = try await client.api.fetchModeratedChannelsPage(
                        userID: accountUserId,
                        first: 100,
                        after: cursor
                    )
                    ids.formUnion(page.data.map(\.broadcasterId))
                    cursor = page.pagination?.cursor
                } while cursor != nil
                return ids
            } catch {
                // .info (not .error): expected for every pre-scope account
                // until they re-sign-in — noisy as an error, but worth a
                // visible breadcrumb when investigating "why no Delete
                // Message" reports.
                logger.info("Moderated-channels fetch failed for account \(accountUserId, privacy: .public): \(error.localizedDescription, privacy: .public) — falling back to badge observation")
                return nil
            }
        }
        moderatedChannelsTasks[accountUserId] = task

        guard let ids = await task.value else {
            // Creator-only eviction (see joiner comment above).
            moderatedChannelsTasks[accountUserId] = nil
            return []
        }
        logger.info("Moderated-channels set for account \(accountUserId, privacy: .public): \(ids.count) channel(s)")
        return ids
    }

    /// Drops the account's cached moderated-channel set so the next
    /// channel-open refetches it. Called (via `ChatTranscriptModel`'s
    /// `onModerationRevoked` hook) when a live `channel.moderate` event
    /// reports the account was unmodded — the cached set still names the
    /// channel, and without eviction a close-and-reopen would re-seed mod
    /// affordances from that stale entry for the rest of the app run.
    ///
    /// Whole-account eviction rather than surgical removal on purpose:
    /// the refetch is one Helix call, authoritative, and shared by all
    /// channels — cheaper to re-ask than to mirror per-channel mutations
    /// into a cached Task's resolved value.
    public func invalidateModeratedChannels(forAccountUserId accountUserId: String) {
        moderatedChannelsTasks[accountUserId] = nil
        logger.debug("Evicted moderated-channels cache for account \(accountUserId, privacy: .public)")
    }
}
