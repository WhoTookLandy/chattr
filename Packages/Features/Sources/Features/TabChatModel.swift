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
    private var pendingSendIDByText: [String: String] = [:]

    /// Surfaced to the view via @Observable so the compose bar can show a
    /// transient error toast when a send fails (Twitch dropped it,
    /// HelixError surfaced, network blip). nil clears the toast.
    public var sendError: String?

    /// When non-nil, the compose bar renders a "Replying to …" chip and
    /// the next send is threaded onto this message. Set by `beginReply(to:)`,
    /// cleared by `cancelReply()` (user dismissed the chip) or
    /// automatically inside `send(...)` after a reply ships.
    ///
    /// We carry both the message ID (what Twitch needs to thread) and
    /// the author + a snippet of the body (what the user needs to
    /// remember which message they're replying to).
    public var replyContext: ReplyContext?

    /// Payload for an in-flight reply intent. Held by `replyContext`;
    /// passed to `ChannelSession.send` as `replyParentMessageId` when
    /// the user finally taps Send.
    public struct ReplyContext: Sendable, Equatable {
        public let parentMessageId: String
        public let parentAuthorDisplayName: String
        public let parentSnippet: String      // already-truncated so the view doesn't need to

        public init(parentMessageId: String, parentAuthorDisplayName: String, parentSnippet: String) {
            self.parentMessageId = parentMessageId
            self.parentAuthorDisplayName = parentAuthorDisplayName
            self.parentSnippet = parentSnippet
        }
    }

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

        // Snapshot the reply context now and clear it immediately. We
        // clear up-front so the chip disappears from the compose bar at
        // the same time the optimistic row appears — feels deliberate,
        // and prevents the user from "double-attaching" a reply by
        // hitting send twice fast.
        //
        // If send fails, the parent message is still in chat so the
        // user can long-press → reply again. We don't try to restore
        // the chip on failure because that would require carrying
        // reply state on the .failed line, which is more complexity
        // than the rare retry-a-reply case justifies.
        let replyAttachment = replyContext
        replyContext = nil

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
            timestamp: .now,
            deliveryState: .sending     // renderer dims the row so the user sees it as in-flight
        )
        lines.append(optimistic)
        // Cap as usual — sending while at 500 lines drops the oldest, same
        // as a received message would.
        if lines.count > Self.lineCap {
            lines.removeFirst(lines.count - Self.lineCap)
        }
        pendingSendIDByText[canonical] = pendingId

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
                // `lines`. The echo may have ALREADY arrived during our
                // await on session.send — it would have reconciled via
                // the text fallback (Path 2), removed the optimistic
                // row, and the entry we'd write here would be a dead
                // letter. Skipping the write avoids a tiny memory leak
                // and a stale entry that could (extremely unlikely) match
                // a future event with the same messageId.
                if lines.contains(where: { $0.id == pendingId }) {
                    helixMessageIdByPendingId[pendingId] = response.messageId
                } else {
                    // Echo already reconciled — defensive sweep in case the
                    // text-map entry didn't get cleaned by the echo path
                    // (it should have via cleanupPending, but the cost of
                    // a no-op removal is zero).
                    pendingSendIDByText.removeValue(forKey: canonical)
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
        guard let idx = lines.firstIndex(where: { $0.id == failedLineId }),
              case .failed(_, let retryText) = lines[idx].deliveryState else {
            return
        }
        // Remove the failed row first so the new optimistic insert
        // takes its place at the bottom of `lines` — the user expects
        // the retry to feel like a fresh send.
        lines.remove(at: idx)
        await send(text: retryText)
    }

    /// Transitions the pending row identified by `pendingId` to the
    /// `.failed` state in place. Pulled out of `send` so both the
    /// Helix-drop and thrown-error paths share the same code.
    ///
    /// If the row isn't in `lines` anymore (rare — could happen if a
    /// moderator's `chatCleared` event raced our failure) we DON'T
    /// re-insert it; the user already saw the row vanish via the
    /// chat-clear handler, and resurrecting it would be jarring.
    private func markFailed(pendingId: String, reason: String, retryText: String) {
        guard let idx = lines.firstIndex(where: { $0.id == pendingId }) else { return }
        let row = lines[idx]
        lines[idx] = ChatLine(
            id: row.id,
            kind: row.kind,
            authorBadges: row.authorBadges,
            originalBadges: row.originalBadges,
            authorUserId: row.authorUserId,
            authorDisplayName: row.authorDisplayName,
            authorColor: row.authorColor,
            runs: row.runs,
            isHighlighted: row.isHighlighted,
            timestamp: row.timestamp,
            deliveryState: .failed(reason: reason, retryText: retryText)
        )
    }

    /// View-facing reset for the toast. Call after the toast finishes
    /// auto-dismissing so a second send error re-triggers the animation.
    public func clearSendError() {
        sendError = nil
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
        let snippet = Self.snippet(from: line.runs, cap: 80)
        replyContext = ReplyContext(
            parentMessageId: line.id,
            parentAuthorDisplayName: line.authorDisplayName,
            parentSnippet: snippet
        )
    }

    /// User dismissed the reply chip without sending. Clears the
    /// pending attachment.
    public func cancelReply() {
        replyContext = nil
    }

    /// Build a short, single-line preview of a message's runs for the
    /// reply chip. Emote and twitchEmote runs become their name (in
    /// angle brackets so the user sees "<KEKW>" rather than blank space
    /// where the emote image would have rendered). URL and cheermote
    /// runs render as their text. The total is capped with an ellipsis.
    private static func snippet(from runs: [LineRun], cap: Int) -> String {
        var out = ""
        for run in runs {
            switch run {
            case .text(let s):
                out += s
            case .emote(let e):
                out += e.name
            case .twitchEmote(_, let display):
                out += display
            case .mention(let login, _):
                out += "@\(login)"
            case .url(let s):
                out += s
            case .cheermote(let prefix, let bits, _):
                out += "\(prefix)\(bits)"
            }
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
    private func apply(_ event: ChannelSession.ChannelEvent) {
        // Special handling for chat-message events: reconcile against the
        // optimistic rows we inserted from `send(...)`. Pulled out of the
        // shared static helper because reconciliation needs read access to
        // `lines` and write access to both correlation maps — neither of
        // which the static (used for priming, where no pending sends
        // exist) has.
        if case .message(let chatMessage) = event {
            // ─── Path 0 (primary): Helix-id match ────────────────────
            //
            // We learned this messageId from `sendChatMessage`'s response.
            // Unambiguous — Twitch's messageId is globally unique per send.
            // Handles every case except "echo arrived before Helix
            // returned" (Path 2 catches that one).
            if let matchedPendingId = helixMessageIdByPendingId.first(where: { $0.value == chatMessage.messageId })?.key {
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
            if lines.contains(where: { $0.id == chatMessage.messageId }) {
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
            if chatMessage.chatterUserId == currentUserId,
               let matchedPendingId = pendingSendIDByText[chatMessage.message.text] {
                cleanupPending(pendingId: matchedPendingId)
                if upgradeOptimistic(at: matchedPendingId, with: chatMessage) { return }
                // Optimistic row was removed under us — fall through to
                // normal append.
            }
        }

        Self.appendLines(for: event, into: &lines, normalizationContext: self)
        if lines.count > Self.lineCap {
            lines.removeFirst(lines.count - Self.lineCap)
        }
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
        guard let idx = lines.firstIndex(where: { $0.id == pendingId }) else {
            return false
        }
        let snapshot = emoteIndex?.snapshot() ?? [:]
        let normalizedLine = Normalizer.normalize(
            message: chatMessage,
            emoteSnapshot: snapshot,
            currentUserLogin: currentUserLogin,
            highlightKeywords: highlightKeywords
        )
        lines[idx] = normalizedLine
        return true
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
        if let textKey = pendingSendIDByText.first(where: { $0.value == pendingId })?.key {
            pendingSendIDByText.removeValue(forKey: textKey)
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
