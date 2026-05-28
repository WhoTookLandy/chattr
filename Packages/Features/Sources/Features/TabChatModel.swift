import Foundation
import Observation   // for @Observable — pulled from Observation rather than SwiftUI
                     // so this model has no SwiftUI dependency, matching its actual surface
import TwitchKit
import Channels
import ChatModel
import EmoteSources
import Core
import os

private let logger = AppLogger.make("Features.TabChatModel")

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
/// Why `@MainActor`: the @Observable `lines` property drives SwiftUI body
/// recomputes. Mutating from any other actor would either need explicit
/// MainActor hops everywhere or trip Swift 6's data-race checks. @MainActor
/// keeps everything simple at the cost of one actor hop per inbound message
/// (cheap in practice — chat throughput is ~tens of messages/sec at peak).
@MainActor
@Observable
public final class TabChatModel {

    /// Three-state attach lifecycle for ChatScreen's empty-state UI.
    public enum AttachState: Sendable {
        case detached    // no sessions registered
        case attaching   // attach in flight
        case attached    // all subscriptions live
    }

    /// Display-ready lines rendered by `ChatRow`. Capped at `lineCap` via
    /// a sliding window — when full, appending drops the oldest line.
    ///
    /// Type changed from `[ChatMessage]` to `[ChatLine]` in Phase 2.2 — we
    /// now normalize each incoming message through `Normalizer.normalize`
    /// before storing, so views consume the already-tokenized form
    /// (emote runs, mention runs, etc.) without re-tokenizing on every
    /// body recomputation.
    public private(set) var lines: [ChatLine] = []

    public private(set) var attachState: AttachState = .detached

    /// Max retained messages across all sessions in this tab.
    private static let lineCap = 500

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

    /// Case-insensitive substrings that trigger row highlighting. Empty
    /// by default — keyword highlighting disabled.
    private var highlightKeywords: [String] = []

    // MARK: - Send-orchestration state

    /// Maps "message text we sent but haven't seen echoed yet" → "the
    /// pending-id we used for the optimistic row." Used by `apply()` to
    /// recognize an incoming `channel.chat.message` as the echo of one
    /// of our own sends, even when the EventSub echo beats the Helix
    /// POST response (which races by ~100ms in practice — Twitch broadcasts
    /// to the WebSocket on the same code path that responds to the POST).
    ///
    /// Keyed by text rather than by ID because we only learn the canonical
    /// `messageId` from one of two sources: the Helix response OR the
    /// EventSub echo. Either may arrive first. Text is what both have in
    /// common.
    ///
    /// If the user double-sends the same text quickly, the dictionary
    /// overwrites and the first-sent line keeps its pending-id until its
    /// Helix response races back — but the echo's broadcast order matches
    /// the send order, so the second send's pending-id gets reconciled
    /// against the first echo. The mismatched IDs are unobservable to the
    /// user (the lines look identical and the dedup still suppresses the
    /// duplicate). A correctness fix here would be a per-send UUID
    /// embedded in the message text (Twitch doesn't surface a
    /// client-correlation field), which isn't worth the complexity at
    /// chat throughput rates.
    private var pendingSendIDByText: [String: String] = [:]

    /// Surfaced to the view via @Observable so the compose bar can show a
    /// transient error toast when a send fails (Twitch dropped it,
    /// HelixError surfaced, network blip). nil clears the toast.
    public var sendError: String?

    /// Synchronous re-entry guard for `attach(sessions:)`. Without it, two
    /// concurrent attach() calls can both pass the "subscriptions empty"
    /// check before either commits — classic actor reentrancy state-staleness
    /// pattern from axiom-concurrency's `isolation-inheritance-diag.md`. The
    /// flag is set/cleared synchronously, so a second call entering the
    /// method during the first's await suspension sees `isAttaching == true`
    /// and bails immediately, before any await.
    private var isAttaching: Bool = false

    public init() {}

    // MARK: - Attach / detach

