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

/// One channel's chat: the transcript (`ChatTranscript`), the compose bar,
/// and the sheets hanging off them (thread, chat settings). Owns the per-tab
/// `ChatTranscriptModel` and its session lifecycle; rows render Twitch-native
/// and 7TV / BTTV / FFZ emotes (animated included) inline.
public struct ChatScreen: View {
    private let account: Account
    private let accountStore: AccountStore

    /// The channel this screen renders — the platform-qualified identity.
    /// Taking the descriptor whole (instead of the previous three loose
    /// String fields) keeps the platform tag attached and spares the
    /// caller from destructuring a descriptor it already holds.
    private let channel: ChannelDescriptor

    // Conveniences so the body reads `channelLoginName` rather than
    // `channel.channelLoginName` everywhere. Twitch-facing call sites
    // (Helix, EventSub) take the bare `channelId`; storage keys take
    // the composite `channel.id`.
    private var channelId: String { channel.channelId }
    private var channelLoginName: String { channel.channelLoginName }
    private var channelDisplayName: String { channel.channelDisplayName }

    /// Per-tab chat state — owns the transcript and the session
    /// subscriptions. New rows arrive already normalized, drained from the
    /// session's mailbox in batches on the main actor (the model is
    /// `@MainActor @Observable`).
    @State private var chatModel = ChatTranscriptModel()

    @State private var errorMessage: String?

    /// The attach epoch owned by the CURRENT session-lifecycle task (see
    /// `.task(id: channelId)`). Each run of that task mints a fresh lease and
    /// detaches with whatever epoch it holds at teardown. Out-of-band attaches
    /// — the error view's Retry button and the compose bar's self-heal — record
    /// into the live lease too, so the attachment they create is torn down
    /// when the view goes away. Without it, a retry after a failed start left
    /// the task holding the `0` sentinel and its `detach(ifEpoch: 0)` no-op'd,
    /// keeping a subscription draining the session offscreen.
    @State private var attachLease = AttachLease()

    /// The persisted compose draft for this channel, read from `DraftStorage`
    /// exactly once at construction (see `init`). `ComposeBar` only consumes
    /// `seedDraft` at first mount thanks to its own `@State(initialValue:)`
    /// semantics, so re-reading it on every `body` evaluation — as the old
    /// `composeBarView` did — was wasted UserDefaults work (back then `body`
    /// re-evaluated on each new chat line). Seeding it here moves the read to
    /// struct construction (parent rebuilds) while preserving exact
    /// first-mount behavior.
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
    /// Tapped message whose author's card is showing.
    @State private var userCardTarget: UserCardTarget?
    /// Viewer list sheet (from the viewer count on the video).
    @State private var showViewerList = false

    /// True while the in-chat settings sheet (chat modes + preferences)
    /// is presented. Opened from the compose bar's gear button.
    @State private var showChatSettings = false

    // NOTE: compose-bar state (`composeText`, `isSending`, `composeFocused`)
    // lives inside the extracted `ComposeBar` view below — NOT here on
    // ChatScreen. That isolation matters: every keystroke in the
    // TextField mutates the draft, and if the @State lived on ChatScreen
    // each keystroke would re-evaluate the whole screen body (transcript
    // wiring, sheets, toolbar). Pulling the state into a child View
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

    /// The pager tab this page renders, or nil outside the pager (always
    /// active then). Stable for the page's lifetime — deliberately NOT an
    /// `isActive` flag: a flag would change on every swipe, re-creating this
    /// struct and re-running this body (and the transcript + UIKit list update
    /// under it) for each page whose flag flipped. The views that care which
    /// page is visible (`StreamHeaderView`, `ChatWelcomeOverlay`) derive it
    /// from `ChatTabsModel.activeTabId` themselves, so a swipe invalidates
    /// only them.
    private let tabId: UUID?

    public init(
        account: Account,
        accountStore: AccountStore,
        channel: ChannelDescriptor,
        tabId: UUID? = nil
    ) {
        self.account = account
        self.accountStore = accountStore
        self.channel = channel
        self.tabId = tabId
        // Read the persisted draft once, here at construction. `State(initial-
        // Value:)` is the correct home for a value that only matters at first
        // mount — a `.task`-based seed would arrive AFTER `ComposeBar` has
        // already captured its initial draft, silently breaking restoration.
        self._draftSeed = State(initialValue: DraftStorage.load(forChannel: channel.id))
    }

