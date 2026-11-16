import Foundation
import Observation   // for @Observable — pulled from Observation rather than SwiftUI
                     // so this model has no SwiftUI dependency, matching its actual surface
import TwitchKit
import Channels
import ChatModel
import EmoteSources
import Core
import os

private let logger = AppLogger.make("Features.ChatTranscriptModel")

/// Per-tab message store. Subscribes to one or more `ChannelSession`s and
/// surfaces a unified, observable `lines` array for `ChatScreen` to render.
///
/// MVP (1 channel per tab): `attach(sessions: [one])` subscribes to a single
/// session. New messages from that session's pub-sub stream append to `lines`.
///
/// Future (N channels per tab): `attach(sessions: [a, b, c])` subscribes to
/// all of them. Incoming messages append into the same `lines` array in
/// arrival order. For chronological ordering across channels we'd need to
/// merge-sort by timestamp on each append — TODO once multi-channel ships.
///
/// Lifecycle:
///   - `attach(sessions:)`: register subscriber on each session; prime `lines`
///     from each session's current snapshot atomically with subscription.
///   - `detach()`: unregister all subscribers; sessions stay alive in the
///     registry (other tabs may reference them, ref counting in Phase E).
///   - `deinit`: nothing to clean up — `detach()` is the explicit teardown,
///     called by `ChatScreen.onDisappear`.
///
/// Why `@MainActor`: the observed publish surface (`changeVersion`, `isEmpty`,
/// …) drives SwiftUI body recomputes. Mutating from any other actor would
/// either need explicit MainActor hops everywhere or trip Swift 6's data-race
/// checks. @MainActor keeps everything simple at the cost of one actor hop per
/// inbound message. A raid pushes 100+ messages/sec, so that hop does only
/// the O(1) buffer mutation; publishing is coalesced to at most one flush per
/// `coalescingWindow` (~one frame) — see "Coalesced change channel" below.
@MainActor
@Observable
public final class ChatTranscriptModel {

    /// Three-state attach lifecycle for ChatScreen's empty-state UI.
    /// `Equatable` so the `@Observable` macro's generated setter can
    /// short-circuit invalidation when the same state is re-assigned —
    /// without it every set notifies observers, equal value or not.
    public enum AttachState: Sendable, Equatable {
        case detached    // no sessions registered
        case attaching   // attach in flight
        case attached    // all subscriptions live
    }

    /// Sliding-window store of every received line (the dedup/echo source of
    /// truth) plus the incrementally-maintained, block-filtered projection the
    /// view renders. Replaces the old `allLines` array + per-message
    /// `BlockFilter.apply` full rescan + `Array.removeFirst` trim — see
    /// `ChatBuffer` for the cost rationale. Cap = 500 retained lines per tab
    /// by default (the Chat History setting overrides it at attach).
    ///
    /// `@ObservationIgnored`: it's a value type mutated on EVERY inbound
    /// message (and by every drain, even an empty one), so leaving it observed
    /// invalidated any body that had ever read through it at message rate.
    /// Views observe the explicit, coalesced surface instead — `changeVersion`
    /// (one bump per flush) and `isEmpty` (flips only).
    @ObservationIgnored private var buffer = ChatBuffer(cap: 500)

    /// Block-filtered, display-ready lines — the live buffer state, which can
    /// run up to one coalescing window ahead of the last flush. Reading it
    /// registers a dependency on `changeVersion`, so a body that renders
    /// `lines` directly (the non-UIKit fallback list) re-evaluates once per
    /// flush. The UIKit list never reads this: it pulls `changes(since:)` and
    /// resets from `transcriptSnapshot()` only when it must.
    public var lines: [ChatLine] {
        _ = changeVersion
        return buffer.lines
    }

    /// True when there are no visible lines — drives `ChatTranscript`'s empty
    /// state. Stored rather than derived from the (observation-ignored)
    /// buffer, so observers are invalidated only when it actually flips; kept
    /// current synchronously by `publishPending()`, so the list mounts the
    /// moment the first line lands rather than a flush later. Counts the
    /// *visible* (block-filtered) projection, matching what the transcript
    /// renders. Internal: only consumed inside the Features module.
    private(set) var isEmpty = true

    // MARK: - Coalesced change channel
    //
    // Instead of re-publishing the whole `lines` array every message and making
    // the view re-diff it, the model publishes typed `[ChatChange]` batches the
    // view applies directly:
    //
    //   1. Every buffer mutation calls `publishPending()`. The first one after a
    //      flush schedules a single main-actor flush `coalescingWindow` later;
    //      the rest inside the window just accumulate in the buffer.
    //   2. The flush seals everything pending into `changeLog` as ONE versioned
    //      batch and sets `changeVersion` (the only observed trigger) to the
    //      log head. A 100 msg/s firehose costs ~one publish per frame, not
    //      one per message.
    //   3. Readers never assume they saw every publish (SwiftUI coalesces
    //      invalidations). Each keeps the last version it consumed and pulls
    //      `changes(since:)`, which replays EVERY batch after it; only a reader
    //      whose next batch was evicted from the bounded log resets from
    //      `transcriptSnapshot()`.
    //
    // Reader pulls seal pending changes too (touching only ignored state), so
    // a snapshot's lines always correspond exactly to its version.

    /// How long the first mutation after a flush waits before publishing —
    /// about one 60 Hz frame. Mutations inside the window ride along.
    static let coalescingWindow: Duration = .milliseconds(15)

    /// Published batches by version. Observation-ignored: readers pull from it
    /// inside their own update, which must not invalidate anything.
    @ObservationIgnored private var changeLog = ChatChangeLog()

    /// True while a flush is scheduled — collapses every mutation inside the
    /// coalescing window onto that one flush.
    @ObservationIgnored private var flushScheduled = false

    /// Log head as of the last flush — the only observed trigger for the
    /// change channel. Moves at most once per flush; readers treat a move as
    /// "pull `changes(since:)`", never as "exactly one batch happened".
    private(set) var changeVersion: Int = 0

