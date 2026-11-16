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

/// `apply-batch`: the main-actor half of the message pipeline (one interval
/// per drained batch). Pair with `Channels.Pipeline`'s `normalize` /
/// `deliver` intervals in Instruments.
private let signposter = AppLogger.signposter("Features.ChatTranscriptModel")

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
/// checks. The main actor does as little as possible per message: rows arrive
/// already normalized by `ChannelSession` (once per channel, off-main), in
/// BATCHES — each drain of the subscription mailbox is one main-actor turn
/// however many messages it holds — and each row costs only the O(1) buffer
/// mutation plus echo reconciliation. Publishing is coalesced to at most one
/// flush per `coalescingWindow` (~one frame) — see "Coalesced change channel".
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

    /// One drain task per subscription: wakes when its session posts, takes
    /// everything queued as one batch, applies it in a single main-actor
    /// turn. Started only after priming (the mailbox buffers until then), and
    /// cancelled by `detach`.
    @ObservationIgnored private var consumers: [Task<Void, Never>] = []

    // MARK: - Per-attach viewer state
    //
    // Set at attach() time and consulted per inbound row. Normalization
    // itself now happens in `ChannelSession` (once per channel, off the main
    // actor); what's left here is what depends on THIS viewer's attach.

    /// The signed-in user's lowercase login. Stamped onto optimistic send
    /// rows. (Self-mention highlighting is computed by the session, which
    /// knows its account's login.)
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

    /// The viewer's highlight keywords, prepared once per attach. Applied to
    /// each message row as it lands (see `withKeywordHighlight`) on top of the
    /// session's self-mention flag.
    ///
    /// Why keywords stay here rather than in the session: they're a per-
    /// attach viewer preference (read from `HighlightSettings` when a tab
    /// attaches), while a session's rows are shared by every tab showing the
    /// channel — baking one tab's keywords into them would leak into others.
    /// The check is cheap: empty matcher (the default) is one branch, and a
    /// configured one is a lowercase-contains per word.
    @ObservationIgnored private var highlightMatcher = HighlightMatcher(keywords: [])

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

    /// The row as this viewer sees it: the session's line, plus this attach's
    /// keyword highlight. Message rows only — bubbles never highlighted.
    private func withKeywordHighlight(_ line: ChatLine) -> ChatLine {
        guard !line.isHighlighted,
              !highlightMatcher.isEmpty,
              case .message = line.kind,
              highlightMatcher.matches(line.runs) else { return line }
        var highlighted = line
        highlighted.isHighlighted = true
        return highlighted
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

    /// Rows the stuck-send fallback settled locally (`synthesizeStuckUpgrade`):
    /// `.delivered` under their canonical id, yet absent from the session's
    /// ring because the echo never came. `reprime` must carry them across a
    /// rebuild like any other local row. Pruned to ids still in the buffer.
    @ObservationIgnored private var locallySettledIds: Set<String> = []

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
    /// state, and starts draining new rows from each session's mailbox.
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
        currentUserId: String = "",
        currentUserLogin: String = "",
        currentUserDisplayName: String = "",
        highlightKeywords: [String] = [],
        lineCap: Int = 500,
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

        // Stash the per-viewer context consulted for each inbound row.
        self.currentUserId = currentUserId
        self.currentUserLogin = currentUserLogin
        self.currentUserDisplayName = currentUserDisplayName
        self.highlightMatcher = HighlightMatcher(keywords: highlightKeywords)
        // Chat filters: snapshot the toggles once per attach (same
        // lifecycle as highlight keywords). Both ingest paths — live
        // apply() and the priming loop — consult these copies, so a
        // mid-session toggle can't make live and re-primed history drift.
        self.filterHideCommands = ChatFilterSettings.hideCommands()
        self.filterHideBots = ChatFilterSettings.hideBots()
        self.onModerationRevoked = onModerationRevoked

        attachState = .attaching

        var combined: [ChannelUpdate] = []
        var newSubscriptions: [ChannelSubscription] = []
        for session in sessions {
            // Atomic prime + subscribe — see ChannelSession.subscribe docs.
            // Rows arrive normalized by the session; nothing is re-tokenized
            // on the main actor, here or per live message.
            let (subscription, snapshot) = await session.subscribe()
            guard myEpoch == attachEpoch else {
                // A newer attach superseded us while we awaited subscribe — undo
                // the subscription we just made so we don't leak a subscriber on
                // the registry-owned session, then bail.
                await session.unsubscribe(subscription.token)
                return myEpoch
            }
            subscriptions.append((session, subscription.token))
            newSubscriptions.append(subscription)
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
        // order. For multi-session tabs we'd sort by row timestamp here
        // — TODO when N > 1 ships.
        //
        // We rebuild the buffer from scratch by replaying each update
        // through `ingest` — the SAME dispatch the live path uses (apply()
        // calls ingest too). Priming therefore shares the cap + block-filter
        // logic with live ingestion; no separate "initial state" path to
        // drift. The buffer's own cap handles the multi-session overflow the
        // old `Self.cap(primed)` did.
        buffer.reset()
        locallySettledIds.removeAll()
        for update in combined {
            ingest(update)
        }
        publishPending()

        // Only now start draining live batches. Everything posted since
        // `subscribe()` is waiting in the mailbox, so nothing is lost — and
        // nothing can be applied BEFORE the prime above (whose `reset` would
        // otherwise wipe it). Each batch is one main-actor turn.
        for subscription in newSubscriptions {
            consumers.append(Task { @MainActor [weak self] in
                for await _ in subscription.wakeups {
                    // A wakeup already in flight when `detach` cancelled us
                    // still resumes the loop once — don't apply it.
                    guard !Task.isCancelled, let self else { return }
                    self.apply(subscription.takePending())
                }
            })
        }
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

        // Stop draining before unsubscribing: a batch must not land in a
        // model that's no longer attached (it would resurface after the
        // next attach's prime reset, or into the wrong channel).
        for consumer in consumers {
            consumer.cancel()
        }
        consumers.removeAll()

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
        locallySettledIds.insert(canonicalMessageId)

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

    // MARK: - Internals

    /// Applies one drained batch — everything the session posted since the
    /// last drain — in a single main-actor turn, then schedules ONE coalesced
    /// publish for all of it. Called by the per-subscription consumer task
    /// started in `attach`.
    ///
    /// Internal (not private) so FeaturesTests can drive event application
    /// directly. Production callers remain the consumer tasks.
    func apply(_ batch: [ChannelUpdate]) {
        guard !batch.isEmpty else { return }
        let interval = signposter.beginInterval(
            "apply-batch",
            id: signposter.makeSignpostID(),
            "updates=\(batch.count)"
        )
        defer { signposter.endInterval("apply-batch", interval) }

        for update in batch {
            applyOne(update)
        }
        publishPending()
    }

    /// Single-update convenience over `apply(_:)` (tests).
    func apply(_ update: ChannelUpdate) {
        apply([update])
    }

    /// Apply one `ChannelUpdate` to the buffer. Rows arrive already
    /// normalized by the session; this decides only what each one does to
    /// THIS transcript.
    ///
    /// Dispatch:
    ///   - `.message`  → append the session's line (plus keyword highlight)
    ///       - dedup-by-id (Helix returned first, we already swapped our
    ///         pending-id to the canonical id, then the echo arrives)
    ///       - echo-of-pending-send (echo beat the Helix response): swap
    ///         our optimistic row in place with the echo's line
    ///   - `.row` → append the bubble / divider line as-is
    ///   - `.messageDeleted(id)` → find by id, flip kind to .deletedPlaceholder
    ///   - `.chatCleared` → flip every line to .deletedPlaceholder
    ///   - `.messagesClearedFromUser(userId)` → flip matching lines
    ///   - `.reprime(snapshot)` → rebuild from the snapshot, keeping local
    ///     (in-flight / failed) send rows
    ///
    /// **Race tolerance**: rows normalized before the channel's EmoteIndex
    /// loaded carry emote names as plain text; the session re-normalizes
    /// them against the loaded table the next time a tab subscribes.
    private func applyOne(_ event: ChannelUpdate) {
        // Restrictions-update events don't produce a row — they're
        // pure state changes. Update the observed property and bail
        // before the rest of apply tries to add a line.
        //
        // The priming path in attach() doesn't pass restrictions updates
        // through this method (it reads the session's cached snapshot
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

        // The ring changed in a way that isn't a tail append (late join
        // history landed above live rows), or this subscriber fell too far
        // behind: rebuild from the session's snapshot.
        if case .reprime(let snapshot) = event {
            reprime(with: snapshot)
            return
        }

        // Chat filters: drop hidden messages before ANY processing —
        // echo reconciliation, ingest, and (critically) the highlight
        // sound below, which reads `buffer.last` and would otherwise
        // ping off a stale row when the filtered message never landed.
        // Own messages are exempt inside `isFiltered`.
        if case .message(let normalized) = event, isFiltered(normalized.message) {
            return
        }

        // Special handling for chat-message events: reconcile against the
        // optimistic rows we inserted from `send(...)`. Pulled out of the
        // shared static helper because reconciliation needs read access to
        // `lines` and write access to both correlation maps — neither of
        // which the static (used for priming, where no pending sends
        // exist) has.
        if case .message(let normalized) = event {
            let chatMessage = normalized.message
            observeOwnEcho(chatMessage)

            // ─── Path 0 (primary): Helix-id match ────────────────────
            //
            // We learned this messageId from `sendChatMessage`'s response.
            // Unambiguous — Twitch's messageId is globally unique per send.
            // Handles every case except "echo arrived before Helix
            // returned" (Path 2 catches that one).
            if !helixMessageIdByPendingId.isEmpty,
               let matchedPendingId = helixMessageIdByPendingId.first(where: { $0.value == chatMessage.messageId })?.key {
                cleanupPending(pendingId: matchedPendingId)
                if upgradeOptimistic(at: matchedPendingId, with: normalized) { return }
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
                if upgradeOptimistic(at: matchedPendingId, with: normalized) { return }
                // Optimistic row was removed under us — fall through to
                // normal append.
            }
        }

        ingest(event)

        // Highlight sound: fire for a freshly-appended FOREIGN live
        // message that's highlighted, if the user has sounds on.
        //
        // Why this is the right gate:
        //   - apply() is the LIVE path; priming calls `ingest` directly
        //     in attach(), and history that arrives live (reconnect gap-
        //     fill) is flagged `isHistorical` by the session — so no ping
        //     for messages that arrived while you were away.
        //   - The echo-reconciliation paths above (0/1/2) already
        //     `return`ed for our OWN messages, so a `.message` reaching
        //     this fall-through is someone else's. The explicit
        //     `chatterUserId != currentUserId` guard covers the rare
        //     own-message-fell-through edge (failed send + late echo).
        //   - `buffer.last?.isHighlighted` reads the just-appended row —
        //     true when it's a self-mention (flagged by the session) OR
        //     matches a configured keyword (`withKeywordHighlight`).
        //   - `soundEnabled()` is checked LAST so the UserDefaults read
        //     only happens for an actual highlighted foreign message
        //     (rare), not every message.
        //   - `!blockedIds.contains(...)` keeps a blocked user silent: blocking
        //     means "invisible to me," so their (still-arriving) messages must
        //     not ping the highlight sound even if they @-mention us.
        if case .message(let normalized) = event,
           !normalized.line.isHistorical,
           normalized.message.chatterUserId != currentUserId,
           !blockedIds.contains(normalized.message.chatterUserId),
           buffer.last?.isHighlighted == true,
           HighlightSettings.soundEnabled() {
            HighlightSoundPlayer.shared.play()
        }
    }

    /// Side-observations on OUR OWN echoed messages (no-op for anyone else's):
    ///
    ///   - **Mod status**: a "moderator" / "broadcaster" badge on our echo
    ///     means we're a mod here. Cheap (badge array is usually <5
    ///     entries), and once `currentUserCanModerate` is true we don't
    ///     re-check. A free upgrade alongside echo reconciliation.
    ///   - **Self style**: each echo carries the authoritative color + badge
    ///     set for this channel. Cache them so the NEXT optimistic send row
    ///     renders fully styled instead of flashing plain until its own echo
    ///     lands.
    ///
    /// Shared by the live path (`applyOne`) and `reprime`, so an echo that
    /// arrives inside a reprime snapshot still teaches us both.
    private func observeOwnEcho(_ chatMessage: ChatMessage) {
        guard chatMessage.chatterUserId == currentUserId else { return }
        if !currentUserCanModerate {
            let hasModBadge = chatMessage.badges.contains { badge in
                badge.setId == "moderator" || badge.setId == "broadcaster"
            }
            if hasModBadge {
                promoteToModerator(session: subscriptions.first?.session)
                logger.info("Detected mod status from echoed badges for #\(self.draftKey, privacy: .public)")
            }
        }
        if !chatMessage.color.isEmpty { selfColor = chatMessage.color }
        if !chatMessage.badges.isEmpty { selfBadges = chatMessage.badges }
    }

    /// The pending send an own echo answers, by the same keys the live path
    /// uses: the Helix-returned id (Path 0), else the canonical text, FIFO
    /// (Path 2). Doesn't consume anything — callers `cleanupPending`.
    private func pendingSend(answeredBy echo: ChatMessage) -> String? {
        if !helixMessageIdByPendingId.isEmpty,
           let pendingId = helixMessageIdByPendingId.first(where: { $0.value == echo.messageId })?.key {
            return pendingId
        }
        guard echo.chatterUserId == currentUserId else { return nil }
        return pendingSendIDByText[
            echo.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        ]?.first
    }

    /// Replaces the optimistic row at `pendingId` with the echo's line, as
    /// normalized by the session (the same row the session's ring holds, so
    /// a later re-prime replays it identically). Returns `true` if the swap
    /// happened (row was present); `false` if the row was gone (caller falls
    /// through to normal-append behavior).
    ///
    /// Pulled out of `apply` so Paths 0 and 2 share the same upgrade logic
    /// — without it the same block would appear twice with the same content
    /// but different match-key sources, inviting drift.
    private func upgradeOptimistic(at pendingId: String, with normalized: NormalizedMessage) -> Bool {
        // `replace` returns false (a no-op) when the optimistic row was already
        // removed under us — the caller then falls through to a normal append.
        buffer.replace(id: pendingId, with: withKeywordHighlight(normalized.line))
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

    /// Applies one `ChannelUpdate` to the `buffer`. Shared by the live path
    /// (`apply`, after echo reconciliation), the priming loop (`attach`) and
    /// `reprime`, so initial state and live ingestion can't drift. The buffer
    /// owns the cap + block-filter; this method only decides *what* mutation
    /// each update produces. Rows arrive normalized — nothing is tokenized
    /// here.
    private func ingest(_ event: ChannelUpdate) {
        switch event {
        case .message(let normalized):
            // Chat filters, priming-path edition: `apply` already guards
            // the live path, but the priming loop in `attach` calls this
            // directly — without this check, re-primed history would
            // resurrect messages the live path dropped.
            if isFiltered(normalized.message) { return }
            // The provenance flag, timestamp and self-mention highlight were
            // all decided by the session and ride the row; only this
            // viewer's keywords are layered on.
            buffer.append(withKeywordHighlight(normalized.line))

        case .row(let line):
            // Bubbles (sub / raid / system) and the "New" divider, built once
            // by the session with stable ids — a re-prime (tab swipe back)
            // replays the same identity instead of a fresh row.
            buffer.append(line)

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

        case .reprime:
            // Never part of a ring snapshot; handled by `apply()`.
            break
        }
    }

    /// Rebuilds the buffer from a session snapshot — the same replay attach
    /// primes with — while keeping this transcript's local-only rows, which
    /// exist nowhere in the session's ring: sends still in flight or marked
    /// failed, and stuck sends the fallback settled locally.
    ///
    /// The snapshot may carry own echoes this transcript never saw live (they
    /// sat in the backlog the reprime replaced). Those get the live path's
    /// treatment minus the in-place swap — their row is already in the
    /// snapshot: the own-echo observations run, and the pending send each
    /// one answers (Path 0 id, else Path 2 text) is settled instead of its
    /// optimistic row being re-appended as a duplicate. Only echoes NEW to
    /// this transcript are considered, so an old identical message in late
    /// history can't settle a fresh send.
    ///
    /// Kept rows are re-appended at the tail — where recent sends nearly
    /// always are anyway.
    private func reprime(with snapshot: [ChannelUpdate]) {
        let previousLines = buffer.lines
        let previousIds = Set(previousLines.map(\.id))
        let localRows = previousLines.filter {
            $0.deliveryState != .delivered || locallySettledIds.contains($0.id)
        }

        buffer.reset()
        for update in snapshot {
            ingest(update)
        }

        var settledPendingIds = Set<String>()
        for update in snapshot {
            guard case .message(let normalized) = update,
                  normalized.message.chatterUserId == currentUserId,
                  !previousIds.contains(normalized.message.messageId) else { continue }
            observeOwnEcho(normalized.message)
            if let pendingId = pendingSend(answeredBy: normalized.message) {
                cleanupPending(pendingId: pendingId)
                settledPendingIds.insert(pendingId)
            }
        }

        var kept = 0
        for row in localRows where !settledPendingIds.contains(row.id) && !buffer.contains(id: row.id) {
            buffer.append(row)
            kept += 1
        }
        locallySettledIds = locallySettledIds.filter { buffer.contains(id: $0) }
        logger.info("ChatTranscriptModel re-primed from \(snapshot.count) session update(s); kept \(kept) local row(s), settled \(settledPendingIds.count) send(s) by echo")
    }
}