    public var body: some View {
        // `@Bindable` projection of the @Observable model — gives us
        // `$bindableChatModel.isShowingSendError` for the .alert binding
        // without writing a `Binding(get:set:)` inline (Swift 5.9+ allows
        // declaring @Bindable inside body for view-scoped projections).
        @Bindable var bindableChatModel = chatModel
        // `.safeAreaBar(edge: .bottom)` pins the compose bar below the
        // scrolling content with integrated glass blur (iOS 26). The bar
        // lives INSIDE ChatScreen (not in ChatPagerScreen) because each
        // tab has its own draft — sharing one bar across tabs would lose
        // drafts on swipe.
        Group {
            if let errorMessage {
                errorView(errorMessage)
            } else {
                // The transcript (empty state + message list + pills) is a
                // separate child view for OBSERVATION SCOPING: it is the only
                // body that reads the model's per-flush state
                // (`changeVersion`, `isEmpty`), so publishes re-evaluate just
                // that subtree. Before this split, the `lines.isEmpty` read
                // right here subscribed ALL of ChatScreen.body to the buffer —
                // the whole screen (compose bar closures, sheets, alert
                // wiring) re-ran for every inbound message, 50–200×/sec
                // during raids.
                //
                // Passing `chatModel` itself registers NO dependency — only
                // property reads do. `rowContent` closes over ChatScreen's
                // row callbacks (retry/reply/block/report) so the transcript
                // stays ignorant of them; the closures run from the cell
                // provider, outside any body, exactly as before.
                ChatTranscript(
                    chatModel: chatModel,
                    channelLoginName: channelLoginName,
                    tabId: tabId,
                    connectionStatus: connectionStatus,
                    rowContent: { line in chatRow(for: line) },
                    rowInputs: rowInputs,
                    onLineTapped: { line in
                        // Only real chat messages have an author to show.
                        guard line.kind == .message, !line.authorUserId.isEmpty else { return }
                        userCardTarget = UserCardTarget(line: line)
                    },
                    showReportConfirmation: $showReportConfirmation
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Join greeting. Attached BEFORE the safe-area bars so it lays out
        // inside them — under the stream header, not on top of it. Its own
        // view so its state, its active-page read and its animation stay
        // scoped to the pill: the `.animation(value:)` used to sit on this
        // whole chain, animating anything in the transcript that changed in
        // the same transaction.
        //
        // Below it, the live poll / prediction / Hype Train banners — one
        // self-contained view owning its own model and feed, so their ticks
        // never re-run this body or the transcript. Mounted only on the
        // account's own channel: Twitch authorizes those events for the
        // broadcaster alone (see `ChannelSession+LiveEvents.swift`), so
        // anywhere else there is nothing to show and nothing to subscribe.
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                ChatWelcomeOverlay(channel: channel, tabId: tabId)
                if channelId == account.userId {
                    LiveEventsBannerArea(chatModel: chatModel, tabId: tabId)
                        .padding(.top, 8)
                }
            }
        }
        // Chat surface color — slightly lifted off pure black/white in
        // both schemes (see DesignSystem.Color.chatSurface). Applied here
        // (not on the list) so the empty/connecting states and the area
        // behind the glass compose bar share the same surface.
        .background(Color.chatSurface.ignoresSafeArea())
        // "You're timed out / banned / warned here" — directly under the
        // stream header (this bar is applied first, so it sits inside the
        // header's). Self-contained and observes only its own small state,
        // so it costs this body and the transcript nothing; renders no
        // content (zero height) when there's nothing to say. Other
        // top-of-chat banners can stack as sibling bars beside it.
        .safeAreaBar(edge: .top) {
            OwnChatRestrictionBanner(
                state: chatModel.ownRestriction,
                channelLoginName: channelLoginName,
                tabId: tabId
            )
        }
        // Stream context (title, category, live/viewers/uptime, or offline
        // + last live) pinned above the transcript. Its own view reading
        // its own stores, so status refreshes never re-run this body.
        .safeAreaBar(edge: .top) {
            StreamHeaderView(channel: channel, tabId: tabId) {
                showViewerList = true
            }
        }
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
        // User card: a short sheet over a still-usable chat; drag up for
        // bio + this user's recent messages here.
        .sheet(item: $userCardTarget) { target in
            let row = chatRow(for: target.line)
            UserCardSheet(
                line: target.line,
                badges: row.badgeEntries,
                account: account,
                accountStore: accountStore,
                recentLines: chatModel.transcriptSnapshot().lines.filter {
                    $0.authorUserId == target.line.authorUserId && $0.kind == .message
                },
                rowContent: { chatRow(for: $0) },
                onReply: { chatModel.beginReply(to: target.line) },
                onBlock: target.line.authorUserId == account.userId ? nil : {
                    Task {
                        await blockStore?.block(
                            userId: target.line.authorUserId,
                            login: target.line.authorUserLogin,
                            displayName: target.line.authorDisplayName,
                            reason: .other
                        )
                    }
                },
                onReport: target.line.authorUserId == account.userId ? nil : { reason in
                    Task {
                        await blockStore?.block(
                            userId: target.line.authorUserId,
                            login: target.line.authorUserLogin,
                            displayName: target.line.authorDisplayName,
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
                },
                // Mods get timeouts / ban / warn — never on themselves or
                // the broadcaster (Twitch refuses both anyway).
                moderation: (chatModel.currentUserCanModerate
                             && target.line.authorUserId != account.userId
                             && target.line.authorUserId != channelId)
                    ? chatModel : nil
            )
        }
        .sheet(isPresented: $showViewerList) {
            ViewerListSheet(channel: channel, account: account, accountStore: accountStore)
        }
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
        // Chat settings entry point: the compose bar's ⋯ menu (see
        // `ComposeBar.moreMenu`). The top-bar gear it replaced competed
        // with the channel pill for the same glance.
        // No `.navigationTitle` here — the parent ChatPagerScreen sets it to
        // "Chat" and the active tab pill in the strip already identifies the
        // channel. Having ChatScreen also override the title to "#login"
        // would just duplicate the information already shown one row below.
        //
        // Three structured tasks, all bound to view lifetime. SwiftUI cancels
        // them on tear-down (incl. when ChatPagerScreen swaps the active
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
        //     `await chatModel.detach(ifEpoch:)` runs in the task's final
        //     breath — structurally bound to view lifetime instead of
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
            // A lease per task run: a channelId change starts a new run with
            // a new lease, so the outgoing run's teardown can never detach an
            // epoch the incoming run (or a retry during it) established.
            let lease = AttachLease()
            attachLease = lease
            await startSession(recordingInto: lease)
            // Hold the task open until SwiftUI cancels us (view torn down
            // or channelId changes). Sleeping for a year is the canonical
            // SwiftUI idiom — Task.sleep is implemented as a scheduler
            // primitive, not a busy-loop, so the cost is zero CPU.
            try? await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
            // Cancellation reaches here via CancellationError from sleep.
            // Detach ONLY if this appearance still owns the current attachment:
            // a newer ChatScreen appearance (paged re-mount, or a session
            // teardown+rebuild) bumps the model's epoch, so a stale teardown
            // here becomes a no-op and can't strand the freshly re-attached
            // model (the "I see chat but it says Not connected" bug). The
            // chatModel reference survives because @State storage persists
            // until the task fully exits.
            // Close the lease FIRST (synchronously, before any suspension):
            // an out-of-band start still in flight will then detach its own
            // attachment when it lands instead of recording it into a lease
            // nobody will tear down. Cancel it too, so it stops early.
            lease.close()
            await chatModel.detach(ifEpoch: lease.epoch)
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
            // The state object, not its value: only the bar observes it.
            ownRestriction: chatModel.ownRestriction,
            // Seeded once at construction (see `draftSeed` / `init`), not
            // re-read here — the seed only matters at first mount thanks to
            // ComposeBar's own @State semantics, so reading it on every body
            // pass was wasted UserDefaults work on the per-message hot path.
            seedDraft: draftSeed,
            onCancelReply: { chatModel.cancelReply() },
            // Debounced: storage is written once typing pauses (~400ms),
            // not per keystroke. Flushed in `.onDisappear` below.
            onDraftChange: { [channelKey = channel.id] newDraft in
                DraftStorage.scheduleSave(forChannel: channelKey, text: newDraft)
            },
            // Captures the concrete EmoteIndex instance + globals dict
            // (resolved above), NOT @Environment — so it returns real
            // emotes when invoked on the button tap. Built on demand
            // (the snapshot read + section build runs only when tapped).
            emoteSectionsProvider: {
                EmoteCatalog.buildSections(
                    emoteIndex: resolvedEmoteIndex,
                    twitchGlobal: resolvedTwitchGlobals
                )
            },
            onSend: { draft in
                // Self-heal: if the model lost its live session under us (a
                // lifecycle race, or a session teardown+rebuild that left it
                // detached while still showing primed lines), re-establish it
                // before sending — so the user never hits a phantom
                // "Not connected to chat" on a channel that's clearly live.
                // `startSession`/`attach` are epoch-guarded + idempotent, so a
                // no-op when already attached.
                if chatModel.attachState != .attached {
                    await startSession(recordingInto: attachLease)
                }
                await chatModel.send(text: draft)
            },
            // Settings live in the compose bar's ⋯ menu (moved out of the
            // top bar, where the gear competed with the channel pill).
            onOpenSettings: { showChatSettings = true }
        )
        // Write any draft still inside the debounce window when the compose
        // bar leaves (page swiped off, tab closed, account switched).
        .onDisappear { DraftStorage.flushPendingSaves() }
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
            // Without an in-place retry this screen is a dead end: the error
            // never clears and `.task(id: channelId)` won't re-fire for the
            // same channel — the only escape was closing the tab.
            Button("Retry") {
                let lease = attachLease
                guard !lease.isClosed else { return }
                lease.track(Task { await startSession(recordingInto: lease) })
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The non-line inputs `chatRow(for:)` reads (see `ChatRowInputs`).
    /// `chatRow` itself runs from the cell provider, OUTSIDE any body, so
    /// those reads were never observed and configured rows went stale; this
    /// is read in `body` instead, so a badge-table load or a mod-status flip
    /// re-renders the transcript and the list reconfigures its rows. Both
    /// change rarely (badges load once per channel; mod status flips at most
    /// a few times), so the extra dependencies cost nothing at message rate.
    private var rowInputs: ChatRowInputs {
        ChatRowInputs(
            badgeEntryCount: badgeStore?.entries.count ?? 0,
            canModerate: chatModel.currentUserCanModerate
        )
    }

    /// Builds the row for one line — badge lookup plus callbacks — in one
    /// place, so both the collection-view cell provider and the legacy
    /// `LazyVStack` (macOS) use the same construction.
    ///
    /// Callback rule: a closure may capture only the `line` and stable
    /// references (`chatModel`, `@State` storage, the block store). ChatRow
    /// compares callbacks by presence, not identity (`ChatRow.Affordances`),
    /// so when a row compares equal SwiftUI keeps the OLD closures — one
    /// capturing any other changing value would silently go stale.
    private func chatRow(for line: ChatLine) -> ChatRow {
        ChatRow(
            line: line,
            badgeEntries: badgeStore?.entries(for: line.originalBadges) ?? [],
            onRetry: { Task { await chatModel.retry(failedLineId: line.id) } },
            onReply: { chatModel.beginReply(to: line) },
            onViewThread: {
                viewingThreadRootId = ThreadRootID(id: ChatTranscriptModel.threadRoot(of: line))
            },
            onDelete: (chatModel.currentUserCanModerate
                       && line.authorUserId != account.userId)
                ? { Task { await chatModel.deleteMessage(withId: line.id) } }
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

    /// Starts (or re-establishes) the session attachment and records the
    /// resulting epoch into `lease`, which the session-lifecycle task passes
    /// to `detach(ifEpoch:)` on teardown. A failed, cancelled or missing-
    /// registry start records nothing, leaving the lease's previous epoch
    /// (or the `0` pre-attach sentinel, whose teardown no-ops unless nothing
    /// ever attached). If the lease closed while the start was in flight,
    /// its teardown has already run, so this start detaches its own
    /// attachment rather than leaving it orphaned.
    @MainActor
    private func startSession(recordingInto lease: AttachLease) async {
        let epoch = await attachSession()
        guard epoch != 0 else { return }
        if lease.isClosed {
            await chatModel.detach(ifEpoch: epoch)
        } else {
            lease.record(epoch)
        }
    }

    @MainActor
    /// - Returns: the attach epoch the model established, or `0` if no attach
    ///   happened (missing registry, cancelled, or error).
    private func attachSession() async -> Int {
        // Clear any prior failure so a retry (button or compose-bar
        // self-heal) actually dismisses the error view; a repeat failure
        // re-sets it below.
        errorMessage = nil
        // Badge load runs in a sibling .task modifier (see body) — gives us
        // structured-cancellation parity with this session-start task.
        guard let registry = channelSessionRegistry else {
            errorMessage = "Couldn't open chat: missing session registry"
            logger.error("ChatScreen has no registry in environment — was RootView injected?")
            return 0
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

            // Hand the session to the tab model, which atomically primes its
            // transcript from the session's current ring buffer AND
            // subscribes for future rows via `ChannelSession.subscribe()`.
            //
            // For the MVP this is always a single-element array. When multi-
            // channel tabs ship, `attach(sessions: [a, b, c])` will subscribe
            // to all of them with the same model — the rest of ChatScreen
            // doesn't need to change.
            //
            // Lifecycle: the session-lifecycle `.task(id: channelId)` in the
            // body detaches (with the epoch returned here) when SwiftUI
            // cancels it. The model's subscriptions stay live as long as this
            // ChatScreen instance is mounted; on tear-down they're released,
            // but the underlying `ChannelSession` stays alive in the registry
            // (other tabs may share it — it's ref-counted there).
            //
            // Rows arrive already normalized: the session tokenizes each
            // message once, off the main actor, against the registry-owned
            // EmoteIndex this screen's emote `.task` loads (same instance),
            // and every tab showing the channel shares the result.
            let epoch = await chatModel.attach(
                sessions: [session],
                currentUserId: account.userId,
                currentUserLogin: account.login,
                currentUserDisplayName: account.displayName,
                // User-configured highlight keywords (Profile → Highlight
                // Keywords). Read at attach time — changing them mid-session
                // applies on the next channel attach (reopen / relaunch).
                // Self-mentions are always highlighted regardless of this
                // list (the session flags them); keywords are additive and
                // applied by this model, per attach.
                highlightKeywords: HighlightSettings.keywords(),
                // Chat History setting — read at attach time, like the
                // keywords. Tab remounts re-attach, so a changed setting
                // takes hold on the next swipe back to (or reopen of) a
                // channel.
                lineCap: ChatAppearance.chatHistoryLines(),
                // Composite draft key — the model clears the persisted
                // draft under this key after a successful send. Passed
                // from the descriptor here so the model never has to
                // compose platform-qualified keys itself.
                draftKey: channel.id,
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
            return epoch
        } catch is CancellationError {
            // Expected on view tear-down / channel-tab switch. The outgoing
            // instance's `try await registry.session(...)` gets cancelled in
            // flight. Silently exit — don't show a red error.
            logger.info("ChatScreen session-start cancelled for #\(channelLoginName)")
            return 0
        } catch {
            errorMessage = "Couldn't open chat: \(error.localizedDescription)"
            logger.error("ChatScreen failed to acquire session: \(error.localizedDescription)")
            return 0
        }
    }
}

/// Mutable holder for the attach epoch a `ChatScreen` session-lifecycle task
/// owns — see `ChatScreen.attachLease`. A reference type so the Retry button
/// and the compose-bar self-heal can record into the lease of the task run
/// that is live when they fire.
@MainActor
final class AttachLease {
    /// The NEWEST epoch any start under this lease established. Epochs only
    /// grow, so keeping the max means a superseded start that finishes late
    /// can't overwrite a newer one with its stale epoch (whose
    /// `detach(ifEpoch:)` would then no-op).
    private(set) var epoch = 0
    /// Set by the lifecycle task's teardown; after that, starts detach what
    /// they establish instead of recording it.
    private(set) var isClosed = false
    /// Out-of-band starts (Retry) in flight, cancelled on close.
    private var pending: [Task<Void, Never>] = []

    func record(_ newEpoch: Int) {
        epoch = max(epoch, newEpoch)
    }

    func track(_ task: Task<Void, Never>) {
        pending.append(task)
    }

    func close() {
        isClosed = true
        for task in pending { task.cancel() }
        pending.removeAll()
    }
}