    /// Subscribes to each session, primes `lines` from their combined current
    /// state, and starts receiving new messages via callback.
    ///
    /// **Re-entry safety**: a synchronous flag (`isAttaching`) guards against
    /// concurrent invocations. SwiftUI's `.task` can fire twice for the same
    /// view identity during multi-state transitions like our `openChannel`
    /// action; without this guard the two calls interleave at their `await`
    /// suspensions and BOTH register subscribers on the same session — same
    /// model, double append per message, duplicate IDs in `ForEach`.
    ///
    /// Setting the flag synchronously *before* any `await` is what makes the
    /// pattern correct. @MainActor's "lock" is released at every suspension
    /// point, so a flag set after an await wouldn't block re-entry — but
    /// the synchronous prologue here is atomic relative to any other
    /// @MainActor work.
    ///
    /// Idempotent at the API level: a second attach with the same sessions
    /// while the first is in flight is a no-op. A subsequent attach AFTER
    /// the first completes will detach the prior subscriptions and re-subscribe
    /// (useful for future multi-channel "the user added/removed a channel
    /// from this tab" flows).
    public func attach(
        sessions: [ChannelSession],
        emoteIndex: EmoteIndex? = nil,
        currentUserId: String = "",
        currentUserLogin: String = "",
        currentUserDisplayName: String = "",
        highlightKeywords: [String] = []
    ) async {
        // Synchronous re-entry guard — must precede any `await`.
        guard !isAttaching else {
            logger.info("TabChatModel attach skipped — already in flight")
            return
        }
        isAttaching = true
        defer { isAttaching = false }

        // Tear down any prior subscriptions (e.g., user changed channel set
        // in a multi-channel tab). Cheap when subs is empty (early return
        // inside detach).
        await detach()

        // Stash normalization context for the per-message handler. Captured
        // here rather than inside the closure so the closure stays small
        // and so updates to keywords (future feature) flow through without
        // resubscribing.
        self.emoteIndex = emoteIndex
        self.currentUserId = currentUserId
        self.currentUserLogin = currentUserLogin
        self.currentUserDisplayName = currentUserDisplayName
        self.highlightKeywords = highlightKeywords

        attachState = .attaching

        var combined: [ChannelSession.ChannelEvent] = []
        for session in sessions {
            // Atomic prime + subscribe — see ChannelSession.subscribe docs.
            let (token, snapshot) = await session.subscribe { [weak self] event in
                // Handler runs in whichever actor the Task happens to be on.
                // Hop to MainActor to convert + apply.
                await self?.apply(event)
            }
            subscriptions.append((session, token))
            combined.append(contentsOf: snapshot)
        }

        // Apply the priming snapshot. For single-session tabs `combined`
        // is already in arrival order; the ring buffer maintains insertion
        // order. For multi-session tabs we'd sort by event timestamp here
        // — TODO when N > 1 ships.
        //
        // We rebuild `lines` from scratch by replaying each ChannelEvent
        // through the same apply() that handles live events. This means
        // priming uses identical code paths to live ingestion — no
        // separate "initial state" logic to drift.
        var primed: [ChatLine] = []
        primed.reserveCapacity(combined.count)
        for event in combined {
            Self.appendLines(for: event, into: &primed, normalizationContext: self)
        }
        lines = Self.cap(primed)
        attachState = .attached
        logger.info("TabChatModel attached to \(sessions.count) session(s), primed with \(self.lines.count) line(s)")
    }

