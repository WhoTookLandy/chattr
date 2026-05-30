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

    /// Currently-scrolled message id. Used by the auto-scroll-to-bottom logic
    /// via `.scrollPosition(id:)`. Writing to this binding scrolls the view;
    /// the binding also updates as the user scrolls manually (iOS 17+ API).
    @State private var scrolledMessageId: String?

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

            ComposeBar(
                channelLoginName: channelLoginName,
                channelDisplayName: channelDisplayName,
                replyContext: chatModel.replyContext,
                chatRestrictions: chatModel.chatRestrictions,
                // Load the persisted draft synchronously here in body.
                // UserDefaults reads are fast + iOS caches them, so
                // doing this on every body re-eval is cheap. The seed
                // only matters at first mount thanks to @State
                // semantics; subsequent re-evals pass new seeds but
                // they're ignored once @State is established.
                seedDraft: DraftStorage.load(forChannelId: channelId),
                onCancelReply: { chatModel.cancelReply() },
                // Persist on every keystroke. The user's drafts survive:
                //   - swiping to another channel-tab and back (the
                //     paged ScrollView unmounts/remounts ChatScreen on
                //     swipe; UserDefaults bridges that gap)
                //   - quitting and relaunching the app (UserDefaults is
                //     plist-backed and survives cold start)
                //   - the user's draft is cleared on successful send
                //     by `chatModel.send` via DraftStorage.clear
                onDraftChange: { newDraft in
                    DraftStorage.save(forChannelId: channelId, text: newDraft)
                },
                onSend: { draft in await chatModel.send(text: draft) }
            )
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
        .alert("Couldn't send", isPresented: Binding(
            get: { chatModel.sendError != nil },
            set: { isPresented in if !isPresented { chatModel.clearSendError() } }
        ), presenting: chatModel.sendError) { _ in
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
        .task { await startSession() }
        .task {
            guard let store = badgeStore else { return }
            let cachedGlobalBadges = globalCatalog?.globalBadges ?? [:]
            await store.load(
                account: account,
                accountStore: accountStore,
                channelId: channelId,
                globalBadges: cachedGlobalBadges
            )
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
        // Detach pub-sub subscriptions when the view leaves the screen. The
        // underlying ChannelSession stays alive in the registry; this just
        // tears down THIS view's subscription. The Task captures `chatModel`
        // so the model survives long enough to complete detach() even after
        // SwiftUI releases its @State storage.
        .onDisappear {
            let model = chatModel
            Task { @MainActor in
                await model.detach()
            }
        }
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
    private var chatScrollView: some View {
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
                        }
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
        // the user scrolls manually, opening the door to "snap to bottom only
        // when already at bottom" UX later without changing today's behavior.
        .scrollPosition(id: $scrolledMessageId, anchor: .bottom)
        // Scroll-edge dissolution under the pinned tab strip — see
        // `chatScrollView` doc-comment above. `.hard` because the tab
        // strip is a pinned accessory; `.top` because that's the edge
        // meeting the chrome.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // Pull-to-dismiss-keyboard: dragging the chat content downward
        // dismisses the keyboard alongside the gesture. Matches Messages /
        // most chat apps. Without this the only way to dismiss the
        // keyboard is to send the message (which often you don't want to
        // do — sometimes you just want to read while typing was a
        // mistake). The compose bar's TextField stays focused if you
        // pull only partially.
        .scrollDismissesKeyboard(.interactively)
        // "tail -f" semantics for chat scroll:
        //
        //   - If the user is at the bottom of the feed (scroll position is
        //     on the previous-last message, or scroll is unset), auto-snap
        //     to the new last message.
        //   - If the user has scrolled UP to read history (scroll position
        //     is on some earlier message), DO NOT snap them down. They're
        //     reading; respect that.
        //
        // We also drop the 0.1s easeOut animation entirely. Under burst
        // traffic (50-200 msgs/sec during raid storms), each animation
        // requires 100ms but new messages arrive every 5-20ms — SwiftUI
        // queues animation requests faster than it drains them, creating
        // visible stutter. Instant snap is more legible at high throughput,
        // and at low throughput the snap is so small the missing animation
        // is invisible.
        .onChange(of: chatModel.lines.count) { _, _ in
            guard let last = chatModel.lines.last else { return }
            // Determine if user was at the bottom *before* this append.
            // The new last is `last`; the previous last is the
            // second-to-last in the current array. If `scrolledMessageId`
            // matches that, we were tailing. nil means "no scroll yet"
            // — treat as at-bottom so the first messages trigger scroll.
            let previousLast = chatModel.lines.dropLast().last
            let wasTailing = scrolledMessageId == nil
                || scrolledMessageId == previousLast?.id
            if wasTailing {
                scrolledMessageId = last.id
            }
        }
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
                highlightKeywords: []   // No user-configurable highlights yet.
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
    let onSend: @MainActor (String) async -> Void

    @State private var composeText: String
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

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
        onSend: @escaping @MainActor (String) async -> Void
    ) {
        self.channelLoginName = channelLoginName
        self.channelDisplayName = channelDisplayName
        self.replyContext = replyContext
        self.chatRestrictions = chatRestrictions
        self.onCancelReply = onCancelReply
        self.onDraftChange = onDraftChange
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
        // Animate the chip's appearance/disappearance. `.animation`
        // observing `replyContext != nil` (rather than `replyContext`
        // itself, which isn't Equatable via @Observable's tracking
        // model) keeps the animation triggered by chip-presence
        // toggling, not by every property change inside the context.
        .animation(.snappy(duration: 0.2), value: replyContext != nil)
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
    @Bindable var chatModel: TabChatModel
    let badgeStore: ChatBadgeStore?
    let channelLoginName: String
    let channelDisplayName: String

    /// The full filtered thread, recomputed each body call. Cheap —
    /// see `TabChatModel.lines(inThreadRootedAt:)` doc-comment.
    private var threadLines: [ChatLine] {
        chatModel.lines(inThreadRootedAt: rootMessageId)
    }

    /// The reply target for the thread's compose bar — last message
    /// in the thread (chronological), or the root if the thread is
    /// just the seed.
    private var threadReplyTarget: TabChatModel.ReplyContext? {
        guard let lastLine = threadLines.last else { return nil }
        // Build the override context. The snippet is the line's
        // already-normalized runs collapsed to text; we use the same
        // formatter the main reply chip uses for visual consistency.
        // Borrowing the formatter from TabChatModel would need a
        // public exposure; for the MVP we render runs inline-ish.
        let snippet: String = {
            var out = ""
            for run in lastLine.runs {
                switch run {
                case .text(let s): out += s
                case .emote(let e): out += e.name
                case .twitchEmote(_, let display): out += display
                case .mention(let login, _): out += "@\(login)"
                case .url(let s): out += s
                case .cheermote(let prefix, let bits, _): out += "\(prefix)\(bits)"
                }
                if out.count >= 80 { break }
            }
            return out.count > 80 ? String(out.prefix(80)) + "…" : out
        }()
        return TabChatModel.ReplyContext(
            parentMessageId: lastLine.id,
            parentAuthorDisplayName: lastLine.authorDisplayName,
            parentSnippet: snippet
        )
    }

    var body: some View {
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
