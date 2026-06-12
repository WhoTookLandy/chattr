import SwiftUI
import Accounts
import Channels
import ChatModel
import DesignSystem
import EmoteSources
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.ChatScreen")
private let signposter = AppLogger.signposter("Features.ChatScreen")

/// Renders live `channel.chat.message` events from EventSub as inline-emote rows.
///
/// Slice-2 interlude scope: Twitch native emote fragments render as CDN images.
/// Third-party emote providers (7TV/BTTV/FFZ) and animated WebP arrive in later slices.
public struct ChatScreen: View {
    private let account: Account
    private let accountStore: AccountStore
    private let channelId: String
    private let channelLoginName: String
    private let channelDisplayName: String

    /// Per-tab chat state — owns the rendered `lines` and the session
    /// subscriptions. Replaces the previous `@State session` + `@State lines`
    /// pair plus the `for-await session.lines` loop. New messages arrive via
    /// the model's pub-sub subscriber callback, which appends to `lines` on
    /// MainActor (the model is `@MainActor @Observable`).
    @State private var chatModel = TabChatModel()

    @State private var errorMessage: String?

    /// The persisted compose draft for this channel, read from `DraftStorage`
    /// exactly once at construction (see `init`). `ComposeBar` only consumes
    /// `seedDraft` at first mount thanks to its own `@State(initialValue:)`
    /// semantics, so re-reading it on every `body` evaluation — as the old
    /// `composeBarView` did — was pure waste on the per-message hot path
    /// (`body` re-evaluates on each new chat line). Seeding it here moves the
    /// UserDefaults read to struct construction (parent rebuilds), off the
    /// per-message path, while preserving exact first-mount behavior.
    @State private var draftSeed: String

    // T11: badgeStore and emoteIndex are NOT `@State` here anymore — they
    // live on `ChannelSessionRegistry`, keyed by (accountUserId, channelId).
    // The registry's lifetime matches the channel tab's lifetime (refcount
    // > 0), so these stores survive ChatScreen unmount/remount within the
    // paged LazyHStack.
    //
    // Before T11: each ChatScreen unmount destroyed `@State badgeStore` and
    // `@State emoteIndex`, forcing 6 emote provider HTTPS calls + 2 Helix
    // badge calls every time the user swiped back to a tab they'd already
    // visited. Now: re-mount reads the same store from the registry, and
    // `load(...)` short-circuits via idempotency.
    //
    // The `emoteLoadTask` cancellation dance also goes away — `.task`
    // cancellation is now safe because the load itself bails on
    // `Task.isCancelled` before publishing (see EmoteIndex.load and
    // ChatBadgeStore.load), so cancelled loads leave the store in an
    // unloaded state and the next mount retries cleanly.

    /// Convenience: pull the registry-owned badge store for this channel.
    /// Returns nil only if the registry isn't in the environment (programming
    /// error — RootView injects it at app start). The body's badge-renderer
    /// call site falls back to `[]` in that pathological case.
    private var badgeStore: ChatBadgeStore? {
        channelSessionRegistry?.badgeStore(
            forAccountUserId: account.userId,
            channelId: channelId
        )
    }

    /// Convenience: pull the registry-owned emote index for this channel.
    /// Same nil semantics as `badgeStore` above.
    private var emoteIndex: EmoteIndex? {
        channelSessionRegistry?.emoteIndex(
            forAccountUserId: account.userId,
            channelId: channelId
        )
    }

    /// Convenience: pull the registry-owned per-account connection-state store.
    /// Same nil semantics as `badgeStore` / `emoteIndex` above. Observed to
    /// drive the "Reconnecting… / Live again" pill.
    private var connectionStatus: ConnectionStatusStore? {
        channelSessionRegistry?.connectionStatus(forAccountUserId: account.userId)
    }

    // NOTE: scroll-position state (`scrolledMessageId`, `isAtBottom`,
    // `unreadWhileScrolledUp`, `scrollToBottomToken`) and the connection-
    // banner state live inside the extracted `ChatTranscript` view below —
    // NOT here on ChatScreen. Same observation-scoping rationale as the
    // compose-bar state note further down: those values change at scroll /
    // message rate, and keeping them out of ChatScreen keeps this body off
    // the per-message hot path.

    /// Brief "Reported & blocked" confirmation; auto-clears after ~2s.
    /// Stays on ChatScreen (not ChatTranscript) because it's WRITTEN by the
    /// report closures built in `chatRow(for:)` here; the transcript reads
    /// it through a binding for the pill overlay.
    @State private var showReportConfirmation = false
    @State private var reportConfirmationDismiss: Task<Void, Never>?