    /// Unsubscribes from every session and clears local state. Safe to call
    /// multiple times; each call no-ops if already detached.
    public func detach() async {
        guard !subscriptions.isEmpty else { return }

        // Snapshot before mutation — actor calls below are awaits.
        let toRemove = subscriptions
        subscriptions = []
        attachState = .detached

        for sub in toRemove {
            await sub.session.unsubscribe(sub.token)
        }
        logger.info("TabChatModel detached \(toRemove.count) subscription(s)")
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
    public func send(text: String) async {
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

        // Build and append the optimistic line. `pending-…` IDs are
        // distinct from anything Twitch can mint (their messageIds are
        // UUIDv4s without a prefix), so there's no risk of a real echo
        // colliding with a pending id.
        let pendingId = "pending-\(UUID().uuidString)"
        let optimistic = ChatLine(
            id: pendingId,
            kind: .message,
            authorBadges: [],
            originalBadges: [],
            authorUserId: currentUserId,
            authorDisplayName: currentUserDisplayName.isEmpty ? currentUserLogin : currentUserDisplayName,
            authorColor: "",            // unknown until echo arrives; renderer falls back to .primary
            runs: [.text(canonical)],   // no emote resolution on the optimistic row — echo will
                                        // overwrite with the Normalizer's tokenized version
            isHighlighted: false,
            timestamp: .now
        )
        lines.append(optimistic)
        // Cap as usual — sending while at 500 lines drops the oldest, same
        // as a received message would.
        if lines.count > Self.lineCap {
            lines.removeFirst(lines.count - Self.lineCap)
        }
        pendingSendIDByText[canonical] = pendingId

        do {
            let response = try await session.send(canonical)

            if response.isSent {
                // Success: leave the optimistic line untouched and let the
                // EventSub echo upgrade it.
                //
                // Why NOT pre-swap the id to response.messageId here:
                // a Twitch chat message includes the chatter's badges,
                // user-picked color, and Twitch's server-parsed fragments
                // (cheermotes, native emotes, mentions). The optimistic
                // line has NONE of those — it just has the plain text. The
                // echo path in `apply()` runs the chat message through
                // `Normalizer.normalize(...)` and replaces the optimistic
                // row wholesale, so the user's own message ends up
                // visually identical to everyone else's.
                //
                // If we'd pre-swapped the id, the echo would match the
                // dedup-by-id branch (drop) instead of the echo-of-pending
                // branch (upgrade), and the row would stay badge-less for
                // the rest of its life on screen.
                //
                // We don't need any local timeout/fallback: Twitch broadcasts
                // to the WebSocket on the same code path that responds to
                // the POST. If isSent=true came back, the echo is essentially
                // guaranteed to arrive within milliseconds.
                logger.debug("send: Helix accepted; awaiting EventSub echo to upgrade optimistic row")
                return
            }

            // isSent=false: Twitch returned 200 OK but didn't broadcast.
            // Common drop reasons: `msg_ratelimit`, `automod_held`,
            // `msg_banned`, `msg_emoteonly`, `msg_subsonly`,
            // `msg_followersonly`, `msg_slowmode`. The human-readable
            // `dropReason.message` is good enough for the toast.
            if pendingSendIDByText.removeValue(forKey: canonical) != nil {
                lines.removeAll { $0.id == pendingId }
            }
            sendError = response.dropReason?.message ?? "Twitch didn't broadcast the message."
            logger.notice("send dropped by Twitch: code=\(response.dropReason?.code ?? "unknown", privacy: .public) reason=\(response.dropReason?.message ?? "—", privacy: .public)")
        } catch {
            // Network blip, unauthorized after refresh-and-retry, or
            // ChannelSession.send's own empty-string guard. Drop optimistic
            // line + surface.
            if pendingSendIDByText.removeValue(forKey: canonical) != nil {
                lines.removeAll { $0.id == pendingId }
            }
            sendError = error.localizedDescription
            logger.error("send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// View-facing reset for the toast. Call after the toast finishes
    /// auto-dismissing so a second send error re-triggers the animation.
    public func clearSendError() {
        sendError = nil
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
    private func apply(_ event: ChannelSession.ChannelEvent) {
        // Special handling for chat-message events: dedup against echoes
        // of our own optimistic sends. Pulled out of the shared static
        // helper because dedup needs read access to `lines` and write
        // access to `pendingSendIDByText`, neither of which the static
        // (used for priming, where no pending sends exist) has.
        if case .message(let chatMessage) = event {
            // (1) dedup-by-id: we already swapped the optimistic line to
            // the canonical messageId after the Helix response, and now
            // the EventSub echo arrives carrying the same id. Skip it —
            // the row already exists with the right id.
            if lines.contains(where: { $0.id == chatMessage.messageId }) {
                return
            }

            // (2) echo-of-pending: the EventSub echo beat our Helix POST
            // response. Find our optimistic line by text+sender match and
            // replace it with the normalized echo (canonical id, Twitch's
            // server-parsed fragments).
            //
            // Why match `chatterUserId` AND text: two users could send
            // the same string within milliseconds — only one of them is
            // ours, and ours is the one whose chatterUserId matches our
            // signed-in account.
            if chatMessage.chatterUserId == currentUserId,
               let pendingId = pendingSendIDByText.removeValue(forKey: chatMessage.message.text) {
                let snapshot = emoteIndex?.snapshot() ?? [:]
                let normalizedLine = Normalizer.normalize(
                    message: chatMessage,
                    emoteSnapshot: snapshot,
                    currentUserLogin: currentUserLogin,
                    highlightKeywords: highlightKeywords
                )
                if let idx = lines.firstIndex(where: { $0.id == pendingId }) {
                    lines[idx] = normalizedLine
                    return
                }
                // The optimistic row was removed under us (e.g., we hit
                // a Helix error that wiped it) before the echo arrived.
                // Fall through to the normal-append path so the echo
                // still shows up — Twitch saw the message, the user
                // deserves to see it too.
            }
        }

        Self.appendLines(for: event, into: &lines, normalizationContext: self)
        if lines.count > Self.lineCap {
            lines.removeFirst(lines.count - Self.lineCap)
        }
    }

    /// Convert one `ChannelEvent` into zero-or-more ChatLine mutations and
    /// apply them to the given lines array. Pulled out as a static so the
    /// priming loop in `attach()` can reuse it without capturing `self`
    /// into closures (which would require Sendable gymnastics) and so
    /// future tests can exercise the dispatch logic in isolation.
    ///
    /// `normalizationContext` carries the emote-index snapshot, current
    /// user login, and highlight keywords — used for `.message` events.
    /// Other event kinds don't depend on these.
    private static func appendLines(
        for event: ChannelSession.ChannelEvent,
        into lines: inout [ChatLine],
        normalizationContext: TabChatModel
    ) {
        switch event {
        case .message(let chatMessage):
            // EmoteIndex.snapshot() is nonisolated + lock-protected, so
            // it's safe to call from @MainActor without an await.
            let snapshot = normalizationContext.emoteIndex?.snapshot() ?? [:]
            let line = Normalizer.normalize(
                message: chatMessage,
                emoteSnapshot: snapshot,
                currentUserLogin: normalizationContext.currentUserLogin,
                highlightKeywords: normalizationContext.highlightKeywords
            )
            lines.append(line)

        case .notification(let n):
            // The Normalizer skips notice types we don't render (returns
            // nil) — those are dropped here. Logging the skip is the
            // caller's job; the Normalizer stays sync-and-pure.
            if let line = Normalizer.line(from: n) {
                lines.append(line)
            }

        case .raid(let r):
            lines.append(Normalizer.line(from: r))

        case .messageDeleted(let targetMessageId):
            // Mutation in place: find the row by id, replace with a
            // deletedPlaceholder-kind copy. We DON'T remove the row —
            // a vanishing line is disorienting mid-scroll, and keeping
            // it as a strikethrough is the Twitch web convention.
            if let idx = lines.firstIndex(where: { $0.id == targetMessageId }) {
                lines[idx] = lines[idx].withDeletedPlaceholder()
            }

        case .chatCleared:
            // Flip every existing line to deletedPlaceholder. Future
            // messages still arrive normally — this only retroactively
            // hides the scrollback.
            //
            // In-place mutation (vs `lines.map { ... }`) avoids
            // allocating a fresh 500-element array per chat-clear event.
            // The @Observable property still publishes one change per
            // element-write, but storage stays in place.
            for idx in lines.indices {
                lines[idx] = lines[idx].withDeletedPlaceholder()
            }

        case .messagesClearedFromUser(let targetUserId):
            // Flip every line whose author is the timed-out/banned user.
            // Required field `authorUserId` on ChatLine is what makes
            // this work — without it we'd have no key to match against.
            //
            // In-place mutation: only touches lines that match the
            // target. Busy channels can see several timeouts per minute;
            // avoiding the full-array .map per event is meaningful at
            // 500-line ring buffers.
            for idx in lines.indices where lines[idx].authorUserId == targetUserId {
                lines[idx] = lines[idx].withDeletedPlaceholder()
            }
        }
    }

    /// Trim a pre-built array to the cap. Used during the initial prime when
    /// merging multiple sessions' snapshots — if their combined sizes exceed
    /// the cap, keep the most recent.
    private static func cap(_ lines: [ChatLine]) -> [ChatLine] {
        if lines.count <= lineCap { return lines }
        return Array(lines.suffix(lineCap))
    }
}
