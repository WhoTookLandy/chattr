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

    /// Case-insensitive substrings that trigger row highlighting. Empty
    /// by default — keyword highlighting disabled.
    private var highlightKeywords: [String] = []

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
        currentUserLogin: String = "",
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
        self.currentUserLogin = currentUserLogin
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

    // MARK: - Internals

    /// Apply one `ChannelEvent` to the `lines` array. Called from the
    /// per-session subscriber handler when a new event arrives, and (via
    /// the appendLines helper) on each event in the priming snapshot.
    ///
    /// Dispatch:
    ///   - `.message`  → normalize + append a `.message` ChatLine
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