    /// Non-nil when the thread sheet is open; carries the thread's root
    /// message ID. `.sheet(item:)` could use `Identifiable`, but the
    /// String here is identifiable already (each root id is unique) so
    /// we wrap it minimally for the API.
    @State private var viewingThreadRootId: ThreadRootID?

    /// True while the in-chat settings sheet (chat modes + preferences)
    /// is presented. Opened from the compose bar's gear button.
    @State private var showChatSettings = false

    /// When true, the user has Reduce Motion on in system Accessibility — we
    /// skip the easeOut tween on auto-scroll so chat snaps instantly to the
    /// newest message instead of animating.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // NOTE: compose-bar state (`composeText`, `isSending`, `composeFocused`)
    // lives inside the extracted `ComposeBar` view below — NOT here on
    // ChatScreen. That isolation matters: every keystroke in the
    // TextField mutates the draft, and if the @State lived on ChatScreen
    // each keystroke would re-evaluate the whole body (which contains
    // the LazyVStack of chat rows). Pulling the state into a child View
    // confines re-evaluation to the compose bar itself, eliminating a
    // visible source of typing lag.

    /// Pre-cached global Twitch data (loaded once at app launch by RootView).
    /// We pass its global-badges slice into `badgeStore.load(...)` so the
    /// per-channel load skips the redundant /chat/badges/global fetch.
    @Environment(\.globalCatalog) private var globalCatalog

    /// Block list for the signed-in account. Pushed into `chatModel.blockedIds`
    /// reactively so the list re-filters whenever the user blocks/unblocks someone.
    @Environment(\.blockStore) private var blockStore

    /// App-wide session registry — `ChatScreen` *must* go through this to
    /// fetch a session rather than constructing one directly. The registry
    /// caches sessions by (userId, channelId), so re-entering a channel
    /// returns the existing already-subscribed session instead of trying to
    /// re-subscribe (Twitch rejects re-subscribe with "already subscribed").
    @Environment(\.channelSessionRegistry) private var channelSessionRegistry

    /// App-wide image prefetcher — `ChatScreen` uses it to warm Nuke's
    /// disk cache for this channel's badge URLs once `ChatBadgeStore.load`
    /// completes. Optional because the environment value is Optional;
    /// nil during previews / detached views just skips the prefetch.
    @Environment(\.chatImagePrefetcher) private var chatImagePrefetcher

    public init(
        account: Account,
        accountStore: AccountStore,
        channelId: String,
        channelLoginName: String,
        channelDisplayName: String
    ) {
        self.account = account
        self.accountStore = accountStore
        self.channelId = channelId
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        // Read the persisted draft once, here at construction. `State(initial-
        // Value:)` is the correct home for a value that only matters at first
        // mount — a `.task`-based seed would arrive AFTER `ComposeBar` has
        // already captured its initial draft, silently breaking restoration.
        self._draftSeed = State(initialValue: DraftStorage.load(forChannelId: channelId))
    }

