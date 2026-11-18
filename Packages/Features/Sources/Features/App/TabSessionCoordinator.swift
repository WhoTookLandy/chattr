import Foundation
import Channels
import ChatModel
import Core
import os

private let logger = AppLogger.make("Features.TabSessionCoordinator")

/// Ties one signed-in shell's chat tabs to the session registry: wires
/// `ChatTabsModel`'s `onOpen` / `onClose` / `onDiscard` to the registry's
/// acquire / release refcounting, runs the per-channel mention watcher that
/// feeds the tab's unread mark and the Activity inbox, and sweeps the
/// account's leftover sessions when the shell goes away.
///
/// `AppShell` owns one and calls `start` as it appears and `stop` as it
/// disappears. The tab model's callbacks hold the coordinator strongly, so
/// the releases a teardown queues still find their watcher tokens after the
/// shell's own state is gone; the coordinator holds the tab model,
/// navigation and registry weakly, so that is not a cycle.
///
/// ## What `onOpen` does
///
///   A tab just appeared (user opened a channel OR cold-start
///   hydration restored a persisted tab). Bumps the refcount for
///   each of its channels and triggers session construction so
///   EventSub subscriptions start flowing immediately.
///
/// ## What `onClose` does
///
///   A tab just disappeared (user tapped the X). Drops the
///   refcount for each of its channels. The session keeps running
///   while other tabs still hold a reference; when the count hits
///   0 the session is stopped and the EventSub subscription is
///   released.
///
/// ## What `onDiscard` does
///
///   A tab disappeared before its `onOpen` ran, so it holds no
///   refcount — but its mounted ChatScreen may already have built
///   the session through `registry.session(...)`. Tears that
///   session down unless another tab holds it.
///
/// ## Sendable note
///
/// The callbacks reach only `Sendable` values: `Account` is a SwiftData
/// @Model (non-Sendable), so the coordinator takes `userId` / `login` as
/// Strings instead. Holding the Account would also retain it for the
/// session lifetime (no `weak` possible on `@Model`) and create undefined
/// behavior if multi-account/sign-out ever invalidates the SwiftData
/// context.
@MainActor
final class TabSessionCoordinator {

    /// Waits between retries of a tab's failed `acquire`.
    static let acquireRetryDelays: [Duration] = [.seconds(2), .seconds(6), .seconds(15)]

    /// The wait before each acquire retry. Injected so tests don't sleep.
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void

    /// The highlight keywords a newly installed watcher matches against.
    private let highlightKeywords: @MainActor () -> [String]

    private weak var registry: (any TabSessionRegistry)?
    private weak var chatTabs: ChatTabsModel?
    private weak var navigation: AppNavigation?
    private var accountUserId = ""
    private var accountLogin = ""

    /// Subscription tokens for the per-tab mention watchers installed in
    /// `onOpen`, keyed by tab id. One entry per channel per open tab: which
    /// subscription to remove from which session when the tab closes.
    private var watchTokens: [UUID: [(channelId: String, token: UUID)]] = [:]

    /// Background retries of a tab's failed acquires, by tab id. The tab's
    /// `onClose` cancels and awaits its entry before releasing.
    private var retries: [UUID: Task<Void, Never>] = [:]

    /// The account this shell wired itself for and its `ShellSessionOwners`
    /// token, for the teardown in `stop`.
    private var sessionScope: (accountUserId: String, owner: UUID)?

    init(
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        highlightKeywords: @escaping @MainActor () -> [String] = { HighlightSettings.keywords() }
    ) {
        self.sleep = sleep
        self.highlightKeywords = highlightKeywords
    }

    /// Test hook: how many mention watchers are installed for the tab.
    func watcherCount(forTab tabId: UUID) -> Int {
        watchTokens[tabId]?.count ?? 0
    }

    // MARK: - Start / stop