    /// Call after any buffer mutation: refreshes `isEmpty` and schedules the
    /// coalesced flush. Cheap — beyond the O(1) empty check it does nothing
    /// while a flush is already pending. Because the buffer *accumulates*
    /// until a flush or a reader pull seals it, nothing is lost between calls.
    private func publishPending() {
        let empty = buffer.visibleCount == 0
        if empty != isEmpty { isEmpty = empty }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalescingWindow)
            self?.flushPendingChanges()
        }
    }

    /// Seals pending buffer changes into the log and publishes the new head.
    /// Normally run by the task `publishPending()` schedules; internal so
    /// tests can flush deterministically instead of sleeping.
    func flushPendingChanges() {
        flushScheduled = false
        let head = sealPendingChanges()
        if changeVersion != head { changeVersion = head }
    }

    /// Moves the buffer's undrained changes into the log as one batch and
    /// returns the log head; afterwards `buffer.lines` is exactly the state at
    /// that version. Touches only observation-ignored state, so readers may
    /// call it from inside a view update.
    @discardableResult
    private func sealPendingChanges() -> Int {
        let changes = buffer.takeChanges()
        if !changes.isEmpty { changeLog.append(changes) }
        return changeLog.headVersion
    }

    /// Every change published after `version`, flattened in order, or
    /// `.overrun` when `version` predates the retained log (the reader must
    /// reset from `transcriptSnapshot()`). Seals pending changes first, so the
    /// reader is never behind the buffer. Observation-free: safe to call from
    /// `updateUIViewController`, `onChange`, or a scroll callback.
    func changes(since version: Int) -> ChatChangeLog.Delta {
        sealPendingChanges()
        return changeLog.changes(since: version)
    }

    /// The visible lines plus the exact log version they reflect. A reader
    /// that resets from this and then pulls `changes(since: version)` sees
    /// every later change exactly once. O(visible) — reset path only.
    func transcriptSnapshot() -> (version: Int, lines: [ChatLine]) {
        let version = sealPendingChanges()
        return (version, buffer.lines)
    }

    /// Blocked user ids, pushed in by the view (which observes BlockStore).
    /// Changing it re-filters the visible projection immediately. The
    /// no-op-when-unchanged guard lives inside `ChatBuffer.blockedIds`.
    public var blockedIds: Set<String> {
        get { buffer.blockedIds }
        set { buffer.blockedIds = newValue; publishPending() }
    }

    public private(set) var attachState: AttachState = .detached

    /// Active subscription tokens, paired with the sessions they belong to.
    /// Stored as tuples (not a dict) because order doesn't matter and we
    /// always operate on all of them together.
    private var subscriptions: [(session: ChannelSession, token: UUID)] = []

    // MARK: - Normalization state
    //
    // These are set at attach() time and consulted on every append(). They
    // live on the model so the per-message handler doesn't need them
    // captured in a closure — keeps the subscriber callback tight.

    /// EmoteIndex for resolving third-party emote names. Held weakly... well,
    /// strongly — an actor is a reference type, but Sendable, so this is
    /// safe to capture inside the @MainActor model. Reading
    /// `index.snapshot()` is nonisolated (lock-protected internally) so
    /// the hot append path doesn't need an actor hop.
    ///
    /// Nullable so the model is constructible without an index (tests + the
    /// brief pre-attach window). When nil, all tokens stay as plain text —
    /// the renderer degrades gracefully to "no third-party emotes."
    private var emoteIndex: EmoteIndex?

    /// The signed-in user's lowercase login. Used to mark self-mentions
    /// for highlighting. Empty by default — no message highlights as
    /// "@me" until set.
    private var currentUserLogin: String = ""

    /// The signed-in user's Twitch user ID. Used to recognize our own
    /// messages in the EventSub echo stream so we can swap optimistic
    /// rows into the canonical echoed row (see `send` / `apply` for
    /// the orchestration). Empty before attach.
    private var currentUserId: String = ""

    /// The signed-in user's display name (capitalized as the user picked
    /// at signup). Stamped onto the optimistic line so the row looks
    /// right BEFORE the EventSub echo arrives and rewrites it with
    /// Twitch's authoritative payload.
    private var currentUserDisplayName: String = ""

    /// The signed-in user's chat name color ("#FF69B4"), stamped onto
    /// optimistic send rows so they render in the right color
    /// immediately instead of flashing plain for the ~0.5s echo
    /// round-trip. Seeded from GET /chat/color at attach (fire-and-
    /// forget), then kept fresh from each echoed own-message — the echo
    /// value wins because it reflects mid-session color changes.
    private var selfColor: String = ""

    /// The signed-in user's badge set in THIS channel (mod / sub / VIP
    /// …), captured from the most recent echoed own-message. Stamped
    /// onto optimistic rows for the same flash-free reason as
    /// `selfColor`. Empty until the first echo of the session — there's
    /// no cheap Helix endpoint for "my badges in channel X", so the
    /// first message renders badge-less and every one after is styled.
    private var selfBadges: [ChatBadge] = []

    /// Case-insensitive substrings that trigger row highlighting. Empty
    /// by default — keyword highlighting disabled.
    private var highlightKeywords: [String] = []

    /// At-attach snapshots of the chat filters (You → Chat → Filters).
    /// See `ChatFilterSettings` — read once in `attach`, consulted by
    /// both `apply` (live) and `ingest` (live + priming).
    private var filterHideCommands = false
    private var filterHideBots = false

    /// Whether the message should be dropped before it touches the
    /// buffer. The user's own messages are always exempt — hiding your
    /// own "!drops" the moment you send it reads as a send failure.
    private func isFiltered(_ chatMessage: ChatMessage) -> Bool {
        guard chatMessage.chatterUserId != currentUserId else { return false }
        return ChatFilterSettings.shouldHide(
            authorLogin: chatMessage.chatterUserLogin,
            text: chatMessage.message.text,
            hideCommands: filterHideCommands,
            hideBots: filterHideBots
        )
    }

    /// Registry-owned memo of normalize results for this channel — survives
    /// this model's detach/re-attach across tab swipes, which is the whole
    /// point: re-priming from the session ring becomes dictionary hits
    /// instead of re-tokenizing every message on the main thread. nil in
    /// tests / pre-attach; everything degrades to plain normalization.
    private var lineCache: NormalizedLineCache?

    /// Fingerprint of the inputs normalization depends on, for cache
    /// stamping. `emoteVersion` is the emote index's publish generation —
    /// see `NormalizedLineCache.Context`.
    private func cacheContext(emoteVersion: Int) -> NormalizedLineCache.Context {
        NormalizedLineCache.Context(
            emoteVersion: emoteVersion,
            currentUserLogin: currentUserLogin,
            highlightKeywords: highlightKeywords
        )
    }

    // MARK: - Send-orchestration state

    // Echo-reconciliation is two-keyed. The two keys handle the two
    // race orderings between the Helix POST response and the EventSub
    // WebSocket echo (which differ by ~50ms in practice and can land in
    // either order).
    //
    // Primary key — Helix-returned messageId. Unambiguous: Twitch's
    // messageId is globally unique per send. We learn it from
    // `sendChatMessage`'s response after our POST round-trips, so this
    // map is empty during the brief window before Helix responds.
    //
    // Fallback key — message text. Used only when the echo arrives
    // BEFORE Helix's response and we don't yet have a messageId to
    // match against. Vulnerable to false positives if the user
    // double-sends identical text within the race window (rare; Twitch
    // doesn't offer a client-correlation field to fix this fully).
    //
    // Lifecycle:
    //   - `send()` adds to `pendingSendIDByText` synchronously, then
    //     adds to `helixMessageIdByPendingId` once Helix responds
    //     (provided the optimistic row is still present — i.e. the echo
    //     hasn't already reconciled via the text fallback).
    //   - `apply()` consumes from either map when an echo arrives,
    //     and `cleanupPending(pendingId:)` removes whichever entries
    //     still reference the now-reconciled pending id.

    /// Primary echo-correlation map. Populated after `sendChatMessage`
    /// returns isSent=true.
    private var helixMessageIdByPendingId: [String: String] = [:]

    /// Fallback echo-correlation map. Populated synchronously in `send(...)`
    /// — covers the race window before Helix responds.
    ///
    /// **FIFO queue** (not a single value) because identical-text
    /// double-sends within the race window would otherwise overwrite
    /// the older entry. Echoes match the oldest pending (Twitch
    /// broadcasts in send-order); cleanup removes a specific id by
    /// scanning the array.
    ///
    /// Without the queue, this scenario corrupts state:
    ///   1. Send "lol" → pendingSendIDByText["lol"] = pending-A
    ///   2. Send "lol" again → overwrites to pending-B (A orphaned!)
    ///   3. Both echoes arrive before either Helix response. The
    ///      Path 2 lookup resolves "lol" to B and upgrades the wrong
    ///      row. Later, the timer-fallback for A synthesizes an
    ///      upgrade using msg-1 — but msg-1 is already in `lines`
    ///      (from echo #1) → DUPLICATE ID → ForEach assertion crash.
    ///
    /// The queue guarantees: echo #N reconciles row #N for all N,
    /// regardless of which arrives first.
    private var pendingSendIDByText: [String: [String]] = [:]

    /// Per-pending-send fallback timer. Started after Helix accepts (`isSent=true`)
    /// — if the EventSub echo doesn't arrive within
    /// `sendFallbackTimeout` seconds, the timer fires and synthesizes a
    /// local upgrade so the row doesn't sit dim in `.sending` forever.
    ///
    /// **Why we need this**: Twitch's EventSub WebSocket is usually
    /// reliable, but if the connection drops between Helix accept and
    /// the broadcast (or Twitch's edge has a hiccup), our optimistic
    /// row stays dim with no recovery path. The Helix response
    /// guarantees the message DID go out — we just don't have the
    /// rich echo data (badges, color, fragments) to upgrade with. The
    /// fallback synthesizes "good enough" data using what we have.
    ///
    /// Cancelled by `cleanupPending` when an echo arrives normally,
    /// and by `detach` when the model goes away.
    private var sendFallbackTimers: [String: Task<Void, Never>] = [:]

    /// How long to wait for the EventSub echo after Helix accepts a
    /// send. 5 seconds is a tradeoff: long enough to cover normal
    /// echo latency (median ~150ms, p99 ~1s on busy channels) plus a
    /// generous buffer for transient WebSocket re-handshakes; short
    /// enough that the user sees their message "land" before they
    /// give up and retry.
    private static let sendFallbackTimeout: Duration = .seconds(5)

    /// Surfaced to the view via @Observable so the compose bar can show a
    /// transient error toast when a send fails (Twitch dropped it,
    /// HelixError surfaced, network blip). nil clears the toast.
    public var sendError: String?

    /// Bindable Bool view of `sendError` for `.alert(isPresented:)`.
    /// Pulled into a computed bindable property so `ChatScreen.body`
    /// doesn't construct an inline `Binding(get:set:)` on every render
    /// pass — that pattern recreates the binding on every observed
    /// property change (i.e., every incoming chat message), allocating
    /// a fresh closure pair per body re-eval.
    ///
    /// The setter only acts on `false` (alert dismiss); setting `true`
    /// from a view doesn't surface an error (no message to attach).
    /// Real errors flow through `sendError = ...` in `send`.
    public var isShowingSendError: Bool {
        get { sendError != nil }
        set { if !newValue { sendError = nil } }
    }

    /// When non-nil, the compose bar renders a "Replying to …" chip and
    /// the next send is threaded onto this message. Set by `beginReply(to:)`,
    /// cleared by `cancelReply()` (user dismissed the chip) or
    /// automatically inside `send(...)` after a reply ships.
    ///
    /// We carry both the message ID (what Twitch needs to thread) and
    /// the author + a snippet of the body (what the user needs to
    /// remember which message they're replying to).
    public var replyContext: ReplyContext?

    /// Per-channel chat restrictions (slow mode, followers-only,
    /// subscribers-only, emote-only). nil until the first
    /// `refreshChatRestrictions()` completes — typically within a few
    /// hundred ms of session start. The compose bar reads from this
    /// to render an inline strip when any restriction is active.
    ///
    /// Refreshed on-demand by `refreshChatRestrictions()`; not currently
    /// updated on `channel.chat_settings.update` EventSub events (future
    /// commit). For now, restrictions are accurate as of session start
    /// and stale if the broadcaster toggles a setting mid-session.
    public private(set) var chatRestrictions: ChatRestrictions?

    /// True when the signed-in account can moderate (delete messages,
    /// timeout users, etc.) in the attached channel. Drives the
    /// `Delete Message` affordance in ChatRow's context menu.
    ///
    /// Set true via three paths:
    ///   1. **Broadcaster instant**: at attach time, if the account
    ///      userId equals the channelId, we know we're the broadcaster
    ///      — true immediately, no waiting.
    ///   2. **Moderated-channels seed**: at attach time, a fire-and-forget
    ///      task asks the caller-provided `moderatedChannelIds` closure
    ///      (registry-cached `/moderation/channels` — which channels does
    ///      THIS user moderate, user-side token) whether the attached
    ///      channel is in the set. Lands within one Helix round-trip on
    ///      the account's first channel-open, instantly after (the
    ///      registry caches the set per account).
    ///   3. **Moderator observation**: as our own chat-message echoes
    ///      arrive, we look at `chatMessage.badges` for "moderator" or
    ///      "broadcaster". Found → true.
    ///
    /// Path 3 is the fallback for path 2's failure modes: accounts signed
    /// in before `user:read:moderated_channels` was requested (fetch fails
    /// unauthorized → empty set), transient fetch failures, and being
    /// modded mid-session.
    ///
    /// Every path that flips this true ALSO calls
    /// `ChannelSession.enableModerationEvents()` (via
    /// `promoteToModerator`), which subscribes to `channel.moderate` v2.
    /// From then on the flag is LIVE in both directions: a `mod`/`unmod`
    /// action targeting our account — or Twitch revoking the subscription,
    /// which it does when the subscriber is unmodded — arrives as
    /// `.moderationStatusChanged` and is applied in `apply()`. The
    /// downgrade also fires `onModerationRevoked` so the registry's
    /// cached moderated-set doesn't re-seed the stale entry on reopen.
    public private(set) var currentUserCanModerate: Bool = false

    /// Invoked when a live `channel.moderate` signal downgrades
    /// `currentUserCanModerate` to false. `ChatScreen` wires this to
    /// `ChannelSessionRegistry.invalidateModeratedChannels` — the model
    /// can't reach the registry itself (Features ↔ Channels layering),
    /// same reason `moderatedChannelIds` is injected as a closure.
    /// Set by `attach(...)`; nil when no invalidation is needed (tests).
    private var onModerationRevoked: (@Sendable () async -> Void)?

    /// In-flight moderated-channels seed (path 2 above). Stored so
    /// `detach` can cancel it (tab closed before the fetch landed — a
    /// late flag-flip after re-attach to a DIFFERENT channel would be
    /// wrong) and so tests can await its completion deterministically.
    /// Internal rather than private for exactly that test access.
    var moderationSeedTask: Task<Void, Never>?

    /// Forward a chat-mode change (emote-only, subs-only, followers-only,
    /// slow mode) to the attached channel's session — see
    /// `ChannelSession.updateChatSettings` for parameter semantics.
    /// Throws when no session is attached or Helix rejects the PATCH
    /// (not actually a mod, token missing `moderator:manage:chat_settings`,
    /// network failure) — the settings sheet surfaces the error and
    /// reverts its controls.
    ///
    /// `chatRestrictions` is assigned here from the PATCH response in
    /// addition to the session's `.restrictionsUpdated` fan-out (which
    /// also lands, idempotently) so the caller observes the new state
    /// the moment this returns.
    public func updateChatSettings(
        emoteOnly: Bool? = nil,
        subscribersOnly: Bool? = nil,
        followersOnly: Bool? = nil,
        followersDurationMinutes: Int? = nil,
        slowMode: Bool? = nil,
        slowModeSeconds: Int? = nil
    ) async throws {
        guard let session = subscriptions.first?.session else {
            throw AppError(message: "Not connected to chat.")
        }
        chatRestrictions = try await session.updateChatSettings(
            emoteOnly: emoteOnly,
            subscribersOnly: subscribersOnly,
            followersOnly: followersOnly,
            followersDurationMinutes: followersDurationMinutes,
            slowMode: slowMode,
            slowModeSeconds: slowModeSeconds
        )
    }

    /// Payload for an in-flight reply intent. Held by `replyContext`;
    /// passed to `ChannelSession.send` as `replyParentMessageId` when
    /// the user finally taps Send.
    public struct ReplyContext: Sendable, Equatable {
        public let parentMessageId: String
        public let parentAuthorDisplayName: String
        public let parentSnippet: String      // already-truncated so the view doesn't need to
        /// The root of the thread this reply belongs to. For replies
        /// to a top-level message, this equals `parentMessageId`. For
        /// replies-to-replies mid-thread, this equals the original
        /// thread root (walked from the parent's own `replyParent`).
        ///
        /// Used to stamp the optimistic `ChatLine.ReplyParent` so the
        /// thread sheet can group the optimistic row correctly
        /// BEFORE the echo arrives and replaces it with Twitch's
        /// authoritative `threadMessageId`. Without this, an
        /// optimistic mid-thread reply would render as a singleton
        /// (its own "thread") in the View Thread sheet until the
        /// echo lands.
        public let threadRootMessageId: String

        public init(
            parentMessageId: String,
            parentAuthorDisplayName: String,
            parentSnippet: String,
            threadRootMessageId: String
        ) {
            self.parentMessageId = parentMessageId
            self.parentAuthorDisplayName = parentAuthorDisplayName
            self.parentSnippet = parentSnippet
            self.threadRootMessageId = threadRootMessageId
        }
    }

    /// Monotonic attach epoch. Bumped synchronously at the start of every
    /// `attach(...)`; the value that call establishes is `myEpoch`. Two things
    /// hang off it:
    ///   - **Supersession:** an in-flight attach re-checks `myEpoch == attachEpoch`
    ///     after each `await`; if a newer attach has bumped the epoch, the older
    ///     one bails (undoing any partial subscription) so the LAST attach wins
    ///     — replacing the old skip-and-strand re-entry guard, which left the
    ///     *surviving* call un-attached when it raced an in-flight one (the model
    ///     then rendered its primed lines but had no live subscription →
    ///     "Not connected to chat").
    ///   - **Stale-detach protection:** `detach(ifEpoch:)` is a no-op unless the
    ///     passed epoch is still current. The session-lifecycle `.task` passes
    ///     the epoch its `attach` returned, so a *dying* ChatScreen appearance's
    ///     teardown can't detach a model a *newer* appearance just re-attached.
    private var attachEpoch: Int = 0

    public init() {}

    // MARK: - Attach / detach

    /// Subscribes to each session, primes `lines` from their combined current
    /// state, and starts receiving new messages via callback.
    ///
    /// **Re-entry safety (epoch supersession)**: SwiftUI's `.task` can fire two
    /// overlapping `attach`es for the same model — e.g. a ChatScreen appearance
    /// disappears and reappears (paged tabs) or the channel session is torn down
    /// and rebuilt — and they interleave at their `await` suspensions. A bumped
    /// `attachEpoch` (claimed synchronously before any await) plus a re-check
    /// after every suspension means a superseded attach bails (undoing any
    /// partial subscription) so the LAST attach wins. This replaces the old
    /// "skip if already attaching" guard, which left the *surviving* call
    /// un-attached when it raced an in-flight one (the model then rendered its
    /// primed lines but had no live subscription → "Not connected to chat").
    ///
    /// A subsequent attach AFTER the first completes detaches the prior
    /// subscriptions and re-subscribes (re-establishes the live session on
    /// rebuild, and supports future multi-channel add/remove flows).
    /// - Returns: the attach epoch this call established. The caller (the
    ///   session-lifecycle `.task`) passes it back to `detach(ifEpoch:)` so a
    ///   stale teardown can't strand a newer attach.
    @discardableResult
    public func attach(
        sessions: [ChannelSession],
        emoteIndex: EmoteIndex? = nil,
        currentUserId: String = "",
        currentUserLogin: String = "",
        currentUserDisplayName: String = "",
        highlightKeywords: [String] = [],
        lineCap: Int = 500,
        lineCache: NormalizedLineCache? = nil,
        // The composite `ChannelDescriptor.ID` used to clear the persisted
        // draft after a successful send. Passed in by the view (which owns
        // the descriptor) rather than derived from the session's bare
        // channelId — the model shouldn't compose platform-qualified keys
        // itself. Empty (the default, used by tests) skips draft clearing.
        draftKey: ChannelDescriptor.ID = "",
        moderatedChannelIds: (@Sendable () async -> Set<String>)? = nil,
        onModerationRevoked: (@Sendable () async -> Void)? = nil
    ) async -> Int {
        // Claim a fresh epoch synchronously (before any await). A concurrent
        // attach that starts later bumps it again; we re-check after every
        // suspension and bail if superseded, so the LAST attach wins instead
        // of the old "skip and strand" behavior.
        attachEpoch &+= 1
        let myEpoch = attachEpoch

        // Apply the user's Chat History setting. Rebuild (rather than
        // reset) when the cap changed, carrying the block set over — the
        // view pushes `blockedIds` on its own schedule and may have done
        // so before attach ran.
        if buffer.cap != lineCap {
            let blocked = buffer.blockedIds
            buffer = ChatBuffer(cap: max(1, lineCap))
            buffer.blockedIds = blocked
        }

        // Tear down any prior subscriptions (unconditional — `ifEpoch: nil`).
        // Cheap when subs is empty (early return inside detach).
        await detach(ifEpoch: nil)
        guard myEpoch == attachEpoch else { return myEpoch }   // superseded mid-detach

        // Stash normalization context for the per-message handler. Captured
        // here rather than inside the closure so the closure stays small
        // and so updates to keywords (future feature) flow through without
        // resubscribing.
        self.emoteIndex = emoteIndex
        self.currentUserId = currentUserId
        self.currentUserLogin = currentUserLogin
        self.currentUserDisplayName = currentUserDisplayName
        self.highlightKeywords = highlightKeywords
        // Chat filters: snapshot the toggles once per attach (same
        // lifecycle as highlight keywords). Both ingest paths — live
        // apply() and the priming loop — consult these copies, so a
        // mid-session toggle can't make live and re-primed history drift.
        self.filterHideCommands = ChatFilterSettings.hideCommands()
        self.filterHideBots = ChatFilterSettings.hideBots()
        self.lineCache = lineCache
        self.onModerationRevoked = onModerationRevoked

        attachState = .attaching

        var combined: [ChannelSession.ChannelEvent] = []
        for session in sessions {
            // Atomic prime + subscribe — see ChannelSession.subscribe docs.
            let (token, snapshot) = await session.subscribe { [weak self] event in
                // Handler runs in whichever actor the Task happens to be on.
                // Hop to MainActor to convert + apply.
                await self?.apply(event)
            }
            guard myEpoch == attachEpoch else {
                // A newer attach superseded us while we awaited subscribe — undo
                // the subscription we just made so we don't leak a subscriber on
                // the registry-owned session, then bail.
                await session.unsubscribe(token)
                return myEpoch
            }
            subscriptions.append((session, token))
            combined.append(contentsOf: snapshot)
        }

        // Stash the caller-provided draft key for `send(...)` to clear the
        // persisted draft on successful send. Single-channel-per-tab MVP;
        // multi-channel will need a per-channel draft mapping.
        self.draftKey = draftKey

        if let firstSession = sessions.first {
            chatRestrictions = await firstSession.currentChatRestrictions()
            guard myEpoch == attachEpoch else { return myEpoch }   // superseded
            // Instant broadcaster check — `isAccountBroadcaster` is
            // nonisolated and just compares the two ids. For broadcasters
            // this gives us mod-power before any chat has happened.
            // For viewers and mods, this stays false; the
            // mod-observation path below upgrades it on first own
            // message echo carrying mod/broadcaster badges.
            if firstSession.isAccountBroadcaster {
                promoteToModerator(session: firstSession)
            }
            // Moderated-channels seed — the hybrid pre-fetch path (path 2
            // in `currentUserCanModerate`'s doc). Fire-and-forget so attach
            // never blocks on the Helix round-trip; the registry caches the
            // set per account, so every channel-open after the account's
            // first resolves instantly. Skipped when the broadcaster check
            // above already proved mod power. The badge-observation upgrade
            // in `apply` remains the fallback when the set comes back
            // empty (no scope on the token, fetch failure, modded
            // mid-session).
            if !currentUserCanModerate, let moderatedChannelIds {
                let channelId = firstSession.channelId
                moderationSeedTask = Task { [weak self] in
                    let ids = await moderatedChannelIds()
                    // Cancellation check AFTER the await: detach cancels
                    // this task, and a result landing post-detach must not
                    // flip the flag (the model may re-attach elsewhere).
                    guard !Task.isCancelled, let self else { return }
                    if ids.contains(channelId) {
                        self.promoteToModerator(session: firstSession)
                    }
                }
            }
            // Seed the optimistic-row name color from /chat/color so even
            // the FIRST send of the session renders styled. Fire-and-forget
            // — attach shouldn't wait on a cosmetic fetch, and the echo
            // path overwrites with fresher data anyway. The echo-wins
            // guard (only fill while still empty) avoids regressing a
            // color an echo taught us during the fetch's round-trip.
            if selfColor.isEmpty {
                Task { [weak self] in
                    guard let color = await firstSession.fetchOwnChatColor() else { return }
                    guard let self, self.selfColor.isEmpty else { return }
                    self.selfColor = color
                }
            }
        }

        // Apply the priming snapshot. For single-session tabs `combined`
        // is already in arrival order; the ring buffer maintains insertion
        // order. For multi-session tabs we'd sort by event timestamp here
        // — TODO when N > 1 ships.
        //
        // We rebuild the buffer from scratch by replaying each ChannelEvent
        // through `ingest` — the SAME dispatch the live path uses (apply()
        // calls ingest too). Priming therefore shares the cap + block-filter
        // logic with live ingestion; no separate "initial state" path to
        // drift. The buffer's own cap handles the multi-session overflow the
        // old `Self.cap(primed)` did.
        buffer.reset()
        for event in combined {
            ingest(event)
        }
        publishPending()
        attachState = .attached
        logger.info("ChatTranscriptModel attached to \(sessions.count) session(s) [epoch \(myEpoch)], primed with \(self.lines.count) line(s)")
        return myEpoch
    }

    /// The single funnel for "we just learned the user can moderate here."
    /// Flips the flag AND fire-and-forget-enables the session's
    /// `channel.moderate` v2 subscription so the status stays live from
    /// here on (unmod/revocation downgrades arrive via `apply()`). All
    /// three upgrade paths — broadcaster check, moderated-set seed, badge
    /// observation — route through this so none of them can forget the
    /// subscription half. Safe to call repeatedly: the flag set is
    /// idempotent and `enableModerationEvents` self-guards.
    private func promoteToModerator(session: ChannelSession?) {
        currentUserCanModerate = true
        guard let session else { return }
        Task {
            await session.enableModerationEvents()
        }
    }

    /// Unsubscribes from every session and clears local state. Safe to call
    /// multiple times; each call no-ops if already detached.
    ///
    /// - Parameter ifEpoch: when non-nil, this teardown only runs if the epoch
    ///   is still current (`== attachEpoch`). The session-lifecycle `.task`
    ///   passes the epoch its `attach` returned, so a *dying* ChatScreen
    ///   appearance can't tear down a model that a *newer* appearance just
    ///   re-attached. `nil` (the internal call from `attach`) always tears down.
    public func detach(ifEpoch epoch: Int? = nil) async {
        if let epoch, epoch != attachEpoch { return }
        // Cancel any in-flight fallback timers BEFORE the empty-guard
        // so a model with pending sends but no subscriptions (rare)
        // still gets its timers cleaned. Calling cancel on a completed
        // Task is harmless.
        for (_, task) in sendFallbackTimers {
            task.cancel()
        }
        sendFallbackTimers.removeAll()

        // Cancel an in-flight moderated-channels seed alongside the timers
        // (also before the empty-guard, same rationale): a result landing
        // after detach must not flip `currentUserCanModerate` for whatever
        // channel this model attaches to next.
        moderationSeedTask?.cancel()
        moderationSeedTask = nil

        guard !subscriptions.isEmpty else { return }

        // Snapshot before mutation — actor calls below are awaits.
        let toRemove = subscriptions
        subscriptions = []
        attachState = .detached

        for sub in toRemove {
            await sub.session.unsubscribe(sub.token)
        }
        logger.info("ChatTranscriptModel detached \(toRemove.count) subscription(s)")
    }

    // MARK: - Send

    /// Sends a chat message via the first attached session (single-channel
    /// MVP — multi-channel send-targeting lands when that ships).
    ///
    /// Flow:
    ///   1. Stamp an optimistic ChatLine with a `pending-…` id and append
    ///      it to `lines` so the user sees their message instantly.
    ///   2. Record `text → pendingId` in `pendingSendIDByText` so the
    ///      apply() path can later reconcile the EventSub echo against it.
    ///   3. Call `ChannelSession.send(_:)`.
    ///      - Success (Helix `isSent == true`): swap the optimistic row's
    ///        id to the canonical `messageId`. The subsequent EventSub
    ///        echo dedups against that id and is silently dropped.
    ///      - Twitch drop (`isSent == false`, `dropReason` set): remove
    ///        the optimistic row, surface `dropReason.message` via
    ///        `sendError` so the compose bar can show a toast.
    ///      - Thrown error (network, HelixError, unauthorized after
    ///        refresh-and-retry): same — remove + surface.
    ///   4. If the EventSub echo arrived FIRST (Helix POST raced — common
    ///      when the WebSocket beats the POST response by ~50ms), apply()
    ///      already consumed `pendingSendIDByText[text]` and swapped the
    ///      optimistic row to the canonical echo. The Helix-response path
    ///      then sees `pendingSendIDByText[text] == nil` and skips the
    ///      id-swap (it's already done).
    ///
    /// Returns nothing — observable side effects (`lines`, `sendError`)
    /// drive the UI.
    /// Composite `ChannelDescriptor.ID` used by `send(...)` to clear the
    /// persisted draft once a send commits. Provided by the view at
    /// attach time (single-channel-per-tab MVP — multi-channel sends
    /// will need a per-channel draft mapping, deferred until that
    /// ships). Empty when no caller supplied one (tests) — draft
    /// clearing is skipped.
    private var draftKey: ChannelDescriptor.ID = ""

    public func send(text: String, replyOverride: ReplyContext? = nil) async {
        // Trim here too (in addition to ChannelSession.send) — we don't
        // want to enqueue an optimistic row with leading whitespace that
        // the server then trims. The two trims must produce the same
        // canonical text or the echo-dedup text-match breaks.
        let canonical = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }

        guard let session = subscriptions.first?.session else {
            sendError = "Not connected to chat."
            return
        }

        // Three send paths, all funneled through the same Helix call:
        //   1. Plain send  — replyOverride nil, replyContext nil
        //   2. Reply send  — replyOverride nil, replyContext set (the
        //      main compose bar with the chip showing)
        //   3. Thread send — replyOverride set (the thread sheet's
        //      compose bar, which always threads against the thread's
        //      latest message)
        //
        // Snapshot the attachment now and clear the chip if we used it.
        // Skipping the clear when an override is in play means the main
        // compose bar's chip survives across thread-view sends —
        // intuitively right: the user might be in the middle of
        // composing a reply on the main bar and pop into the thread
        // sheet to add a quick thread response.
        let replyAttachment: ReplyContext?
        if let override = replyOverride {
            replyAttachment = override
        } else {
            replyAttachment = replyContext
            replyContext = nil
        }

        // Build and append the optimistic line. `pending-…` IDs are
        // distinct from anything Twitch can mint (their messageIds are
        // UUIDv4s without a prefix), so there's no risk of a real echo
        // colliding with a pending id.
        // Build a ReplyParent for the optimistic row if this is a reply.
        // ReplyContext now carries the authoritative threadRootMessageId
        // (walked in `replyContext(for:)`), so we can stamp the
        // optimistic line with the correct root. This matters for
        // replies-to-replies: opening the thread sheet during the
        // race window (after send, before echo) would otherwise see
        // the optimistic row as a singleton thread instead of part of
        // the chain.
        let optimisticReplyParent: ChatLine.ReplyParent? = replyAttachment.map { attachment in
            ChatLine.ReplyParent(
                parentMessageId: attachment.parentMessageId,
                parentAuthorDisplayName: attachment.parentAuthorDisplayName,
                parentBody: attachment.parentSnippet,
                threadRootMessageId: attachment.threadRootMessageId
            )
        }

        // Clear the persisted draft now (synchronously, before any
        // awaits). The optimistic row appears immediately below; from
        // the user's perspective the compose bar is "empty + the
        // message is in flight" — restoring the draft from disk on a
        // failure would be confusing, so we treat send-initiated as
        // the deliberate clear point.
        //
        // If the send ends up in the `.failed` state, the user can
        // long-press the failed row → Retry (which re-sends the
        // captured `retryText`) — they don't need the draft restored
        // for that path.
        if !draftKey.isEmpty {
            DraftStorage.clear(forChannel: draftKey)
        }

        let pendingId = "pending-\(UUID().uuidString)"
        let optimistic = ChatLine(
            id: pendingId,
            kind: .message,
            authorBadges: [],
            originalBadges: selfBadges,  // last echoed badge set (empty before first echo)
            authorUserId: currentUserId,
            authorDisplayName: currentUserDisplayName.isEmpty ? currentUserLogin : currentUserDisplayName,
            authorUserLogin: currentUserLogin,
                                        // Carry the signed-in user's login so a localized
                                        // (non-Latin) self display name renders as "name (login)"
                                        // immediately, instead of flipping when the echo arrives.
            authorColor: selfColor,      // attach-time /chat/color seed, refreshed by echoes
            runs: Normalizer.wordRuns(text: canonical),
                                        // Word-level runs (required for FlowLayout wrapping) but
                                        // no emote resolution on the optimistic row — echo will
                                        // overwrite with the Normalizer's fully tokenized version
            isHighlighted: false,
            timestamp: .now,
            deliveryState: .sending,    // renderer dims the row so the user sees it as in-flight
            replyParent: optimisticReplyParent
        )
        buffer.append(optimistic)
        publishPending()
        // FIFO append — see pendingSendIDByText doc-comment.
        pendingSendIDByText[canonical, default: []].append(pendingId)

        do {
            let response = try await session.send(canonical, replyParentMessageId: replyAttachment?.parentMessageId)

            if response.isSent {
                // Success: leave the optimistic line untouched and let the
                // EventSub echo upgrade it. We don't pre-swap the id —
                // doing so would short-circuit the echo's normalization
                // (badges, color, server-parsed fragments) via the
                // dedup-by-id path.
                //
                // What we DO is stash the canonical messageId so the
                // upcoming echo can match unambiguously via Path 0 in
                // `apply()`. This is the primary correlation key; the
                // text map remains as a fallback for the rare case
                // where the echo arrives before we get here.
                //
                // Guard: only stash if the optimistic row is still in
                // `allLines`. The echo may have ALREADY arrived during our
                // await on session.send — it would have reconciled via
                // the text fallback (Path 2), removed the optimistic
                // row, and the entry we'd write here would be a dead
                // letter. Skipping the write avoids a tiny memory leak
                // and a stale entry that could (extremely unlikely) match
                // a future event with the same messageId.
                if buffer.contains(id: pendingId) {
                    helixMessageIdByPendingId[pendingId] = response.messageId
                    // Defensive: start a fallback timer that fires if
                    // the echo never arrives. See `synthesizeStuckUpgrade`
                    // for what it does. The timer is cancelled by
                    // cleanupPending the moment an echo reconciles the
                    // row through Path 0 or Path 2, so in the normal
                    // case it never fires.
                    startSendFallbackTimer(pendingId: pendingId, canonicalMessageId: response.messageId)
                } else {
                    // Echo already reconciled — defensive sweep. With
                    // the FIFO queue, removing the whole text key would
                    // be wrong (it could nuke unrelated pending sends
                    // of the same text). Instead, remove only OUR
                    // pendingId from the queue and clear the key only
                    // if the queue is empty afterwards.
                    pendingSendIDByText[canonical]?.removeAll { $0 == pendingId }
                    if pendingSendIDByText[canonical]?.isEmpty == true {
                        pendingSendIDByText.removeValue(forKey: canonical)
                    }
                }
                logger.debug("send: Helix accepted; awaiting EventSub echo to upgrade optimistic row")
                return
            }

            // isSent=false: Twitch returned 200 OK but didn't broadcast.
            // Common drop reasons: `msg_ratelimit`, `automod_held`,
            // `msg_banned`, `msg_emoteonly`, `msg_subsonly`,
            // `msg_followersonly`, `msg_slowmode`. Mark the row as
            // .failed in place — non-modal, the user sees red text +
            // retry icon directly on the row that didn't send. They
            // get context for WHY (the dropReason) without losing what
            // they typed.
            cleanupPending(pendingId: pendingId)
            let reason = response.dropReason?.message ?? "Twitch didn't broadcast the message."
            markFailed(pendingId: pendingId, reason: reason, retryText: canonical)
            logger.notice("send dropped by Twitch: code=\(response.dropReason?.code ?? "unknown", privacy: .public) reason=\(reason, privacy: .public)")
        } catch {
            // Network blip, unauthorized after refresh-and-retry, or
            // ChannelSession.send's own empty-string guard. Same
            // treatment as a Twitch drop — keep the row, mark it failed.
            cleanupPending(pendingId: pendingId)
            markFailed(pendingId: pendingId, reason: error.localizedDescription, retryText: canonical)
            logger.error("send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-send a previously-failed row's draft. Removes the failed row
    /// (so we don't end up with two duplicate rows when the retry
    /// succeeds and the echo arrives) and dispatches `send(text:)` with
    /// the captured retry text. Called from the row's retry button.
    ///
    /// Silently no-ops if the row isn't actually in a `.failed` state —
    /// could happen if the user triple-taps the retry button on a row
    /// that's mid-retry.
    public func retry(failedLineId: String) async {
        guard let failedRow = buffer.line(id: failedLineId),
              case .failed(_, let retryText) = failedRow.deliveryState else {
            return
        }
        // Capture the failed row's reply context BEFORE removing it so
        // the retry threads against the same parent. Without this fix,
        // a failed reply that the user taps Retry on would land as a
        // top-level message — silently breaking the thread relationship
        // the user explicitly chose with Reply.
        //
        // ReplyParent already carries the resolved threadRootMessageId
        // (set when the original send was made), so we use it directly
        // — no need to re-walk.
        let preservedReply: ReplyContext? = failedRow.replyParent.map { rp in
            ReplyContext(
                parentMessageId: rp.parentMessageId,
                parentAuthorDisplayName: rp.parentAuthorDisplayName,
                parentSnippet: rp.parentBody,
                threadRootMessageId: rp.threadRootMessageId
            )
        }
        // Remove the failed row first so the new optimistic insert
        // takes its place at the bottom of `lines` — the user expects
        // the retry to feel like a fresh send.
        buffer.remove(id: failedLineId)
        publishPending()
        await send(text: retryText, replyOverride: preservedReply)
    }

    /// Transitions the pending row identified by `pendingId` to the
    /// `.failed` state in place. Pulled out of `send` so both the
    /// Helix-drop and thrown-error paths share the same code.
    ///
    /// If the row isn't in `lines` anymore (rare — could happen if a
    /// moderator's `chatCleared` event raced our failure) we DON'T
    /// re-insert it; the user already saw the row vanish via the
    /// chat-clear handler, and resurrecting it would be jarring.
    /// Kick a one-shot 5-second timer Task that synthesizes a local
    /// "delivered" upgrade if the EventSub echo never arrives. Stored
    /// in `sendFallbackTimers` so `cleanupPending` can cancel it the
    /// moment a real echo reconciles the row.
    ///
    /// The Task is `@MainActor`-isolated via `[weak self]` capture —
    /// when the model deinits (view torn down for good) the weak self
    /// is nil and the synthesize step bails. Belt-and-braces with the
    /// explicit `detach()` cancellation.
    private func startSendFallbackTimer(pendingId: String, canonicalMessageId: String) {
        // Cancel any prior timer for this pendingId (shouldn't happen
        // in normal flow, but defensive).
        sendFallbackTimers[pendingId]?.cancel()

        let task = Task { @MainActor [weak self] in
            // `try?` swallows the CancellationError that propagates
            // when cleanupPending or detach cancels us. After the
            // sleep returns (either timed out OR cancelled), we
            // check `isCancelled` to decide whether to fire.
            try? await Task.sleep(for: Self.sendFallbackTimeout)
            guard !Task.isCancelled, let self else { return }
            self.synthesizeStuckUpgrade(pendingId: pendingId, canonicalMessageId: canonicalMessageId)
        }
        sendFallbackTimers[pendingId] = task
    }

    /// Synthesizes a `.delivered` upgrade for a row that's still in
    /// `.sending` 5s after Helix accepted. We don't have the echo's
    /// rich payload (badges, color, server-parsed fragments) so the
    /// row's content stays as the optimistic version — but its id
    /// becomes the canonical messageId from Helix, so:
    ///   - The dim "in-flight" treatment goes away (user sees their
    ///     message landed).
    ///   - If the echo eventually arrives, it hits Path 1 (dedup-by-id)
    ///     and is silently dropped — no duplicate row.
    ///
    /// Bails if the row is no longer in `.sending` (e.g. echo raced
    /// the timer and reconciled normally between our sleep returning
    /// and this code running).
    private func synthesizeStuckUpgrade(pendingId: String, canonicalMessageId: String) {
        sendFallbackTimers.removeValue(forKey: pendingId)

        guard let row = buffer.line(id: pendingId),
              case .sending = row.deliveryState else {
            // Already upgraded via echo, or removed — nothing to do.
            return
        }

        // Defensive duplicate-id check. With the FIFO queue (commit 17)
        // this shouldn't happen in normal flow, but if Path 2 ever
        // upgraded an unrelated row to `canonicalMessageId` (legacy
        // bug, future regression, etc.), replacing pendingId with
        // canonicalMessageId would produce two rows with the same id
        // and crash the ForEach.
        //
        // If we'd create a dupe, just remove the optimistic row instead
        // of replacing — the echo's row already covers it.
        if buffer.contains(id: canonicalMessageId) {
            logger.warning("Synthesize would duplicate id \(canonicalMessageId, privacy: .public); removing optimistic row only")
            buffer.remove(id: pendingId)
            publishPending()
            cleanupPending(pendingId: pendingId)
            return
        }

        logger.warning("Echo never arrived for messageId=\(canonicalMessageId, privacy: .public); synthesizing local upgrade after \(Self.sendFallbackTimeout)")

        buffer.replace(id: pendingId, with: ChatLine(
            id: canonicalMessageId,
            kind: row.kind,
            authorBadges: row.authorBadges,
            originalBadges: row.originalBadges,
            authorUserId: row.authorUserId,
            authorDisplayName: row.authorDisplayName,
            authorUserLogin: row.authorUserLogin,   // preserve the login annotation on synthesized delivery
            authorColor: row.authorColor,
            runs: row.runs,
            isHighlighted: row.isHighlighted,
            timestamp: row.timestamp,
            deliveryState: .delivered,
            replyParent: row.replyParent
        ))
        publishPending()

        // Clean up correlation maps — we won't be reconciling this id
        // from an echo anymore (the synthesized id is what a future
        // echo would dedup against via Path 1).
        cleanupPending(pendingId: pendingId)
    }

    private func markFailed(pendingId: String, reason: String, retryText: String) {
        guard let row = buffer.line(id: pendingId) else { return }
        buffer.replace(id: pendingId, with: ChatLine(
            id: row.id,
            kind: row.kind,
            authorBadges: row.authorBadges,
            originalBadges: row.originalBadges,
            authorUserId: row.authorUserId,
            authorDisplayName: row.authorDisplayName,
            authorUserLogin: row.authorUserLogin,   // preserve the login annotation when a send fails
            authorColor: row.authorColor,
            runs: row.runs,
            isHighlighted: row.isHighlighted,
            timestamp: row.timestamp,
            deliveryState: .failed(reason: reason, retryText: retryText),
            replyParent: row.replyParent       // preserve thread membership on failed
        ))
        publishPending()
    }

    /// View-facing reset for the toast. Call after the toast finishes
    /// auto-dismissing so a second send error re-triggers the animation.
    public func clearSendError() {
        sendError = nil
    }

    /// Asks Twitch to delete one message in the attached channel.
    /// Guard-rails are minimal — the caller (ChatRow's context menu)
    /// only surfaces the affordance when `currentUserCanModerate` is
    /// true. The actual authorization is on the server: if the user
    /// isn't actually a mod (or is no longer one), Helix returns
    /// `HelixError.unauthorized` and we surface that as a toast.
    ///
    /// Does NOT mutate `lines` locally. The chat.message_delete
    /// EventSub echo will arrive shortly after the Helix call returns
    /// and our existing `apply()` for `.messageDeleted(targetMessageId:)`
    /// flips the row to `.deletedPlaceholder`. The visual update
    /// therefore flows through the SAME path as a moderator's web-UI
    /// delete — no special-case rendering needed.
    public func deleteMessage(withId messageId: String) async {
        guard let session = subscriptions.first?.session else {
            sendError = "Not connected to chat."
            return
        }
        do {
            try await session.deleteMessage(messageId: messageId)
            logger.info("Requested delete for message \(messageId, privacy: .public)")
        } catch {
            sendError = "Couldn't delete message: \(error.localizedDescription)"
            logger.error("deleteMessage failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Attaches a reply to the next send. Builds the chip snippet from
    /// the line's runs — text runs concatenated up to ~80 chars, emote
    /// runs collapsed to their name (so the chip still reads sensibly
    /// when the parent was mostly emotes).
    ///
    /// `.subBubble` / `.raidBubble` / `.systemBubble` / `.deletedPlaceholder`
    /// lines are ignored — replying to a system message isn't a thing
    /// Twitch supports, and the long-press menu in `ChatRow` only
    /// surfaces the Reply affordance for `.message` rows anyway. The
    /// guard is defensive.
    public func beginReply(to line: ChatLine) {
        guard case .message = line.kind else { return }
        replyContext = Self.replyContext(for: line)
    }

    /// User dismissed the reply chip without sending. Clears the
    /// pending attachment.
    public func cancelReply() {
        replyContext = nil
    }

    /// Returns every line in `lines` belonging to the thread rooted at
    /// `rootMessageId` — the root itself plus any reply whose
    /// `threadRootMessageId` matches. Order is preserved (chronological,
    /// since `lines` is append-only with timestamp-ordered insertion).
    ///
    /// Computed on demand rather than maintained as an index because:
    ///   - Threads are rare (one in N messages); maintaining a full
    ///     thread-index for every message would waste memory.
    ///   - The filter is O(lines.count) — fine per call at our cap (~500
    ///     lines), but not per publish during a raid. `ThreadView` therefore
    ///     calls it (via `threadSnapshot`) once per sheet open and then only
    ///     when a published batch actually touches the thread (see
    ///     `ChatChange.touchesThread`).
    public func lines(inThreadRootedAt rootMessageId: String) -> [ChatLine] {
        lines.filter { line in
            line.id == rootMessageId
                || line.replyParent?.threadRootMessageId == rootMessageId
        }
    }

    /// The thread's lines plus the change-log version they reflect — the
    /// thread-sheet counterpart of `transcriptSnapshot()`. A reader that seeds
    /// from this and then pulls `changes(since: version)` misses nothing.
    func threadSnapshot(rootedAt rootMessageId: String) -> (version: Int, lines: [ChatLine]) {
        let version = sealPendingChanges()
        return (version, lines(inThreadRootedAt: rootMessageId))
    }

    /// Returns the thread root id for a given line. If the line is
    /// itself a reply, the thread root is `replyParent.threadRootMessageId`.
    /// If not, the line itself is the candidate root.
    ///
    /// "Candidate" because we have no way to tell from a single line
    /// whether it's actually been replied to — would require scanning
    /// other lines. The caller (the View Thread menu item) doesn't
    /// need this distinction because the sheet handles a "singleton
    /// thread" (just this one message) the same way it handles a
    /// 50-message thread.
    public static func threadRoot(of line: ChatLine) -> String {
        line.replyParent?.threadRootMessageId ?? line.id
    }

    /// Factory: build a `ReplyContext` from any line. Used by
    /// `beginReply` (main compose bar) AND by `ThreadView` (thread
    /// sheet's compose bar — replies to the latest thread message).
    /// Centralizing the construction here means callers don't have to
    /// know how to build the snippet, and the snippet logic only
    /// exists in one place.
    public static func replyContext(for line: ChatLine) -> ReplyContext {
        // Resolve the thread root: if the line we're replying to is
        // itself a reply, the thread root is the SAME root the line
        // already points to (mid-thread continuation). Otherwise the
        // line itself is the root candidate (first reply, or a
        // singleton thread).
        let threadRoot = line.replyParent?.threadRootMessageId ?? line.id
        return ReplyContext(
            parentMessageId: line.id,
            parentAuthorDisplayName: line.authorDisplayName,
            parentSnippet: snippet(from: line.runs, cap: 80),
            threadRootMessageId: threadRoot
        )
    }

    /// Build a short, single-line preview of a message's runs for the
    /// reply chip. Emote and twitchEmote runs become their name, URL and
    /// cheermote runs render as their text. Runs are word-level (no
    /// whitespace of their own) so pieces are joined with single spaces.
    /// The total is capped with an ellipsis.
    ///
    /// Internal (not private) so `ThreadView` can reuse it via
    /// `replyContext(for:)` without duplicating the dispatch logic.
    static func snippet(from runs: [LineRun], cap: Int) -> String {
        var out = ""
        for run in runs {
            let piece: String
            switch run {
            case .text(let s):
                piece = s
            case .emote(let e):
                piece = e.name
            case .twitchEmote(_, let display):
                piece = display
            case .mention(let login, _):
                piece = "@\(login)"
            case .url(let s):
                piece = s
            case .cheermote(let prefix, let bits, _):
                piece = "\(prefix)\(bits)"
            }
            if piece.isEmpty { continue }
            if !out.isEmpty { out += " " }
            out += piece
            if out.count >= cap { break }
        }
        if out.count > cap {
            // Cut at character boundary — using `prefix(cap)` returns a
            // Substring of Characters, safe for Grapheme clusters
            // (emoji, combined marks). String(...) re-bridges.
            return String(out.prefix(cap)) + "…"
        }
        return out
    }

    // MARK: - Internals

    /// Apply one `ChannelEvent` to the `lines` array. Called from the
    /// per-session subscriber handler when a new event arrives, and (via
    /// the appendLines helper) on each event in the priming snapshot.
    ///
    /// Dispatch:
    ///   - `.message`  → normalize + append a `.message` ChatLine
    ///       - dedup-by-id (Helix returned first, we already swapped our
    ///         pending-id to the canonical id, then the echo arrives)
    ///       - echo-of-pending-send (echo beat the Helix response): swap
    ///         our optimistic row in place with the normalized echo
    ///   - `.notification` / `.raid` → convert via Normalizer.line(from:),
    ///     append a bubble ChatLine
    ///   - `.messageDeleted(id)` → find by id, flip kind to .deletedPlaceholder
    ///   - `.chatCleared` → flip every line to .deletedPlaceholder
    ///   - `.messagesClearedFromUser(userId)` → flip matching lines
    ///
    /// **Race tolerance**: if the EmoteIndex hasn't loaded yet (snapshot is
    /// empty), the message normalizes with no third-party emote
    /// resolution — emote-name tokens stay as plain text. Subsequent
    /// messages received after the load completes will resolve their
    /// emotes correctly. Re-normalizing pre-load messages is deferred to
    /// a future iteration.
    // Internal (not private) so FeaturesTests can drive event application
    // directly — the visibility relaxation ChatTranscriptModelReplyTests' header
    // note anticipated. Production callers remain the subscribe handlers
    // registered in `attach`.
    func apply(_ event: ChannelSession.ChannelEvent) {
        // Restrictions-update events don't produce a row — they're
        // pure state changes. Update the observed property and bail
        // before the rest of apply tries to add a line.
        //
        // Caught here (in the instance method) rather than in the
        // static appendLines helper because the static can't mutate
        // self. The priming path in attach() doesn't pass restrictions
        // updates through this method (it pulls the snapshot
        // separately) so we never double-apply.
        if case .restrictionsUpdated(let restrictions) = event {
            chatRestrictions = restrictions
            logger.info("Chat restrictions updated mid-session: hasAny=\(restrictions.hasAny)")
            return
        }

        // Live mod-status change — also a pure state change, no row.
        // Upgrades route through `promoteToModerator` (idempotent; the
        // channel.moderate subscription that delivered this is already
        // live, so the enable inside is a no-op). Downgrades additionally
        // evict the registry's cached moderated-set via the injected hook
        // — without that, a close-and-reopen would re-seed mod
        // affordances from the stale cache entry.
        if case .moderationStatusChanged(let canModerate) = event {
            if canModerate {
                promoteToModerator(session: subscriptions.first?.session)
            } else {
                currentUserCanModerate = false
                if let onModerationRevoked {
                    Task { await onModerationRevoked() }
                }
            }
            logger.info("Mod status changed mid-session for #\(self.draftKey, privacy: .public): canModerate=\(canModerate)")
            return
        }

        // Chat filters: drop hidden messages before ANY processing —
        // echo reconciliation, ingest, and (critically) the highlight
        // sound below, which reads `buffer.last` and would otherwise
        // ping off a stale row when the filtered message never landed.
        // Own messages are exempt inside `isFiltered`.
        if case .message(let chatMessage, _) = event, isFiltered(chatMessage) {
            return
        }

        // Special handling for chat-message events: reconcile against the
        // optimistic rows we inserted from `send(...)`. Pulled out of the
        // shared static helper because reconciliation needs read access to
        // `lines` and write access to both correlation maps — neither of
        // which the static (used for priming, where no pending sends
        // exist) has.
        if case .message(let chatMessage, _) = event {
            // Mod-status side-observation. We look at the badges
            // attached to OUR own echoed messages. If we see a
            // "moderator" or "broadcaster" set_id, we're a mod here.
            // Cheap (badge array is usually <5 entries), runs only on
            // our own messages, and once `currentUserCanModerate` is
            // true we don't re-check.
            //
            // This is a free upgrade — runs alongside the existing echo
            // reconciliation paths below.
            if !currentUserCanModerate && chatMessage.chatterUserId == currentUserId {
                let hasModBadge = chatMessage.badges.contains { badge in
                    badge.setId == "moderator" || badge.setId == "broadcaster"
                }
                if hasModBadge {
                    promoteToModerator(session: subscriptions.first?.session)
                    logger.info("Detected mod status from echoed badges for #\(self.draftKey, privacy: .public)")
                }
            }

            // Self-style side-observation: each echoed own-message carries
            // the authoritative color + badge set for this channel. Cache
            // them so the NEXT optimistic send row renders fully styled
            // instead of flashing plain until its own echo lands.
            if chatMessage.chatterUserId == currentUserId {
                if !chatMessage.color.isEmpty { selfColor = chatMessage.color }
                if !chatMessage.badges.isEmpty { selfBadges = chatMessage.badges }
            }

            // ─── Path 0 (primary): Helix-id match ────────────────────
            //
            // We learned this messageId from `sendChatMessage`'s response.
            // Unambiguous — Twitch's messageId is globally unique per send.
            // Handles every case except "echo arrived before Helix
            // returned" (Path 2 catches that one).
            if !helixMessageIdByPendingId.isEmpty,
               let matchedPendingId = helixMessageIdByPendingId.first(where: { $0.value == chatMessage.messageId })?.key {
                cleanupPending(pendingId: matchedPendingId)
                if upgradeOptimistic(at: matchedPendingId, with: chatMessage) { return }
                // Optimistic row was removed under us (e.g., a Helix
                // failure cleanup raced this echo). Fall through to
                // normal append so the echo still shows up — Twitch
                // saw the message, the user deserves to see it.
            }

            // ─── Path 1: dedup-by-id ─────────────────────────────────
            //
            // We already reconciled this echo above (or a prior path
            // already added a row with this id). Drop the duplicate.
            // This is a defensive check — the cleanup in Path 0 should
            // prevent the same echo from arriving twice in normal flow,
            // but Twitch occasionally re-sends events on reconnect.
            // Check the buffer's unfiltered window (not the filtered `lines`)
            // so a blocked user's prior message is still recognised as stored.
            if buffer.contains(id: chatMessage.messageId) {
                return
            }

            // ─── Path 2 (fallback): text+sender match ────────────────
            //
            // The EventSub echo beat our Helix POST response. We don't
            // have a messageId in `helixMessageIdByPendingId` yet, so
            // fall back to matching by (chatterUserId == me, text).
            //
            // Vulnerable to false positives if the user double-sends
            // identical text within the race window AND both echoes
            // arrive before both Helix responses. The collision is
            // visible only as one extra row (other matches still
            // upgrade correctly via Path 0 once Helix returns). Twitch
            // doesn't offer a client-correlation field — fixing this
            // edge case fully requires either client-side serialization
            // of identical-text sends or a custom IRC bridge.
            //
            // CR-MEDIUM-1: the text-map key is canonicalized
            // (whitespace-trimmed) at send time — the echo lookup must
            // apply the same trim so Twitch-side whitespace handling
            // (e.g. trailing newlines stripped server-side) doesn't
            // cause a miss.
            // Trim only on the own-message path: `trimmingCharacters` allocates
            // a fresh String unconditionally, and this Path-2 fallback only
            // matters for the current user's own echoes (rare), not every
            // incoming message.
            if chatMessage.chatterUserId == currentUserId,
               let matchedPendingId = pendingSendIDByText[
                   chatMessage.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
               ]?.first {
                // FIFO: oldest pending matches first echo, matching
                // Twitch's broadcast order.
                cleanupPending(pendingId: matchedPendingId)
                if upgradeOptimistic(at: matchedPendingId, with: chatMessage) { return }
                // Optimistic row was removed under us — fall through to
                // normal append.
            }
        }

        ingest(event)

        // Highlight sound: fire for a freshly-appended FOREIGN live
        // message that's highlighted, if the user has sounds on.
        //
        // Why this is the right gate:
        //   - apply() is the LIVE path; priming/backfill uses
        //     appendLines directly in attach(), so historical messages
        //     never reach here. (No ping for messages that arrived
        //     while you were away.)
        //   - The echo-reconciliation paths above (0/1/2) already
        //     `return`ed for our OWN messages, so a `.message` reaching
        //     this fall-through is someone else's. The explicit
        //     `chatterUserId != currentUserId` guard covers the rare
        //     own-message-fell-through edge (failed send + late echo).
        //   - `buffer.last?.isHighlighted` reads the just-appended row —
        //     true when it's a self-mention OR matches a configured
        //     keyword (the Normalizer set the flag).
        //   - `soundEnabled()` is checked LAST so the UserDefaults read
        //     only happens for an actual highlighted foreign message
        //     (rare), not every message.
        //   - `!blockedIds.contains(...)` keeps a blocked user silent: blocking
        //     means "invisible to me," so their (still-arriving) messages must
        //     not ping the highlight sound even if they @-mention us.
        if case .message(let m, let isHistorical) = event,
           !isHistorical,
           m.chatterUserId != currentUserId,
           !blockedIds.contains(m.chatterUserId),
           buffer.last?.isHighlighted == true,
           HighlightSettings.soundEnabled() {
            HighlightSoundPlayer.shared.play()
        }

        publishPending()
    }

    /// Replaces the optimistic row at `pendingId` with a freshly-normalized
    /// `ChatLine` built from the echoed `chatMessage`. Returns `true` if
    /// the swap happened (row was present); `false` if the row was gone
    /// (caller falls through to normal-append behavior).
    ///
    /// Pulled out of `apply` so Paths 0 and 2 share the same upgrade logic
    /// — without it the same six-line block would appear twice with the
    /// same content but different match-key sources, inviting drift.
    private func upgradeOptimistic(at pendingId: String, with chatMessage: ChatMessage) -> Bool {
        let versioned = emoteIndex?.snapshotWithGeneration()
        let snapshot = versioned?.emotes ?? [:]
        let normalizedLine = Normalizer.normalize(
            message: chatMessage,
            emoteSnapshot: snapshot,
            currentUserLogin: currentUserLogin,
            highlightKeywords: highlightKeywords
        )
        // Memo the echo's normalized form: the echo event sits in the
        // session ring under this canonical messageId, so the next tab
        // remount replays it through `ingest` — which should hit, not
        // re-normalize. (The optimistic `pending-…` row itself is never
        // cached; it isn't a ring event.)
        lineCache?.store(normalizedLine, context: cacheContext(emoteVersion: versioned?.generation ?? 0))
        // `replace` returns false (a no-op) when the optimistic row was already
        // removed under us — the caller then falls through to a normal append.
        let didReplace = buffer.replace(id: pendingId, with: normalizedLine)
        publishPending()
        return didReplace
    }

    /// Removes any correlation-map entries pointing at `pendingId` from
    /// both maps. Called when a pending send reaches a terminal state
    /// (reconciled via echo, dropped by Twitch, or thrown error).
    ///
    /// Removing from the text map requires a value-scan because the map
    /// is keyed by text; the cost is bounded by the number of pending
    /// sends, typically 0–1.
    private func cleanupPending(pendingId: String) {
        helixMessageIdByPendingId.removeValue(forKey: pendingId)
        // FIFO-aware removal: find which text key contains this
        // pendingId in its queue, remove it from the queue, and drop
        // the key entirely if the queue is now empty. Two-step scan
        // is O(n) over pending sends — n is tiny (typically 0–1).
        if let textKey = pendingSendIDByText.first(where: { $0.value.contains(pendingId) })?.key {
            pendingSendIDByText[textKey]?.removeAll { $0 == pendingId }
            if pendingSendIDByText[textKey]?.isEmpty == true {
                pendingSendIDByText.removeValue(forKey: textKey)
            }
        }
        // Cancel + remove the fallback timer. Echo arrived (or row was
        // explicitly removed), so the timer's stuck-upgrade no longer
        // applies. Calling cancel on a completed Task is harmless.
        sendFallbackTimers[pendingId]?.cancel()
        sendFallbackTimers.removeValue(forKey: pendingId)
    }

    /// Applies one `ChannelEvent` to the `buffer`. Shared by the live path
    /// (`apply`, after echo reconciliation) and the priming loop (`attach`),
    /// so initial state and live ingestion can't drift. The buffer owns the
    /// cap + block-filter; this method only decides *what* mutation each event
    /// kind produces.
    ///
    /// Instance method (was a `static` taking the model as a context) because
    /// it reads `emoteIndex` / `currentUserLogin` / `highlightKeywords` and
    /// writes `buffer` — all instance state.
    private func ingest(_ event: ChannelSession.ChannelEvent) {
        switch event {
        case .message(let chatMessage, let isHistorical):
            // Chat filters, priming-path edition: `apply` already guards
            // the live path, but the priming loop in `attach` calls this
            // directly — without this check, re-primed history would
            // resurrect messages the live path dropped.
            if isFiltered(chatMessage) { return }
            // EmoteIndex.snapshot() is nonisolated + lock-protected, so
            // it's safe to call from @MainActor without an await.
            // Snapshot + generation read atomically: the generation stamps
            // the cache entry, so it must belong to the table we normalize
            // against.
            let versioned = emoteIndex?.snapshotWithGeneration()
            let snapshot = versioned?.emotes ?? [:]
            let context = cacheContext(emoteVersion: versioned?.generation ?? 0)
            // Memo hit: this exact message was normalized before (live
            // arrival, or a prior tab mount) under the same inputs. The
            // re-prime path on tab swipes is ~all hits, which is what
            // keeps swiping between open chats cheap. The provenance flag
            // is re-stamped on every append (it rides the ring event, not
            // the cache) so a hit can never carry a stale dim state.
            if var cached = lineCache?.line(id: chatMessage.messageId, context: context) {
                cached.isHistorical = isHistorical
                buffer.append(cached)
                return
            }
            var line = Normalizer.normalize(
                message: chatMessage,
                emoteSnapshot: snapshot,
                currentUserLogin: currentUserLogin,
                highlightKeywords: highlightKeywords
            )
            line.isHistorical = isHistorical
            lineCache?.store(line, context: context)
            buffer.append(line)

        case .notification(let n):
            // The Normalizer skips notice types we don't render (returns
            // nil) — those are dropped here. Logging the skip is the
            // caller's job; the Normalizer stays sync-and-pure.
            if let line = Normalizer.line(from: n) {
                buffer.append(line)
            }

        case .raid(let r):
            buffer.append(Normalizer.line(from: r))

        case .messageDeleted(let targetMessageId):
            // Mutation in place: find the row by id, replace with a
            // deletedPlaceholder-kind copy. We DON'T remove the row —
            // a vanishing line is disorienting mid-scroll, and keeping
            // it as a strikethrough is the Twitch web convention. A no-op
            // when the target already aged out of the buffer.
            buffer.mutate(id: targetMessageId) { $0.markingDeleted() }

        case .chatCleared:
            // Flip every existing line to deletedPlaceholder. Future
            // messages still arrive normally — this only retroactively
            // hides the scrollback.
            buffer.mutateAll { $0.markingDeleted() }

        case .messagesClearedFromUser(let targetUserId):
            // Flip every line whose author is the timed-out/banned user.
            // Required field `authorUserId` on ChatLine is what makes
            // this work — without it we'd have no key to match against.
            buffer.mutateMatching(authorUserId: targetUserId) { $0.markingDeleted() }

        case .newMessagesDivider(let id, let timestamp):
            // The red "New" rule. Pure presentation — empty author, empty
            // runs; ChatRow dispatches on the kind. The id was minted with
            // the ring event, so a re-prime (tab swipe back) replays the
            // same stable identity instead of a fresh row.
            buffer.append(ChatLine(
                id: id,
                kind: .newMessagesDivider,
                authorDisplayName: "",
                runs: [],
                timestamp: timestamp
            ))

        case .restrictionsUpdated:
            // Restrictions updates produce no row — they're pure state
            // changes consumed by `apply()` before this switch runs.
            break

        case .moderationStatusChanged:
            // No row, same as restrictions. NOT re-applied from the ring
            // on priming either: attach re-derives mod status from its
            // own sources (broadcaster check, moderated-set seed, badge
            // observation), all of which post-date a replayed ring event.
            break
        }
    }
}
