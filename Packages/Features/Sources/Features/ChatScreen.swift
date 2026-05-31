import SwiftUI
import Accounts
import Channels
import ChatModel
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

    /// Currently-scrolled message id. Used by the auto-scroll-to-bottom logic
    /// via `.scrollPosition(id:)`. Writing to this binding scrolls the view;
    /// the binding also updates as the user scrolls manually (iOS 17+ API).
    @State private var scrolledMessageId: String?

    /// True when the scroll is at (or near) the bottom — i.e. the user is
    /// "tailing" live chat. Driven by `.onScrollGeometryChange` reading
    /// real scroll geometry. Gates the auto-scroll-on-new-message and
    /// controls the jump-to-bottom pill's visibility (pill shows when
    /// false).
    @State private var isAtBottom = true

    /// Count of messages that arrived while the user was scrolled up
    /// (not tailing). Shown in the jump-to-bottom pill ("3 new
    /// messages") so the user knows how much they're missing. Reset to
    /// 0 whenever they return to the bottom.
    @State private var unreadWhileScrolledUp = 0

    /// Incremented to ask the UIKit chat list to scroll to the newest message
    /// (jump-to-bottom pill). The collection view acts on each change.
    @State private var scrollToBottomToken = 0

    /// Current connection pill, derived from connection-state transitions via
    /// `ConnectionBanner.next`. Driven by the `.onChange` below.
    @State private var connectionBanner: ConnectionBanner = .hidden

    /// Cancels the in-flight "Live again" auto-dismiss when state changes again.
    @State private var liveAgainDismiss: Task<Void, Never>?

    /// Non-nil when the thread sheet is open; carries the thread's root
    /// message ID. `.sheet(item:)` could use `Identifiable`, but the
    /// String here is identifiable already (each root id is unique) so
    /// we wrap it minimally for the API.
    @State private var viewingThreadRootId: ThreadRootID?

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
    }

    public var body: some View {
        // `@Bindable` projection of the @Observable model — gives us
        // `$bindableChatModel.isShowingSendError` for the .alert binding
        // without writing a `Binding(get:set:)` inline (Swift 5.9+ allows
        // declaring @Bindable inside body for view-scoped projections).
        @Bindable var bindableChatModel = chatModel
        // VStack lets the compose bar pin to the bottom while the
        // ScrollView takes the rest. The bar lives INSIDE ChatScreen
        // (not in ChatTabsScreen) because each tab has its own draft —
        // sharing one bar across tabs would lose drafts on swipe.
        VStack(spacing: 0) {
            Group {
                if let errorMessage {
                    errorView(errorMessage)
                } else if chatModel.lines.isEmpty {
                    // Distinguish "attaching" (sessions not yet subscribed) from
                    // "attached but quiet" (subscriptions live, but no messages
                    // have arrived yet). Without explicit state UI a quiet channel
                    // looks identical to a broken connection.
                    emptyOrConnectingView
                } else {
                    chatScrollView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        // openChannel ran `chatTabsModel.open + selectedTab = .chat` back-to-
        // back, the paged-ScrollView LazyHStack briefly re-evaluated children
        // and ChatScreen's task identity dropped). All 6 emote provider HTTP
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
            // Load the persisted draft synchronously here in body.
            // UserDefaults reads are fast + iOS caches them; the seed
            // only matters at first mount thanks to @State semantics.
            seedDraft: DraftStorage.load(forChannelId: channelId),
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

    /// Empty-state placeholder. Two flavors driven by `chatModel.attachState`:
    ///   - `.detached` / `.attaching` → "Connecting to chat…" with a spinner
    ///     (the model's `attach(sessions:)` is in flight — that includes
    ///     registry.session() which subscribes to EventSub).
    ///   - `.attached` → "Connected — waiting for messages" (everything's
    ///     wired, the channel just hasn't had a chat message yet).
    @ViewBuilder
    private var emptyOrConnectingView: some View {
        VStack(spacing: 12) {
            if chatModel.attachState != .attached {
                ProgressView()
                Text("Connecting to chat…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                Text("Connected to #\(channelLoginName)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Waiting for messages…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Selects between the UICollectionView bridge (iOS) and the legacy
    /// SwiftUI ScrollView (macOS / non-UIKit). The UIKit path is the spike
    /// under validation; the legacy path is the known-good fallback.
    @ViewBuilder
    private var chatScrollView: some View {
        #if canImport(UIKit)
        ChatListView(
            lines: chatModel.lines,
            rowContent: { line in chatRow(for: line) },
            isAtBottom: $isAtBottom,
            scrollToBottomToken: scrollToBottomToken
        )
        // New messages while scrolled up tally into the unread pill; while
        // tailing, the collection view auto-scrolls and we reset the count.
        .onChange(of: chatModel.lines.count) { oldCount, newCount in
            if isAtBottom {
                unreadWhileScrolledUp = 0
            } else if newCount > oldCount {
                unreadWhileScrolledUp += (newCount - oldCount)
            }
        }
        .onChange(of: isAtBottom) { _, atBottom in
            if atBottom { unreadWhileScrolledUp = 0 }
        }
        // Jump-to-bottom pill (bottom edge).
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                jumpToBottomPill
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
        // Transient connection indicator (top edge) — carried over from the
        // legacy path so the iOS collection-view list keeps the connection pill
        // the concurrent connection-status workstream added.
        .overlay(alignment: .top) {
            connectionPill
                .padding(.top, 8)
                .animation(.snappy, value: connectionBanner)
        }
        .onChange(of: connectionStatus?.state) { previous, current in
            guard let current else { return }
            connectionBanner = ConnectionBanner.next(previous: previous, current: current)
            liveAgainDismiss?.cancel()
            if connectionBanner == .liveAgain {
                liveAgainDismiss = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if connectionBanner == .liveAgain { connectionBanner = .hidden }
                }
            }
        }
        #else
        legacyScrollView
        #endif
    }

    /// Jump the transcript to the newest message. On UIKit the collection view
    /// owns scrolling (token bump); on other platforms the legacy ScrollView
    /// scrolls via `scrolledMessageId`.
    private func jumpToLatest() {
        #if canImport(UIKit)
        scrollToBottomToken += 1
        #else
        if let last = chatModel.lines.last { scrolledMessageId = last.id }
        #endif
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
                : nil
        )
    }

    /// The scrolling chat content. Only mounted once we have at least one
    /// message — keeps the empty-state cleanly separated and avoids feeding
    /// an empty LazyVStack into `.scrollPosition` (which would no-op until
    /// rows arrive but log-spams about a missing target).
    ///
    /// **Scroll edge effect**: `.hard` style is the right pick here because
    /// our parent (`ChatTabsScreen`) renders a pinned glass tab strip
    /// directly above this scroll. Per axiom-design's liquid-glass guidance:
    /// "use `.hard` style for pinned accessory views" — that's exactly what
    /// the tab strip is. The hard variant dissolves scrolling content into
    /// the background just under the strip, giving a crisp visual shelf
    /// without the old explicit Divider we used to have here.
    @ViewBuilder
    private var legacyScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(chatModel.lines) { line in
                    ChatRow(
                        line: line,
                        // `?? []` is the safe fallback when the registry isn't
                        // in the environment — but startSession() already
                        // catches that case and surfaces an error UI, so in
                        // practice we always have a store here. The fallback
                        // just prevents force-unwrap explosions during weird
                        // preview/test configurations.
                        badgeEntries: badgeStore?.entries(for: line.originalBadges) ?? [],
                        // Per-row retry handler — only triggers when the
                        // ChatRow shows its failure footer (delivery state
                        // is `.failed`). The Task indirection escapes
                        // the synchronous Button action into the
                        // @MainActor model's async retry method.
                        onRetry: { Task { await chatModel.retry(failedLineId: line.id) } },
                        // Long-press → Reply. Sync-only — beginReply
                        // just mutates @Observable state on the model,
                        // no Task needed.
                        onReply: { chatModel.beginReply(to: line) },
                        // Long-press → View Thread. Sets the sheet
                        // state to this line's thread root. The same
                        // sheet works for both a "reply leading to a
                        // thread" (root = parent's threadRootMessageId)
                        // and a "I might be the root of a thread"
                        // (root = my own id, sheet shows me + any
                        // matching replies).
                        onViewThread: {
                            viewingThreadRootId = ThreadRootID(id: TabChatModel.threadRoot(of: line))
                        },
                        // Mod-only delete affordance. The closure is
                        // nil for non-mods and for messages already in
                        // a deleted state, so the menu entry is
                        // hidden in those cases. We also hide it for
                        // our OWN messages — `DELETE /moderation/chat`
                        // rejects the broadcaster trying to delete
                        // their own messages anyway, and for a regular
                        // mod the affordance is nonsensical: just
                        // edit your own text instead of pretending to
                        // moderate yourself.
                        onDelete: (chatModel.currentUserCanModerate
                                   && line.authorUserId != account.userId)
                            ? { Task { await chatModel.deleteMessage(line.id) } }
                            : nil
                    )
                    .id(line.id)
                }
            }
            // `.scrollTargetLayout` tells the enclosing ScrollView to treat
            // this LazyVStack's children's `.id(...)` values as anchor points
            // for `.scrollPosition(id:)`. Without it, the position binding
            // has nothing to attach to.
            .scrollTargetLayout()
            .padding(.horizontal)
        }
        // Declarative replacement for `ScrollViewReader { proxy.scrollTo(...) }`.
        // Writing to `scrolledMessageId` scrolls; the binding also updates as
        // the user scrolls manually.
        .scrollPosition(id: $scrolledMessageId, anchor: .bottom)
        // Start at the bottom (most recent message) on fresh channel join.
        //
        // `.defaultScrollAnchor(.bottom)` alone doesn't reliably win
        // against `.scrollPosition(id:)` — the combination is finicky and
        // the scroll often starts at the TOP, which then reads as
        // "not at bottom" and pops the jump-to-latest pill immediately.
        //
        // Instead we drive the initial scroll explicitly: on first appear
        // (the chatScrollView only mounts once lines are non-empty, so the
        // backfill is already present), write the last message's id to
        // `scrolledMessageId`. With `anchor: .bottom` that pins the newest
        // message to the viewport bottom. `isAtBottom` is seeded true so
        // the pill never flashes during the initial settle.
        .onAppear {
            scrolledMessageId = chatModel.lines.last?.id
            isAtBottom = true
        }
        // Scroll-edge dissolution under the pinned tab strip — see
        // `chatScrollView` doc-comment above. `.hard` because the tab
        // strip is a pinned accessory; `.top` because that's the edge
        // meeting the chrome.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // Pull-to-dismiss-keyboard: dragging the chat content downward
        // dismisses the keyboard alongside the gesture. Matches Messages /
        // most chat apps.
        .scrollDismissesKeyboard(.interactively)
        // Track whether we're at (near) the bottom using REAL scroll
        // geometry (iOS 18+). More robust than comparing scrolledMessageId
        // to lines.last — that breaks when the last message is taller than
        // the viewport. The transform returns a Bool; `action` fires only
        // when the Bool flips, so this isn't a per-frame cost during a
        // tailing scroll.
        //
        // "Near the bottom" within 44pt absorbs the small offset jitter
        // during rapid appends and means the pill doesn't flicker on at
        // the exact bottom edge.
        .onScrollGeometryChange(for: Bool.self) { geo in
            let distanceFromBottom = geo.contentSize.height
                - geo.contentOffset.y
                - geo.containerSize.height
                + geo.contentInsets.bottom
            return distanceFromBottom <= 44
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        // "tail -f" semantics, now gated on the geometry-derived
        // `isAtBottom` instead of a scrolledMessageId comparison:
        //   - At bottom → auto-snap to the new last message + reset unread.
        //   - Scrolled up → don't snap; tally the new message into the
        //     unread count so the pill can show "N new."
        //
        // No animation on the snap — under burst traffic (50-200 msg/sec
        // during raids) queued animations stutter; instant snap is more
        // legible and at low throughput the missing animation is invisible.
        .onChange(of: chatModel.lines.count) { oldCount, newCount in
            if isAtBottom {
                if let last = chatModel.lines.last {
                    scrolledMessageId = last.id
                }
                unreadWhileScrolledUp = 0
            } else if newCount > oldCount {
                unreadWhileScrolledUp += (newCount - oldCount)
            }
        }
        // Returning to the bottom (manual scroll down, or via the pill)
        // clears the unread tally.
        .onChange(of: isAtBottom) { _, atBottom in
            if atBottom { unreadWhileScrolledUp = 0 }
        }
        // Jump-to-bottom pill. Floats at the bottom of the scroll area
        // (just above the compose bar) whenever the user has scrolled up
        // off the live edge. Tapping snaps to the newest message and
        // resumes tailing.
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                jumpToBottomPill
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isAtBottom)
        // Transient connection indicator floats at the top of the chat area.
        .overlay(alignment: .top) {
            connectionPill
                .padding(.top, 8)
                .animation(.snappy, value: connectionBanner)
        }
        // Drive the pill from connection-state transitions. `previous`/`current`
        // are both `ConnectionState?` (the observed expression is one optional);
        // pass `previous` straight through — the reducer treats nil as "no prior
        // state → no Live-again flash."
        .onChange(of: connectionStatus?.state) { previous, current in
            guard let current else { return }
            connectionBanner = ConnectionBanner.next(previous: previous, current: current)
            liveAgainDismiss?.cancel()
            if connectionBanner == .liveAgain {
                liveAgainDismiss = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    if connectionBanner == .liveAgain { connectionBanner = .hidden }
                }
            }
        }
    }

    /// Transient connection indicator. "Reconnecting…" while the socket is down,
    /// a brief "Live again" on recovery, hidden otherwise. Same quiet glass
    /// capsule as the jump-to-latest pill.
    @ViewBuilder
    private var connectionPill: some View {
        if connectionBanner != .hidden {
            HStack(spacing: 4) {
                Image(systemName: connectionBanner == .liveAgain ? "checkmark" : "wifi.exclamationmark")
                    .font(.caption2.weight(.semibold))
                Text(connectionBanner == .liveAgain ? "Live again" : "Reconnecting…")
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityLabel(connectionBanner == .liveAgain ? "Connection restored" : "Reconnecting")
        }
    }

    /// Floating "jump to latest" pill. Subtle by design — a thin glass
    /// capsule with secondary-grey text so it reads as a quiet hint, not
    /// a call-to-action competing with the chat. Shows an unread count
    /// when messages arrived while scrolled up, else just "Latest".
    @ViewBuilder
    private var jumpToBottomPill: some View {
        Button {
            jumpToLatest()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                if unreadWhileScrolledUp > 0 {
                    // Apple's inflection markdown pluralizes "message"
                    // automatically (1 message / 2 messages).
                    Text("^[\(unreadWhileScrolledUp) new message](inflect: true)")
                        .font(.caption2.weight(.medium))
                } else {
                    Text("Latest")
                        .font(.caption2.weight(.medium))
                }
            }
            // Clear grey type so the pill stays quiet against chat.
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            // Glass capsule (regular, not prominent/tinted) for the
            // subtle floating-hint aesthetic.
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            unreadWhileScrolledUp > 0
                ? "Jump to latest, \(unreadWhileScrolledUp) new messages"
                : "Jump to latest"
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
                highlightKeywords: HighlightSettings.keywords()
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

// MARK: - ComposeBar

/// Bottom-pinned text input + send button for chat. Lives in its own
/// `View` struct so the draft `@State` is isolated from the parent
/// `ChatScreen`'s body — every keystroke mutates `composeText`, and
/// keeping that mutation OUT of ChatScreen prevents the LazyVStack of
/// chat rows from re-evaluating its body on every typed character.
///
/// Communicates with the parent only through:
///   - `onSend`: async callback the parent uses to actually post via
///     `chatModel.send(text:)`. Async-typed so the button can show a
///     disabled state while a send is in flight.
///
/// Single-line by design: Twitch chat doesn't support newlines (the
/// server strips them on receive). Using single-line also means the
/// soft-keyboard's Return key acts as Send (with `.submitLabel(.send)`)
/// instead of inserting a newline glyph — `axis: .vertical` would
/// override `.submitLabel` and force Return to be newline.
private struct ComposeBar: View {
    let channelLoginName: String
    let channelDisplayName: String
    /// When non-nil, the bar shows a "Replying to …" chip above the
    /// field and the next send threads against this parent. Owned by
    /// `TabChatModel.replyContext` upstream — the bar is purely
    /// presentational.
    let replyContext: TabChatModel.ReplyContext?
    /// Channel-wide restrictions to surface above the input (slow mode,
    /// followers-only, etc.). nil before the first chat-settings fetch
    /// completes — same visual as a channel with no restrictions, which
    /// is the common case.
    let chatRestrictions: ChatRestrictions?
    /// Tapped on the chip's X — dismisses the reply attachment without
    /// sending. The parent (`ChatScreen`) calls `chatModel.cancelReply()`.
    let onCancelReply: () -> Void
    /// Fired on every text change so the parent (`ChatScreen`) can
    /// persist the draft to `DraftStorage`. We don't expose @State or
    /// a Binding<String> — that would re-trigger ChatScreen.body on
    /// every keystroke (the typing-lag regression commit 2 fixed).
    /// Instead the bar owns its @State internally and notifies via
    /// callback, which doesn't propagate as a dependency change.
    let onDraftChange: (String) -> Void
    /// Builds the emote-picker sections on demand (when the emote button
    /// is tapped) so we don't recompute them on every body eval.
    let emoteSectionsProvider: () -> [EmoteSection]
    let onSend: @MainActor (String) async -> Void

    @State private var composeText: String
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    /// Picker presentation + its snapshot of sections (captured when the
    /// emote button is tapped, so the grid is stable while open).
    @State private var showingEmotePicker = false
    @State private var pickerSections: [EmoteSection] = []

    /// Custom init that seeds `composeText`'s @State with the persisted
    /// draft. SwiftUI's `@State` semantics ensure the seed value is
    /// only used at first mount for a given view identity — subsequent
    /// re-renders ignore the seed and keep whatever the user typed.
    /// This gives us "load on first mount, never clobber typing"
    /// without a Binding.
    init(
        channelLoginName: String,
        channelDisplayName: String,
        replyContext: TabChatModel.ReplyContext?,
        chatRestrictions: ChatRestrictions?,
        seedDraft: String,
        onCancelReply: @escaping () -> Void,
        onDraftChange: @escaping (String) -> Void,
        emoteSectionsProvider: @escaping () -> [EmoteSection],
        onSend: @escaping @MainActor (String) async -> Void
    ) {
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        self.replyContext = replyContext
        self.chatRestrictions = chatRestrictions
        self.onCancelReply = onCancelReply
        self.onDraftChange = onDraftChange
        self.emoteSectionsProvider = emoteSectionsProvider
        self.onSend = onSend
        self._composeText = State(initialValue: seedDraft)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let restrictions = chatRestrictions, restrictions.hasAny {
                restrictionsStrip(restrictions)
            }

            if let reply = replyContext {
                replyChip(reply)
            }

            inputRow
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Animate the chip's appearance/disappearance. We trigger on
        // `replyContext != nil` (not the full context value) because
        // we only want the animation on chip appear/disappear, NOT on
        // mid-compose target switches (long-press another message to
        // reply to it instead). The chip's content updates in place
        // without an animation — which feels right for "I changed my
        // mind about who to reply to."
        //
        // `ReplyContext` is fully `Equatable` (all stored fields are
        // String), so we could use `value: replyContext` if we wanted
        // the chip to animate when the target changes. Not chosen
        // today — feels jumpier.
        .animation(.snappy(duration: 0.2), value: replyContext != nil)
        // Emote picker. Stays open while you tap (so you can stack
        // several emotes); inserts each emote's name into the composer.
        .sheet(isPresented: $showingEmotePicker) {
            EmotePickerView(sections: pickerSections) { name in
                insertEmote(name)
            }
        }
    }

    /// Append a tapped emote's name to the draft, ensuring a single
    /// space separates it from prior text (and a trailing space so the
    /// next token / emote doesn't fuse to it). Chat emotes are
    /// whitespace-delimited tokens, so the spacing is load-bearing —
    /// "KappaPride" is a different (or non-existent) emote vs
    /// "Kappa Pride".
    private func insertEmote(_ name: String) {
        if composeText.isEmpty || composeText.hasSuffix(" ") {
            composeText += "\(name) "
        } else {
            composeText += " \(name) "
        }
        // onChange(of: composeText) fires from the mutation above, so
        // the draft persists automatically — no explicit onDraftChange
        // call needed here.
    }

    /// Inline informational strip above the input, listing chat
    /// restrictions that affect what the user can send (slow mode,
    /// followers-only, etc.). Non-blocking — the send button stays
    /// enabled, and if the user fails the restriction (e.g. not yet
    /// following), Twitch's `dropReason` surfaces on the failed row.
    ///
    /// Why informational not blocking: pre-flighting "is the user
    /// following / subscribed" requires per-user API calls and produces
    /// the same outcome as letting Twitch tell us via dropReason. The
    /// strip is just a heads-up so users don't get a surprise rejection.
    @ViewBuilder
    private func restrictionsStrip(_ r: ChatRestrictions) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(restrictionsLabel(r))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    /// Build a human-readable comma-joined label of the active
    /// restrictions. Each phrase is short enough to coexist on one line
    /// of caption2 when the channel has 1-2 restrictions; with 3+ the
    /// strip allows up to 2 lines of wrap.
    private func restrictionsLabel(_ r: ChatRestrictions) -> String {
        var parts: [String] = []
        if let secs = r.slowModeSeconds {
            parts.append("Slow mode: \(secs)s")
        }
        if r.followersOnly {
            if let mins = r.followersDurationMinutes, mins > 0 {
                // Render "30m" / "1h" / "1d" for readability — Twitch's
                // duration is in minutes which gets unwieldy at high
                // values ("43800 minutes").
                parts.append("Followers only (\(Self.formatMinutes(mins)))")
            } else {
                parts.append("Followers only")
            }
        }
        if r.subscribersOnly {
            parts.append("Subscribers only")
        }
        if r.emoteOnly {
            parts.append("Emote only")
        }
        return parts.joined(separator: " · ")
    }

    /// Format a follower-mode duration in the most natural unit:
    /// minutes for <60, hours for <24h, days otherwise.
    private static func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }

    /// "Replying to @author: snippet" chip with an X button. Tinted
    /// with the accent color at low opacity so it reads as informative,
    /// not alarming. Uses `arrowshape.turn.up.left.fill` to mirror the
    /// long-press menu icon — visual continuity between "I chose
    /// Reply" and "I'm now in reply mode."
    @ViewBuilder
    private func replyChip(_ reply: TabChatModel.ReplyContext) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(reply.parentAuthorDisplayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(reply.parentSnippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Button {
                onCancelReply()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.12))
        )
        // Subtle transition so the chip appearing isn't jarring.
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// Placeholder text — switches to "Reply to @author" when a reply
    /// is attached so the user has a second visual cue (beyond the
    /// chip) that their next send will be threaded.
    private var textFieldPrompt: String {
        if let reply = replyContext {
            return "Reply to \(reply.parentAuthorDisplayName)"
        }
        return "Send a message in #\(channelLoginName)"
    }

    /// True when the send button represents a meaningful action: the
    /// draft has at least one non-whitespace character AND we're not
    /// already mid-send. Drives both the tinting (accent vs muted)
    /// AND the `.disabled(!isActive)` modifier so a single source of
    /// truth governs both visual + behavior.
    private var isActive: Bool {
        !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// The TextField + Send button row, pulled out of the body for
    /// readability now that the reply chip is also a sibling.
    @ViewBuilder
    private var inputRow: some View {
        HStack(spacing: 8) {
            // Emote-picker button. Snapshots the sections (built on
            // demand) and presents the grid sheet. Glass circle to match
            // the send button's chrome.
            Button {
                pickerSections = emoteSectionsProvider()
                showingEmotePicker = true
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 17, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .padding(2)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Emotes")

            TextField(textFieldPrompt, text: $composeText)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { Task { await sendDraft() } }
                // Forward every text change to the parent so it can
                // persist via DraftStorage. UserDefaults batches writes
                // so per-keystroke saves don't actually hit disk on
                // every call — observed throughput is roughly the same
                // as a debounced save without the .task(id:) sleep.
                .onChange(of: composeText) { _, newValue in
                    onDraftChange(newValue)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Regular glass (not interactive) — typing happens inside
                // the field, no glass-on-press animation needed.
                .glassEffect(.regular, in: Capsule())
                .accessibilityLabel("Message input")
                .accessibilityHint("Type a chat message to send to \(channelDisplayName)")

            Button {
                Task { await sendDraft() }
            } label: {
                // Symbol effect `.bounce` fires when `isActive` toggles
                // — gives the user a satisfying micro-interaction the
                // first time they type a character. Reduce-Motion users
                // get no animation (SF Symbols respect the system
                // setting automatically). The button stays interactive
                // either way.
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: isActive)
                    .padding(2)
            }
            // Style switch: `.glassProminent` when the draft is
            // meaningful, plain `.glass` otherwise. Per axiom-design's
            // Liquid Glass guidance: "Use `.tint()` only to convey
            // meaning (call to action, next step), not for decoration."
            // The tint is the call-to-action signal — empty draft → no
            // signal, populated draft → "this action is now meaningful."
            //
            // SwiftUI's conditional buttonStyle creates a fresh button
            // identity per branch, which would normally retrigger the
            // symbol effect on every keystroke. Pulling the active flag
            // out into a computed property + using `.tint()` (which
            // doesn't reset identity) avoids that — `.tint(.accentColor)`
            // when active, no tint when not.
            .buttonStyle(.glassProminent)
            .tint(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
            .disabled(!isActive)
            .accessibilityLabel("Send message")
        }
        // No padding modifiers here — the outer VStack in `body` owns
        // the horizontal + vertical padding for the whole compose bar
        // including the reply chip.
    }

    private func sendDraft() async {
        let draft = composeText
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isSending else { return }

        isSending = true
        defer { isSending = false }

        // Optimistic clear — the message immediately appears in chat as an
        // optimistic row via chatModel.send, so leaving the bar populated
        // would feel like the message is still in flight.
        composeText = ""

        await onSend(draft)
    }
}

// MARK: - Thread sheet

/// `.sheet(item:)` requires its value-type to be `Identifiable`. We
/// wrap the thread root id String so we can pass it through
/// `@State viewingThreadRootId: ThreadRootID?`.
private struct ThreadRootID: Identifiable, Equatable {
    let id: String
}

/// Modal sheet that filters chat to a single thread and offers a
/// dedicated compose bar that automatically threads against the
/// thread's latest message. Reuses `ChatRow` and `ComposeBar` for
/// visual consistency with the main chat.
///
/// Design choices:
///   - Lives in a NavigationStack with a Done button so the sheet
///     reads as a deliberate modal (not a swipe-down popover).
///   - Compose bar always threads — `replyOverride` is built from
///     the latest line in the thread, so the user doesn't need to
///     manually pick a parent for each send.
///   - Long-press inside the thread sheet does NOT offer "View
///     Thread" again (would be a no-op — we're already in it).
///   - "Reply" inside the thread sheet sets the model's reply
///     context to that specific line, then the compose bar's
///     replyOverride is preempted by it. Slightly confusing to have
///     two sources of reply intent — for MVP we just NOT offer Reply
///     inside the thread sheet either (threading is automatic, no
///     need for explicit "Reply").
///
/// Future polish (not in this commit):
///   - Scroll to the most recent message on open.
///   - Inline "View profile" / "Mention" actions on rows.
///   - Persisted scroll position so re-opening the sheet returns to
///     where you were reading.
private struct ThreadView: View {
    @Environment(\.dismiss) private var dismiss

    let rootMessageId: String
    // Audit fix (axiom MEDIUM): was `@Bindable var chatModel` but no
    // bindings are created from it. @Observable references don't need
    // any wrapper to be observed — `let` is correct since ThreadView
    // never reassigns it, and dropping @Bindable removes the false
    // "this view uses bindings" signal.
    let chatModel: TabChatModel
    let badgeStore: ChatBadgeStore?
    let channelLoginName: String
    let channelDisplayName: String

    var body: some View {
        // Audit fix (axiom LOW): compute the filter result ONCE per body
        // and reuse it for both `ForEach` and the reply-target factory.
        // Previously each body call evaluated `lines(inThreadRootedAt:)`
        // twice (via the `threadLines` and `threadReplyTarget`
        // computed properties).
        let threadLines = chatModel.lines(inThreadRootedAt: rootMessageId)
        // Reply target for the thread compose bar — latest message in
        // the thread, built via the centralized factory so it matches
        // the main compose bar's reply chip formatting exactly.
        let threadReplyTarget: TabChatModel.ReplyContext? = threadLines.last.map {
            TabChatModel.replyContext(for: $0)
        }
        NavigationStack {
            VStack(spacing: 0) {
                if threadLines.isEmpty {
                    ContentUnavailableView(
                        "Thread not found",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("The original message may have aged out of the buffer.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(threadLines) { line in
                                ChatRow(
                                    line: line,
                                    badgeEntries: badgeStore?.entries(for: line.originalBadges) ?? []
                                    // Note: deliberately no onRetry /
                                    // onReply / onViewThread inside the
                                    // thread sheet. Reply is implicit
                                    // (the compose bar threads
                                    // automatically); recursive
                                    // View Thread would be a no-op;
                                    // retry on optimistic rows still
                                    // works from the main chat view.
                                )
                                .id(line.id)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    // Open at the most recent message instead of the
                    // root. Threads grow over time and the conversation
                    // context the user wants is at the bottom — opening
                    // at the top would require manual scrolling every
                    // time. `.defaultScrollAnchor(.bottom)` (iOS 17+)
                    // only affects the INITIAL anchor; subsequent
                    // scrolling behaves normally, so the user can swipe
                    // up to read the thread's history without fighting
                    // any auto-snap.
                    .defaultScrollAnchor(.bottom)
                }

                // Dedicated compose bar. The replyOverride is built
                // from `threadReplyTarget` — automatic threading
                // against the latest message in the thread, which is
                // what feels natural for "continue this conversation."
                ThreadComposeBar(
                    channelLoginName: channelLoginName,
                    channelDisplayName: channelDisplayName,
                    replyTarget: threadReplyTarget,
                    onSend: { draft in
                        await chatModel.send(
                            text: draft,
                            replyOverride: threadReplyTarget
                        )
                    }
                )
            }
            .navigationTitle("Thread")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // `confirmationAction` placement → right side on iOS.
                // "Done" rather than "Cancel" because closing this
                // sheet isn't destructive — no input is being
                // abandoned, the user just finished reading.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Compose bar variant for the thread sheet. Same look as the main
/// ComposeBar but without the reply chip (threading is automatic and
/// always-on, so the chip would be redundant) and without the
/// restrictions strip (the user already saw it on the main bar).
///
/// Pulled out as a separate struct rather than reusing ComposeBar
/// because (a) ComposeBar's reply chip + restrictions strip + cancel
/// button machinery is dead weight here, and (b) the placeholder
/// text needs to read "Reply in thread" instead of "Send a message"
/// — switching ComposeBar to parameterize that one prompt seemed
/// less clean than a focused thread-specific variant.
private struct ThreadComposeBar: View {
    let channelLoginName: String
    let channelDisplayName: String
    let replyTarget: TabChatModel.ReplyContext?
    let onSend: @MainActor (String) async -> Void

    @State private var composeText: String = ""
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    private var isActive: Bool {
        !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private var prompt: String {
        if let target = replyTarget {
            return "Reply to \(target.parentAuthorDisplayName)"
        }
        return "Send to #\(channelLoginName)"
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(prompt, text: $composeText)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { Task { await sendDraft() } }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .accessibilityLabel("Reply input")
                .accessibilityHint("Type a reply to send to \(channelDisplayName)")

            Button {
                Task { await sendDraft() }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: isActive)
                    .padding(2)
            }
            .buttonStyle(.glassProminent)
            .tint(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
            .disabled(!isActive)
            .accessibilityLabel("Send reply")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sendDraft() async {
        let draft = composeText
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        composeText = ""
        await onSend(draft)
    }
}