    /// Registers the shell as live for the account and wires the tab
    /// model's callbacks. Call before the tabs are hydrated, so each
    /// restored tab's `onOpen` acquires its sessions.
    func start(
        accountUserId: String,
        accountLogin: String,
        registry: (any TabSessionRegistry)?,
        navigation: AppNavigation
    ) {
        let chatTabs = navigation.chatTabs
        self.accountUserId = accountUserId
        self.accountLogin = accountLogin
        self.registry = registry
        self.chatTabs = chatTabs
        self.navigation = navigation

        // This shell is now live for the account (see
        // `ShellSessionOwners`). Recorded as Strings for `stop`, which runs
        // when the `Account` may already be deleted. A repeated `start`
        // re-wires, so its earlier token no longer stands for a live shell.
        let sessionOwner = UUID()
        if let previous = sessionScope {
            ShellSessionOwners.live[previous.accountUserId]?.remove(previous.owner)
        }
        ShellSessionOwners.live[accountUserId, default: []].insert(sessionOwner)
        sessionScope = (accountUserId: accountUserId, owner: sessionOwner)

        // `chatTabs` MUST stay weak on the coordinator: these closures are
        // stored on `chatTabs` itself and hold the coordinator, so a strong
        // reference back is a retain cycle — the old ChatTabsModel (plus its
        // tabs, TabPersistence, and this coordinator) would leak on every
        // account switch, since RootView's `.id(userId)` rebuilds AppShell
        // each time.
        chatTabs.onOpen = { [self] tab in await self.tabDidOpen(tab) }
        chatTabs.onClose = { [self] tab in await self.tabDidClose(tab) }
        chatTabs.onDiscard = { [self] tab in await self.tabWasDiscarded(tab) }
    }

    /// The shell went away (account switch / sign-out). `releases` is the
    /// task `ChatTabsModel.tearDown()` returned: every tab's own release.
    ///
    /// `releaseAll` then sweeps up whatever the tabs didn't own (a session
    /// a chat page built without its tab ever acquiring it). It runs
    /// only after the last tab release, so it finds exactly what is left
    /// over — not acquires those releases are still waiting on, nor one a
    /// multi-channel open has yet to make.
    ///
    /// Returns the task doing so (nil when the coordinator was never
    /// started or the registry is gone).
    @discardableResult
    func stop(after releases: Task<Void, Never>?) -> Task<Void, Never>? {
        guard let registry, let scope = sessionScope else { return nil }
        return Task {
            await releases?.value
            // Another shell is live for the account: it came back
            // (switched away and back, or this shell re-appeared) while
            // the releases ran, or a second window is showing it. The
            // sessions still in the registry are that shell's — its
            // tabs hold refcounts on them.
            guard ShellSessionOwners.retire(scope.owner, forAccountUserId: scope.accountUserId) else { return }
            await registry.releaseAll(forAccountUserId: scope.accountUserId)
        }
    }

    // MARK: - Tab callbacks