    public var body: some View {
        // `@Bindable` projection of the @Observable model — gives us
        // `$bindableChatModel.isShowingSendError` for the .alert binding
        // without writing a `Binding(get:set:)` inline (Swift 5.9+ allows
        // declaring @Bindable inside body for view-scoped projections).
        @Bindable var bindableChatModel = chatModel
        // `.safeAreaBar(edge: .bottom)` pins the compose bar below the
        // scrolling content with integrated glass blur (iOS 26). The bar
        // lives INSIDE ChatScreen (not in ChatTabsScreen) because each
        // tab has its own draft — sharing one bar across tabs would lose
        // drafts on swipe.
        Group {
            if let errorMessage {
                errorView(errorMessage)
            } else {
                // The transcript (empty state + message list + pills) is a
                // separate child view for OBSERVATION SCOPING: it is the only
                // body that reads `chatModel.lines`, so per-message buffer
                // mutations re-evaluate just that subtree. Before this split,
                // the `lines.isEmpty` read right here subscribed ALL of
                // ChatScreen.body to the buffer — the whole screen (compose
                // bar closures, sheets, alert wiring) re-ran for every
                // inbound message, 50–200×/sec during raids.
                //
                // Passing `chatModel` itself registers NO dependency — only
                // property reads do. `rowContent` closes over ChatScreen's
                // row callbacks (retry/reply/block/report) so the transcript
                // stays ignorant of them; the closures run from the cell
                // provider, outside any body, exactly as before.
                ChatTranscript(
                    chatModel: chatModel,
                    channelLoginName: channelLoginName,
                    connectionStatus: connectionStatus,
                    rowContent: { line in chatRow(for: line) },
                    showReportConfirmation: $showReportConfirmation
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Chat surface color — slightly lifted off pure black/white in
        // both schemes (see DesignSystem.Color.chatSurface). Applied here
        // (not on the list) so the empty/connecting states and the area
        // behind the glass compose bar share the same surface.
        .background(Color.chatSurface.ignoresSafeArea())
        .safeAreaBar(edge: .bottom) {
            composeBarView
        }
        // Send-failure alert is gone — drops and network errors now
        // surface inline on the failed row itself (red exclamation +
        // tap-to-retry; see ChatRow's failed-state treatment).
        //
        // We keep `chatModel.sendError` for the one remaining case
        // where there's no row to attach the error to: the user tries
        // to send but there's no attached session (rare — usually means
        // the channel session failed to construct). For that we still
        // show the alert.
        //
        // Audit fix (axiom HIGH 1): previously this used
        // `Binding(get:set:)` inline, which reallocates the binding's
        // closure pair on every body re-eval (every chat message
        // arriving). Now we go through `@Bindable` + the model's
        // `isShowingSendError` computed property — the binding comes
        // from the projected `$` value, no per-body allocation.
        .alert(
            "Couldn't send",
            isPresented: $bindableChatModel.isShowingSendError,
            presenting: chatModel.sendError
        ) { _ in
            Button("OK", role: .cancel) { chatModel.clearSendError() }
        } message: { reason in
            Text(reason)
        }
        // Thread sheet — driven by the @State viewingThreadRootId
        // wrapper. `.sheet(item:)` ties presentation to a non-nil value
        // AND passes the unwrapped value into the content closure
        // automatically.
        .sheet(item: $viewingThreadRootId) { root in
            ThreadView(
                rootMessageId: root.id,
                chatModel: chatModel,
                badgeStore: badgeStore,
                channelLoginName: channelLoginName,
                channelDisplayName: channelDisplayName
            )
            // Half sheet by default — a thread is usually 2-5 messages,
            // and keeping live chat visible behind it preserves context.
            // Drag the grabber (or swipe up on the content) to expand to
            // full height for long threads.
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // In-chat settings: chat modes (mod-gated) + viewer preferences.
        // Half sheet like Twitch's native Chat Settings; expandable for
        // the appearance sub-screen.
        .sheet(isPresented: $showChatSettings) {
            ChatSettingsSheet(
                chatModel: chatModel,
                channelLoginName: channelLoginName,
                currentUserLogin: account.login
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // No `.navigationTitle` here — the parent ChatTabsScreen sets it to
        // "Chat" and the active tab pill in the strip already identifies the
        // channel. Having ChatScreen also override the title to "#login"
        // would just duplicate the information already shown one row below.
        //
        // Three structured tasks, all bound to view lifetime. SwiftUI cancels
        // them on tear-down (incl. when ChatTabsScreen swaps the active
        // channel via `.id(...)`). T11 made this safe — see notes above the
        // `badgeStore` / `emoteIndex` computed properties.
        //
        // Splitting the three loads across separate `.task` modifiers means
        // session-connect, badge-fetch, and emote-fetch all run concurrently.
        // None of them block the others.
        //
        // The session-lifecycle .task uses `.task(id: channelId)` instead of
        // bare `.task`:
        //   - Runs startSession on first mount (and on channelId change,
        //     though channelId is stable per ChatScreen instance).
        //   - Body sleeps indefinitely after startSession completes, holding
        //     the task alive until SwiftUI cancels it.
        //   - Cancellation comes from view tear-down (paged ScrollView
        //     unmounts off-screen ChatScreens during swipes) OR an id change.
        //   - On cancellation, the `try?` swallows the CancellationError and
        //     `await chatModel.detach()` runs synchronously in the task's
        //     final breath — structurally bound to view lifetime instead of
        //     fired-and-forgotten from `.onDisappear`.
        //
        // The audit (CR HIGH 5) flagged the previous `.onDisappear { Task {
        // await detach() } }` pattern as racing rapid A→B→A swipes: the
        // unstructured Task could run AFTER the next ChatScreen's attach,
        // leaving a brief window of ghost subscribers on the registry-owned
        // session. The structured pattern eliminates the race because
        // SwiftUI's task cancellation completes before the next view's
        // `.task` body starts.
        .task(id: channelId) {
            await startSession()
            // Hold the task open until SwiftUI cancels us (view torn down
            // or channelId changes). Sleeping for a year is the canonical
            // SwiftUI idiom — Task.sleep is implemented as a scheduler
            // primitive, not a busy-loop, so the cost is zero CPU.
            try? await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
            // Cancellation reaches here via CancellationError from sleep.
            // detach awaits the model's pub-sub teardown (unsubscribe from
            // the registry-owned session, cancel any sendFallbackTimers).
            // The chatModel reference survives because @State storage
            // persists until the task fully exits.
            await chatModel.detach()
        }
        .task {
            guard let store = badgeStore else { return }
            let cachedGlobalBadges = globalCatalog?.globalBadges ?? [:]
            await store.load(
                account: account,
                accountStore: accountStore,
                channelId: channelId,
                globalBadges: cachedGlobalBadges
            )
            // After the badge store finishes loading, warm Nuke's
            // disk cache for THIS channel's badge URLs. The merged
            // dict includes global + channel-specific entries; we
            // hand them all over and let Nuke's cache short-circuit
            // any already-memory-cached globals.
            //
            // This means by the time a user with a tier-2 sub badge
            // chats in this channel, the badge image is already on
            // disk — first display decodes from disk (~5ms) instead
            // of fetching from CDN (~150-500ms).
            chatImagePrefetcher?.prefetchChannelBadges(store.entries)
        }
        // Load 7TV / BTTV / FFZ emote definitions for this channel.
        //
        // ## Why `.task` is finally safe (T11)
        //
        // Pre-T11 history: `.task` was the obvious primitive but it cancelled
        // mid-flight during transient SwiftUI identity flickers (e.g. when
        // openChannel ran `chatTabsModel.open` — and, in an earlier design,
        // `selectedTab = .chat` — back-to-back, the paged-ScrollView LazyHStack
        // briefly re-evaluated children and ChatScreen's task identity dropped).
        // All 6 emote provider HTTP
        // calls threw `URLError(.cancelled)` and the EmoteIndex was left
        // populated with 0 emotes. We worked around it by using `.onAppear`
        // + an unstructured Task — escaping view lifetime — but that leaked
        // tasks past tear-down and required manual cancellation bookkeeping.
        //
        // T11 makes `.task` safe by changing what cancellation MEANS for the
        // emote load:
        //   - EmoteIndex is registry-owned, not view-state-owned. Its
        //     lifetime survives view churn for as long as the channel tab
        //     stays open.
        //   - `EmoteIndex.load(...)` checks `Task.isCancelled` BEFORE
        //     publishing. A cancelled load leaves `loadedBroadcasterId`
        //     unset, so the next-mount's `.task` retries cleanly.
        //   - `.task` cancellation under view churn no longer corrupts
        //     anything — at worst we burn an HTTP round-trip and retry on
        //     the next mount.
        //
        // Result: structured concurrency is preserved (no orphan tasks
        // outliving the view) AND the data layer is robust under remount.
        .task {
            guard let index = emoteIndex else { return }
            let id = signposter.makeSignpostID()
            let state = signposter.beginInterval(
                "emote-load",
                id: id,
                "channel=\(channelLoginName)"
            )
            await index.load(
                broadcasterId: channelId,
                broadcasterLogin: channelLoginName
            )
            let count = index.snapshot().count
            signposter.endInterval("emote-load", state, "count=\(count)")
            logger.info("EmoteIndex loaded for #\(channelLoginName, privacy: .public): \(count) emotes")
        }
        // Detach is now handled inside the .task(id: channelId) above —
        // structurally bound to view lifetime via CancellationError, no
        // unstructured Task needed. See the doc-comment on that .task
        // for why.
    }

    /// The compose bar, extracted so we can resolve `@Environment`-derived
    /// values (`emoteIndex`, `globalCatalog`) DURING body evaluation and
    /// capture the concrete results into the emote-section provider closure.
    ///
    /// ## Why this matters
    ///
    /// `@Environment` values are only reliably resolved during `body`. If
    /// the provider closure captured `self` and read `self.globalCatalog` /
    /// `self.emoteIndex` (both `@Environment`-derived) when the closure runs
    /// LATER — on the emote-button tap — they return their DEFAULT (nil),
    /// producing an empty picker.
    ///
    /// Resolving them here, into local `let`s, captures the concrete
    /// `EmoteIndex` actor instance + the Twitch-globals dict. The closure
    /// reads those instead of `@Environment`, so it works whenever it runs.
    /// The dict snapshot is current because `body` re-evaluates when
    /// `globalCatalog` (`@Observable`) changes, recreating the closure.
    @ViewBuilder
    private var composeBarView: some View {
        let resolvedEmoteIndex = emoteIndex
        let resolvedTwitchGlobals = globalCatalog?.globalEmotes ?? [:]
        ComposeBar(
            channelLoginName: channelLoginName,
            channelDisplayName: channelDisplayName,
            replyContext: chatModel.replyContext,
            chatRestrictions: chatModel.chatRestrictions,
            // Seeded once at construction (see `draftSeed` / `init`), not
            // re-read here — the seed only matters at first mount thanks to
            // ComposeBar's own @State semantics, so reading it on every body
            // pass was wasted UserDefaults work on the per-message hot path.
            seedDraft: draftSeed,
            onCancelReply: { chatModel.cancelReply() },
            onDraftChange: { newDraft in
                DraftStorage.save(forChannelId: channelId, text: newDraft)
            },
            // Captures the concrete EmoteIndex instance + globals dict
            // (resolved above), NOT @Environment — so it returns real
            // emotes when invoked on the button tap. Built on demand
            // (the snapshot read + section build runs only when tapped).
            emoteSectionsProvider: {
                EmoteCatalog.buildSections(
                    thirdParty: resolvedEmoteIndex?.snapshot() ?? [:],
                    twitchGlobal: resolvedTwitchGlobals
                )
            },
            onOpenSettings: { showChatSettings = true },
            onSend: { draft in await chatModel.send(text: draft) }
        )
    }

    // MARK: - Subviews

    /// Shown when an error has been recorded (couldn't open chat, etc.). Red
    /// text on the main content area — same visual treatment as before, just
    /// pulled into its own builder.
    @ViewBuilder
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Builds the row for one line — same badge lookup + callbacks the
    /// `ForEach` used, lifted into a helper so both the collection-view cell
    /// provider and the legacy `LazyVStack` can call it.
    private func chatRow(for line: ChatLine) -> ChatRow {
        ChatRow(
            line: line,
            badgeEntries: badgeStore?.entries(for: line.originalBadges) ?? [],
            onRetry: { Task { await chatModel.retry(failedLineId: line.id) } },
            onReply: { chatModel.beginReply(to: line) },
            onViewThread: {
                viewingThreadRootId = ThreadRootID(id: TabChatModel.threadRoot(of: line))
            },
            onDelete: (chatModel.currentUserCanModerate
                       && line.authorUserId != account.userId)
                ? { Task { await chatModel.deleteMessage(line.id) } }
                : nil,
            onBlock: line.authorUserId == account.userId ? nil : {
                Task {
                    await blockStore?.block(
                        userId: line.authorUserId,
                        login: line.authorDisplayName,
                        displayName: line.authorDisplayName,
                        reason: .other
                    )
                }
            },
            onReport: line.authorUserId == account.userId ? nil : { reason in
                Task {
                    await blockStore?.block(
                        userId: line.authorUserId,
                        login: line.authorDisplayName,
                        displayName: line.authorDisplayName,
                        reason: reason
                    )
                    showReportConfirmation = true
                    reportConfirmationDismiss?.cancel()
                    reportConfirmationDismiss = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                        showReportConfirmation = false
                    }
                }
            }
        )
    }

    // MARK: - Session lifecycle

    @MainActor
    private func startSession() async {
        // Badge load runs in a sibling .task modifier (see body) — gives us
        // structured-cancellation parity with this session-start task.
        guard let registry = channelSessionRegistry else {
            errorMessage = "Couldn't open chat: missing session registry"
            logger.error("ChatScreen has no registry in environment — was RootView injected?")
            return
        }

        // Signpost-bracket the session-start so Instruments can show the
        // overlap with the emote-load interval. Useful for diagnosing
        // races like the cancellation-during-channel-open bug we hit
        // (Instruments would show emote-load truncated while session-start
        // continues to completion, making the relationship obvious).
        let signpostID = signposter.makeSignpostID()
        let signpostState = signposter.beginInterval(
            "session-start",
            id: signpostID,
            "channel=\(channelLoginName)"
        )
        defer { signposter.endInterval("session-start", signpostState) }

        do {
            // Registry returns the cached session if one exists for this
            // (userId, channelId), or constructs + starts a new one. Either
            // way the session is already-running by the time we get it.
            let session = try await registry.session(
                accountUserId: account.userId,
                accountLogin: account.login,
                channelId: channelId,
                channelLoginName: channelLoginName
            )
            logger.info("ChatScreen got session for #\(channelLoginName) (cached or new)")

            // Hand the session to the tab model, which atomically primes
            // `chatModel.lines` from the session's current ring buffer AND
            // subscribes for future messages via `ChannelSession.subscribe(_:)`.
            //
            // For the MVP this is always a single-element array. When multi-
            // channel tabs ship, `attach(sessions: [a, b, c])` will subscribe
            // to all of them with the same model — the rest of ChatScreen
            // doesn't need to change.
            //
            // Lifecycle: detach() is called from `.onDisappear` in the body
            // below. The model's pub-sub subscriptions stay live as long as
            // this ChatScreen instance is mounted; on tear-down they're
            // released, but the underlying `ChannelSession` stays alive in
            // the registry (other tabs may share it, ref counting in commit E).
            //
            // Phase 2.2 addition: hand in the per-channel EmoteIndex so each
            // incoming message gets normalized through
            // `Normalizer.normalize(...)` against the third-party emote
            // table. The index may not be loaded yet at this point — the
            // model tolerates a nil/empty snapshot and tokens stay as text
            // until the snapshot fills in.
            //
            // T11: index comes from the registry (same object across all
            // ChatScreen mounts for this channel). Fall through to a
            // throwaway EmoteIndex if registry is missing — startSession
            // already errored out above in that case, so this branch is
            // effectively unreachable; the fallback exists only to keep
            // the type-checker happy without forcing a force-unwrap.
            let index = registry.emoteIndex(
                forAccountUserId: account.userId,
                channelId: channelId
            )
            await chatModel.attach(
                sessions: [session],
                emoteIndex: index,
                currentUserId: account.userId,
                currentUserLogin: account.login,
                currentUserDisplayName: account.displayName,
                // User-configured highlight keywords (Profile → Highlight
                // Keywords). Read at attach time — changing them mid-session
                // applies on the next channel attach (reopen / relaunch).
                // Self-mentions are always highlighted regardless of this
                // list; keywords are additive.
                highlightKeywords: HighlightSettings.keywords(),
                // Chat History setting — read at attach time, like the
                // keywords. Tab remounts re-attach, so a changed setting
                // takes hold on the next swipe back to (or reopen of) a
                // channel.
                lineCap: ChatAppearance.chatHistoryLines(),
                // Registry-owned normalize memo — survives this screen's
                // unmount so swiping back re-primes from cache hits
                // instead of re-tokenizing the whole ring (see
                // NormalizedLineCache).
                lineCache: registry.normalizedLineCache(
                    forAccountUserId: account.userId,
                    channelId: channelId
                ),
                // Hybrid mod detection: an async provider for the account's
                // moderated-channel set (`/moderation/channels`, cached per
                // account on the registry). attach fires it concurrently —
                // it never blocks chat startup — and seeds
                // `currentUserCanModerate` when this channel is in the set,
                // so mods get Delete Message without sending a message
                // first. Captures the userId string (not `account`, a
                // non-Sendable @Model) and the registry weakly — if the
                // registry is gone by resolution time the model just
                // falls back to badge observation.
                moderatedChannelIds: { [weak registry, accountUserId = account.userId] in
                    await registry?.moderatedChannelIds(
                        forAccountUserId: accountUserId
                    ) ?? []
                },
                // Counterpart hook: a live unmod (channel.moderate event or
                // subscription revocation) evicts the registry's cached
                // moderated-set, so reopening the channel refetches instead
                // of re-seeding mod affordances from the stale entry.
                onModerationRevoked: { [weak registry, accountUserId = account.userId] in
                    await registry?.invalidateModeratedChannels(
                        forAccountUserId: accountUserId
                    )
                }
            )
        } catch is CancellationError {
            // Expected on view tear-down / channel-tab switch. The outgoing
            // instance's `try await registry.session(...)` gets cancelled in
            // flight. Silently exit — don't show a red error.
            logger.info("ChatScreen session-start cancelled for #\(channelLoginName)")
        } catch {
            errorMessage = "Couldn't open chat: \(error.localizedDescription)"
            logger.error("ChatScreen failed to acquire session: \(error.localizedDescription)")
        }
    }
}
