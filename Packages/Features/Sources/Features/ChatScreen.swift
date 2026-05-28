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

    /// Per-channel badge cache. Reset implicitly when the screen pushes a new
    /// instance — each NavigationLink push creates a fresh `@State` so old
    /// channel badges don't bleed into a different broadcaster's chat.
    @State private var badgeStore = ChatBadgeStore()

    /// Per-channel third-party emote index (7TV / BTTV / FFZ). Same lifetime
    /// pattern as `badgeStore` — created fresh per `ChatScreen` instance,
    /// loaded in a sibling `.task` (see below). When Phase 2.3 Task 11
    /// lands, ownership moves into `ChannelSession` (which has the right
    /// lifetime — survives view-tree churn); until then we tolerate the
    /// reload-on-swipe cost.
    @State private var emoteIndex = EmoteIndex()

    /// Currently-scrolled message id. Used by the auto-scroll-to-bottom logic
    /// via `.scrollPosition(id:)`. Writing to this binding scrolls the view;
    /// the binding also updates as the user scrolls manually (iOS 17+ API).
    @State private var scrolledMessageId: String?

    /// When true, the user has Reduce Motion on in system Accessibility — we
    /// skip the easeOut tween on auto-scroll so chat snaps instantly to the
    /// newest message instead of animating.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // No `.navigationTitle` here — the parent ChatTabsScreen sets it to
        // "Chat" and the active tab pill in the strip already identifies the
        // channel. Having ChatScreen also override the title to "#login"
        // would just duplicate the information already shown one row below.
        // Two structured tasks. Both are bound to this view's lifetime —
        // SwiftUI cancels them on tear-down (incl. when ChatTabsScreen swaps
        // the active channel via `.id(...)`).
        //
        // Splitting badge-load into its own .task means the session connect
        // and the badge fetch run in parallel, AND we don't leak an
        // unstructured Task per channel switch (the previous code spawned
        // `Task { await badgeStore.load(...) }` inside startSession, which
        // outlived the view).
        .task { await startSession() }
        .task {
            let cachedGlobalBadges = globalCatalog?.globalBadges ?? [:]
            await badgeStore.load(
                account: account,
                accountStore: accountStore,
                channelId: channelId,
                globalBadges: cachedGlobalBadges
            )
        }
        // Load 7TV / BTTV / FFZ emote definitions for this channel.
        //
        // ## Why `.onAppear { Task { ... } }` not `.task { ... }`
        //
        // `.task` cancels its body when the view "disappears" — including
        // transient identity flickers during SwiftUI re-renders (e.g., when
        // openChannel triggers `chatTabsModel.open + selectedTab = .chat`
        // back-to-back, the paged-ScrollView LazyHStack briefly re-evaluates
        // children, and ChatScreen's task identity drops mid-flight).
        //
        // Observed symptom (before this fix): all 6 emote provider calls
        // (3 globals + 3 channel-specifics) threw `URLError(.cancelled)`
        // within the first frame of channel-open, leaving the EmoteIndex
        // populated with 0 emotes and chat rendering all third-party emote
        // names as plain text.
        //
        // Unstructured `Task { ... }` started in `.onAppear` isn't bound to
        // view lifetime — view tear-downs don't cancel its HTTP work. The
        // Task captures `emoteIndex` (an actor, Sendable) strongly, so
        // even if @State releases it on permanent view tear-down, the
        // load completes and the actor deallocates cleanly afterward.
        //
        // Idempotency: if `.onAppear` fires multiple times (visibility
        // transitions), each call starts another load. EmoteIndex.load
        // is last-write-wins on the snapshot, so duplicate loads waste
        // HTTP but don't corrupt state. Phase 2.3 Task 11 moves the
        // EmoteIndex into ChannelSession (actor-owned, session-lifetime)
        // which eliminates this entirely.
        .onAppear {
            Task {
                // Signpost-bracket the emote load so Instruments shows the
                // duration as a "Points of Interest" interval. If the Task
                // gets cancelled or interrupted, the interval shows up
                // truncated — visual proof of where the race happened.
                let id = signposter.makeSignpostID()
                let state = signposter.beginInterval(
                    "emote-load",
                    id: id,
                    "channel=\(channelLoginName)"
                )
                await emoteIndex.load(
                    broadcasterId: channelId,
                    broadcasterLogin: channelLoginName
                )
                let count = emoteIndex.snapshot().count
                signposter.endInterval("emote-load", state, "count=\(count)")
                logger.info("EmoteIndex loaded for #\(channelLoginName, privacy: .public): \(count) emotes")
            }
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
    @ViewBuilder
    private var chatScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(chatModel.lines) { line in
                    ChatRow(
                        line: line,
                        badgeEntries: badgeStore.entries(for: line.originalBadges)
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
        .onChange(of: chatModel.lines.count) { _, _ in
            guard let last = chatModel.lines.last else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
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
                account: account,
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
            await chatModel.attach(
                sessions: [session],
                emoteIndex: emoteIndex,
                currentUserLogin: account.login,
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