    private func tabDidOpen(_ tab: ChatTab) async {
        guard let registry else { return }
        var failed: [ChannelDescriptor] = []
        for channel in tab.channels {
            do {
                try await acquireAndWatch(channel, tabId: tab.id, registry: registry)
            } catch is CancellationError {
                // Expected if a release races acquire (rapid
                // open-then-close). Swallow silently.
            } catch {
                // The registry already rolled this acquire back, so
                // the tab holds nothing for the channel. Retried
                // below.
                logger.error("acquire failed for \(channel.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                failed.append(channel)
            }
        }
        guard !failed.isEmpty else { return }
        // Retry with backoff while the tab stays open — on a task of
        // its own, so a channel that can't start doesn't hold up the
        // restored tabs queued behind this one. `onClose` cancels
        // and awaits it before releasing, which keeps a late acquire
        // from landing after the tab's release.
        let unacquired = failed
        retries[tab.id] = Task { [self] in
            var remaining = unacquired
            for delay in TabSessionCoordinator.acquireRetryDelays {
                do {
                    try await self.sleep(delay)
                } catch {
                    return
                }
                guard let registry = self.registry,
                      self.chatTabs?.tabs.contains(where: { $0.id == tab.id }) == true
                else { return }
                var stillFailing: [ChannelDescriptor] = []
                for channel in remaining {
                    do {
                        try await self.acquireAndWatch(channel, tabId: tab.id, registry: registry)
                    } catch is CancellationError {
                        // The key was released under us; nothing to hold.
                    } catch {
                        stillFailing.append(channel)
                    }
                }
                remaining = stillFailing
                if remaining.isEmpty { return }
            }
            let unacquiredCount = remaining.count
            logger.error("acquire still failing for \(unacquiredCount) channel(s) of a tab; giving up until it is reopened")
        }
    }

    private func tabDidClose(_ tab: ChatTab) async {
        // Settle a pending acquire retry first: whatever it managed
        // to acquire is released below with the rest.
        if let retry = retries.removeValue(forKey: tab.id) {
            retry.cancel()
            await retry.value
        }
        guard let registry else { return }
        // Unsubscribe the mention watchers BEFORE releasing, while
        // the tab's own refcount still keeps the session alive.
        // `existingSession` never builds one: if the session is
        // already gone, so are its subscribers.
        for entry in watchTokens[tab.id] ?? [] {
            guard let session = registry.existingSession(
                accountUserId: accountUserId, channelId: entry.channelId
            ) else { continue }
            await session.unsubscribe(entry.token)
        }
        // A watcher is installed exactly when an acquire succeeded, so each
        // entry is one reference this tab holds: one release per entry. The
        // registry's count is shared per channel, so releasing a channel the
        // tab never acquired (or one more time than it did) would take
        // another tab's reference.
        let acquired = watchTokens.removeValue(forKey: tab.id) ?? []
        for entry in acquired {
            await registry.release(accountUserId: accountUserId, channelId: entry.channelId)
        }
        // A channel with no successful acquire may still have a session its
        // chat page built, which nothing else would end.
        let acquiredIds = Set(acquired.map { $0.channelId })
        var discarded: Set<String> = []
        for channel in tab.channels where !acquiredIds.contains(channel.channelId) {
            guard discarded.insert(channel.channelId).inserted else { continue }
            await registry.releaseUnowned(accountUserId: accountUserId, channelId: channel.channelId)
        }
    }

    private func tabWasDiscarded(_ tab: ChatTab) async {
        guard let registry else { return }
        for channel in tab.channels {
            await registry.releaseUnowned(accountUserId: accountUserId, channelId: channel.channelId)
        }
    }

    /// Acquires `channel`'s session for the tab (one refcount) and installs
    /// the tab's mention watcher on it. Throws what `registry.acquire`
    /// throws; the registry has rolled the refcount back by then.
    private func acquireAndWatch(
        _ channel: ChannelDescriptor,
        tabId: UUID,
        registry: any TabSessionRegistry
    ) async throws {
        // Locals, not `self`: the watcher below runs off the main actor.
        let accountUserId = self.accountUserId
        let accountLogin = self.accountLogin
        let chatTabs = self.chatTabs
        let navigation = self.navigation
        let session = try await registry.acquire(
            accountUserId: accountUserId,
            accountLogin: accountLogin,
            channelId: channel.channelId,
            channelLoginName: channel.channelLoginName
        )
        // Mention watcher: session-level (not ChatTranscriptModel)
        // so @-mentions land the red dot even for tabs whose
        // page isn't mounted. The handler is deliberately
        // tiny — a substring check per message — and runs on
        // its own task per drained batch, so it never holds
        // up the session or the transcript.
        //
        // It also feeds the Activity inbox: @-mentions, plus
        // highlight-keyword hits (keywords read at tab open,
        // like the transcript's own highlighting).
        let keywordMatcher = HighlightMatcher(keywords: highlightKeywords())
        let token = await session.subscribe(onBatch: {
            [weak chatTabs, weak navigation, channel, keywordMatcher] batch in
            var mentioned = false
            var hits: [ActivityStore.Entry] = []
            for update in batch {
                guard case .message(let normalized) = update,
                      !normalized.line.isHistorical,
                      normalized.message.chatterUserId != accountUserId
                else { continue }
                let text = normalized.message.message.text
                let isMention = ChatTabsModel.containsMention(of: accountLogin, in: text)
                guard isMention || keywordMatcher.matches(normalized.line.runs) else { continue }
                mentioned = mentioned || isMention
                let line = normalized.line
                hits.append(ActivityStore.Entry(
                    id: line.id,
                    channel: channel,
                    authorDisplayName: line.authorDisplayName,
                    authorColor: line.authorColor,
                    text: text,
                    timestamp: line.timestamp,
                    reason: isMention ? .mention : .keyword
                ))
            }
            if mentioned {
                await chatTabs?.markMention(tabId: tabId)
            }
            if !hits.isEmpty {
                await navigation?.recordActivity(hits, fromTab: tabId)
            }
        })
        watchTokens[tabId, default: []]
            .append((channelId: channel.channelId, token: token))
    }
}
