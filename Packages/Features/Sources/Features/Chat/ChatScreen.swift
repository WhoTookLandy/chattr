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

    /// The session lifecycle for `chatModel`: attach on mount, detach on
    /// teardown, Retry and the compose bar's self-heal — and the error to
    /// show when a start fails. Driven from `.task(id: channelId)` below.
    @State private var sessionCoordinator = ChatSessionCoordinator()

    /// What `sessionCoordinator` works against, built where it is used: the
    /// registry is only readable from the environment, and the account is
    /// read when a start actually runs.
    private var sessionLink: ChatSessionCoordinator.Link {
        .live(
            registry: channelSessionRegistry,
            chatModel: chatModel,
            account: account,
            channel: channel
        )
    }

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
    /// Stays on ChatScreen (not ChatTranscript) because it's WRITTEN by
    /// `blockAuthor(of:reason:isReport:)` here; the transcript reads it
    /// through a binding for the pill overlay.
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

    /// "Create Clip" from the compose bar's ⋯ menu (live channels only).
    @State private var showCreateClip = false

    /// Opens Twitch clip links tapped in chat in `ClipPlayerSheet` instead
    /// of Safari. Its `openURLAction` is built once, so installing it in the
    /// environment never changes the value the chat cells see.
    @State private var clipLinks = ClipLinkRouter()

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
        @Bindable var clipLinkRouter = clipLinks
        // Resolved once here and captured by the row factory below, which
        // runs once per cell (see `RowDependencies`).
        let rowDependencies = RowDependencies(
            accountUserId: account.userId,
            badgeStore: badgeStore
        )
        // `.safeAreaBar(edge: .bottom)` pins the compose bar below the
        // scrolling content with integrated glass blur (iOS 26). The bar
        // lives INSIDE ChatScreen (not in ChatPagerScreen) because each
        // tab has its own draft — sharing one bar across tabs would lose
        // drafts on swipe.
        Group {
            if let errorMessage = sessionCoordinator.errorMessage {
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
                    channelId: channelId,
                    channelLoginName: channelLoginName,
                    tabId: tabId,
                    connectionStatus: connectionStatus,
                    rowContent: { line in chatRow(for: line, rowDependencies) },
                    rowInputs: rowInputs(badgeStore: rowDependencies.badgeStore),
                    openURL: clipLinks.openURLAction,
                    onLineTapped: { line in
                        // Only real chat messages have an author to show.
                        guard line.kind == .message, !line.authorUserId.isEmpty else { return }
                        // The author's recent lines are filtered out of the
                        // transcript here, once per presentation — not in
                        // the sheet's content closure, which re-runs with
                        // this body.
                        userCardTarget = UserCardTarget(
                            line: line,
                            transcript: chatModel.transcriptSnapshot().lines
                        )
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
        // Opt-in TestFlight / Developer HUD (renders EmptyView with zero cost when off).
        .overlay(alignment: .bottomLeading) {
            ChatDebugOverlay(channelLoginName: channelLoginName)
        }
        // Chat surface color — slightly lifted off pure black/white in
        // both schemes (see DesignSystem.Color.chatSurface). Applied here
        // (not on the list) so the empty/connecting states and the area
        // behind the glass compose bar share the same surface.
        // `ChatSurfaceBackground` turns translucent in the landscape
        // "chat over video" layout; its own view, so only it re-renders.
        .background { ChatSurfaceBackground() }
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
        // On the landscape stage the video moves beside the chat, so the
        // header collapses — but stays mounted: it keeps driving playback.
        .safeAreaBar(edge: .top) {
            StreamHeaderView(channel: channel, tabId: tabId) {
                showViewerList = true
            }
            .hiddenOnLandscapeStage()
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
            let isOwnLine = target.line.authorUserId == rowDependencies.accountUserId
            UserCardSheet(
                line: target.line,
                badges: rowDependencies.badgeStore?.entries(for: target.line.originalBadges) ?? [],
                account: account,
                accountStore: accountStore,
                recentLines: target.recentLines,
                rowContent: { chatRow(for: $0, rowDependencies) },
                // An undelivered row has only its local `pending-…` id —
                // nothing Twitch can thread a reply against.
                onReply: target.line.deliveryState == .delivered
                    ? { chatModel.beginReply(to: target.line) }
                    : nil,
                onBlock: isOwnLine ? nil : {
                    blockAuthor(of: target.line, reason: .other, isReport: false)
                },
                onReport: isOwnLine ? nil : { reason in
                    blockAuthor(of: target.line, reason: reason, isReport: true)
                },
                // Mods get timeouts / ban / warn — never on themselves or
                // the broadcaster (Twitch refuses both anyway).
                moderation: (chatModel.currentUserCanModerate
                             && !isOwnLine
                             && target.line.authorUserId != channelId)
                    ? chatModel : nil
            )
            .id(target.line.authorUserId)
        }
        .sheet(isPresented: $showViewerList) {
            ViewerListSheet(channel: channel, account: account, accountStore: accountStore)
        }
        .sheet(item: $viewingThreadRootId) { root in
            ThreadView(
                rootMessageId: root.id,
                chatModel: chatModel,
                badgeStore: rowDependencies.badgeStore,
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
        .sheet(isPresented: $showCreateClip) {
            CreateClipSheet(channel: channel, account: account, accountStore: accountStore)
        }
        // A clip link tapped in chat (routed here by `clipLinks`).
        .sheet(item: $clipLinkRouter.presented) { clip in
            ClipPlayerSheet(clip: clip)
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
        //   - Runs the session start on first mount (and on channelId change,
        //     though channelId is stable per ChatScreen instance).
        //   - `ChatSessionCoordinator.run` sleeps indefinitely after the
        //     start completes, holding the task alive until SwiftUI cancels
        //     it.
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
            await sessionCoordinator.run(sessionLink)
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
        //
        // The load goes through the registry, not straight to the index:
        // the registry starts it too when it creates the session (a restored
        // background tab never mounts this screen), and when the table
        // changes it has the session re-normalize the rows it tokenized
        // against the old one. This call is the remount retry.
        .task {
            guard let registry = channelSessionRegistry else { return }
            let accountUserId = account.userId
            let index = registry.emoteIndex(
                forAccountUserId: accountUserId,
                channelId: channelId
            )
            let id = signposter.makeSignpostID()
            let state = signposter.beginInterval(
                "emote-load",
                id: id,
                "channel=\(channelLoginName)"
            )
            await registry.loadEmotes(
                accountUserId: accountUserId,
                channelId: channelId,
                channelLoginName: channelLoginName
            )
            let count = index.snapshot().count
            signposter.endInterval("emote-load", state, "count=\(count)")
            logger.info("EmoteIndex loaded for #\(channelLoginName, privacy: .public): \(count) emotes")
        }
        // Detach is now handled inside the .task(id: channelId) above —
        // structurally bound to view lifetime via CancellationError, no
        // unstructured Task needed. See the doc-comment on that .task
        // for why.
        //
        // Clip links in the sheets above open in-app. A stable value — see
        // `clipLinks`. The transcript's cells are separate hosting roots
        // that don't inherit this, so `ChatTranscript` hands the same
        // action to each row explicitly.
        .environment(\.openURL, clipLinks.openURLAction)
        .onAppear {
            logger.info("ChatScreen appeared #\(channelLoginName, privacy: .public) (id=\(channelId, privacy: .public), tab=\(tabId?.uuidString.prefix(8).description ?? "nil", privacy: .public))")
        }
        .onDisappear {
            logger.info("ChatScreen disappeared #\(channelLoginName, privacy: .public)")
        }
        .onChange(of: sessionCoordinator.errorMessage) { _, errorMessage in
            guard let errorMessage else { return }
            ChatDiagnostics.shared.recordPage(ChatPageDiagnosticSnapshot(
                channelLogin: channelLoginName,
                channelId: channelId,
                tabId: tabId?.uuidString.prefix(8).description ?? "nil",
                errorMessage: errorMessage,
                attachState: String(describing: chatModel.attachState),
                transcriptBranch: "error",
                isEmpty: chatModel.isEmpty,
                visibleLineCount: chatModel.visibleLineCount,
                unfilteredLineCount: chatModel.unfilteredLineCount,
                blockedCount: chatModel.blockedUserCount,
                changeVersion: chatModel.changeVersion,
                isVisible: true,
                connectionState: connectionStatus.map { String(describing: $0.state) } ?? "nil"
            ))
        }
        // Landscape with the stream showing: video beside / under this
        // whole chat column. Applied last so everything above (transcript,
        // header, compose bar, sheets, session tasks) keeps one structural
        // identity across rotation — see `LandscapeStageLayout`.
        .landscapeStageLayout(channel: channel, tabId: tabId)
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
            tabId: tabId,
            replyContext: chatModel.replyContext,
            chatRestrictions: chatModel.chatRestrictions,
            // The state object, not its value: only the bar observes it.
            ownRestriction: chatModel.ownRestriction,
            // Mods and the broadcaster skip slow mode: no countdown ring.
            slowModeExempt: chatModel.currentUserCanModerate,
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
            // Read on demand (when an @mention starts), so the transcript
            // read stays off this body's dependency list.
            mentionPoolProvider: { [chatModel, channelLoginName, channelDisplayName] in
                MentionAutocomplete.pool(
                    from: chatModel.lines,
                    broadcasterLogin: channelLoginName,
                    broadcasterDisplayName: channelDisplayName,
                    excludingLogin: chatModel.selfLogin
                )
            },
            onSend: { draft in
                // Self-heal first: a model that lost its live session is
                // re-attached before the send (see `reattachIfNeeded`).
                await sessionCoordinator.reattachIfNeeded(sessionLink)
                await chatModel.send(text: draft)
            },
            // Settings live in the compose bar's ⋯ menu (moved out of the
            // top bar, where the gear competed with the channel pill).
            onOpenSettings: { showChatSettings = true },
            createClip: ComposeBar.CreateClipEntry(
                channelId: channelId,
                action: { showCreateClip = true }
            )
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
                sessionCoordinator.retry(sessionLink)
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
    private func rowInputs(badgeStore: ChatBadgeStore?) -> ChatRowInputs {
        ChatRowInputs(
            badgeEntryCount: badgeStore?.entries.count ?? 0,
            canModerate: chatModel.currentUserCanModerate
        )
    }

    /// What `chatRow(for:_:)` needs besides the line and the model, resolved
    /// once per `body`. The row factory runs once per configured cell, and
    /// resolving these there meant a registry lookup (which builds its key
    /// string) and several `account.userId` reads (a SwiftData getter) for
    /// every cell. Both are fixed for this screen's lifetime, so capturing
    /// them obeys the callback rule below.
    private struct RowDependencies {
        let accountUserId: String
        let badgeStore: ChatBadgeStore?
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
    private func chatRow(for line: ChatLine, _ dependencies: RowDependencies) -> ChatRow {
        let isOwnLine = line.authorUserId == dependencies.accountUserId
        return ChatRow(
            line: line,
            badgeEntries: dependencies.badgeStore?.entries(for: line.originalBadges) ?? [],
            onRetry: { Task { await chatModel.retry(failedLineId: line.id) } },
            onReply: { chatModel.beginReply(to: line) },
            onViewThread: {
                viewingThreadRootId = ThreadRootID(id: ChatTranscriptModel.threadRoot(of: line))
            },
            onDelete: (chatModel.currentUserCanModerate && !isOwnLine)
                ? { Task { await chatModel.deleteMessage(withId: line.id) } }
                : nil,
            onBlock: isOwnLine ? nil : {
                blockAuthor(of: line, reason: .other, isReport: false)
            },
            onReport: isOwnLine ? nil : { reason in
                blockAuthor(of: line, reason: reason, isReport: true)
            }
        )
    }

    /// Blocks the author of `line` — the one path behind Block and Report,
    /// from the row menu and the user card alike. A report is a block with
    /// a reason, and also flashes the "Reported & blocked" pill for ~2s.
    private func blockAuthor(of line: ChatLine, reason: UserBlockReason, isReport: Bool) {
        Task {
            await blockStore?.block(
                userId: line.authorUserId,
                login: line.authorUserLogin,
                displayName: line.authorDisplayName,
                reason: reason
            )
            guard isReport else { return }
            showReportConfirmation = true
            reportConfirmationDismiss?.cancel()
            reportConfirmationDismiss = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                showReportConfirmation = false
            }
        }
    }
}
