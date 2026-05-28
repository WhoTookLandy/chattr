import SwiftUI
import Accounts
import Channels
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
                        onRetry: { Task { await chatModel.retry(failedLineId: line.id) } }
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
    let onSend: @MainActor (String) async -> Void

    @State private var composeText: String = ""
    @State private var isSending: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Send a message in #\(channelLoginName)", text: $composeText)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { Task { await sendDraft() } }
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
                // No explicit `.frame(...)` — `.buttonStyle(.glass)`
                // sizes the glass capsule to its content + its own
                // internal padding. The hardcoded 36×36 frame in the
                // previous version added on top of that padding, making
                // the button look bulky next to the field. The 17pt
                // font + .padding(2) here lands at a button that
                // matches the field's vertical rhythm.
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .padding(2)
            }
            .buttonStyle(.glass)
            .disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .accessibilityLabel("Send message")
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

        // Optimistic clear — the message immediately appears in chat as an
        // optimistic row via chatModel.send, so leaving the bar populated
        // would feel like the message is still in flight.
        composeText = ""

        await onSend(draft)
    }
}
