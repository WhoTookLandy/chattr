import Foundation
import Observation   // for @Observable — pulled from Observation rather than SwiftUI
                     // so this model has no SwiftUI dependency, matching its actual surface
import TwitchKit
import Channels
import ChatModel
import Core
import os

private let logger = AppLogger.make("Features.ChatTranscriptModel")

/// `apply-batch`: the main-actor half of the message pipeline (one interval
/// per drained batch). Pair with `Channels.Pipeline`'s `normalize` /
/// `deliver` intervals in Instruments.
private let signposter = AppLogger.signposter("Features.ChatTranscriptModel")

/// Per-tab chat transcript. Subscribes to one or more `ChannelSession`s and
/// surfaces one observable transcript for `ChatScreen`, `ChatTranscript` /
/// `ChatListView` and `ThreadView`.
///
/// A thin coordinator over focused collaborators, one concern each:
///   - `SessionAttachment` — subscriptions, mailbox draining, attach epochs.
///   - `TranscriptStore` — the rows and their coalesced, versioned changes.
///   - `ChatViewerPolicy` — this attach's chat filters and highlight keywords.
///   - `OutgoingMessages` — optimistic sends: pending → echo → delivered /
///     failed, plus the stuck-send fallback (its pure state machine is
///     `OutgoingMessageReconciler`).
///   - `SelfChatter` — the signed-in user's identity and learned styling.
///   - `ChannelModerationState` — mod status (detection, revocation), deletes.
///   - `ChatRoomState` — chat restrictions and chat-mode changes.
///   - `OwnChatRestrictionState` — our own timeout / ban / warning here.
///   - `ChatTranscriptDependencies` — settings reads, drafts, the sound.
/// What stays here is the routing between them: where each session update
/// goes, and the send / retry / reprime flows that span several of them.
///
/// Lifecycle: `ChatScreen`'s session-lifecycle `.task` calls `attach`, and
/// `detach(ifEpoch:)` with the returned epoch when SwiftUI cancels it; the
/// sessions stay alive in the registry (other tabs may share them).
///
/// Why `@MainActor`: the observed surface drives SwiftUI body recomputes.
/// The main actor does as little as possible per message: rows arrive
/// normalized by `ChannelSession` (once per channel, off-main), one batch per
/// mailbox drain, each row costing an O(1) buffer mutation plus echo
/// reconciliation; publishing is coalesced to ~one flush per frame.
///
/// Multi-channel tabs (future): `attach(sessions: [a, b, c])` already
/// subscribes to all of them, rows landing in arrival order; merging them
/// chronologically is a TODO for when that ships.
@MainActor
@Observable
public final class ChatTranscriptModel {

    /// Three-state attach lifecycle for the transcript's empty state.
    /// `Equatable` so the `@Observable` setter can short-circuit invalidation
    /// when the same state is re-assigned.
    public enum AttachState: Sendable, Equatable {
        case detached    // no sessions registered
        case attaching   // attach in flight
        case attached    // all subscriptions live
    }

    // MARK: - Collaborators

    private let store: TranscriptStore
    private let outgoing: OutgoingMessages
    private let attachment: SessionAttachment
    private let moderation: ChannelModerationState
    private let room: ChatRoomState
    private let dependencies: ChatTranscriptDependencies

    /// Why the signed-in user can't chat here (timed out, banned, warned),
    /// if anything. Its own `@Observable` so only the banner and the compose
    /// bar observe it — never the transcript. A `let`, so reaching it
    /// registers no dependency on this model.
    let ownRestriction: OwnChatRestrictionState

    @ObservationIgnored private var policy = ChatViewerPolicy()
    @ObservationIgnored private var selfChatter = SelfChatter()

    /// Composite `ChannelDescriptor.ID` whose persisted draft a send clears.
    /// Supplied by the view at attach (it owns the descriptor — the model
    /// never composes platform-qualified keys). Empty (tests) skips clearing.
    @ObservationIgnored private var draftKey: ChannelDescriptor.ID = ""

    public convenience init() {
        self.init(dependencies: .live)
    }

    /// Tests inject `dependencies` to keep UserDefaults, the draft store and
    /// the speaker out of the picture.
    init(dependencies: ChatTranscriptDependencies) {
        let store = TranscriptStore()
        self.store = store
        self.outgoing = OutgoingMessages(store: store)
        self.attachment = SessionAttachment()
        self.moderation = ChannelModerationState()
        self.room = ChatRoomState()
        self.ownRestriction = OwnChatRestrictionState()
        self.dependencies = dependencies
    }

    // MARK: - Observed surface

    /// Block-filtered, display-ready lines; re-evaluates a reading body once
    /// per flush (the non-UIKit list). The UIKit list pulls `changes(since:)`
    /// instead.
    public var lines: [ChatLine] { store.lines }

    /// The signed-in user's login ("" when anonymous) — so @-mention
    /// suggestions can leave you out.
    var selfLogin: String { selfChatter.login }

    /// True when no line is visible. Invalidates only when it flips.
    var isEmpty: Bool { store.isEmpty }

    /// The change channel's head — the only per-flush observed trigger.
    var changeVersion: Int { store.changeVersion }

    public var attachState: AttachState { attachment.state }

    /// The attached session, for consumers with their own feed from it — the
    /// live-event banners (`LiveEventsBannerArea`) subscribe here once
    /// `attachState` reaches `.attached`. Not observed: read it when
    /// `attachState` changes.
    var liveEventsSession: ChannelSession? { attachment.primarySession }

    /// Blocked user ids, pushed in by the view (which observes `BlockStore`).
    /// Changing it re-filters the visible lines immediately.
    public var blockedIds: Set<String> {
        get { store.blockedIds }
        set { store.blockedIds = newValue }
    }

    /// Per-channel chat restrictions; nil until the attach-time read lands.
    /// The compose bar renders an inline strip when any is active.
    public var chatRestrictions: ChatRestrictions? { room.restrictions }

    /// True when the signed-in account can moderate the attached channel —
    /// drives ChatRow's Delete Message affordance and the mod-only chat
    /// modes. See `ChannelModerationState` for how it's learned.
    public var currentUserCanModerate: Bool { moderation.canModerate }

    /// In-flight moderated-channels seed, exposed so tests can await it.
    var moderationSeedTask: Task<Void, Never>? { moderation.seedTask }

    /// The one error with no row to attach to (no attached session, a failed
    /// delete) — shown as an alert. Send failures surface inline on the
    /// failed row instead.
    public var sendError: String?

    /// Bindable Bool view of `sendError` for `.alert(isPresented:)`, so
    /// `ChatScreen.body` doesn't rebuild a `Binding(get:set:)` on every
    /// render. The setter only acts on `false` (dismiss).
    public var isShowingSendError: Bool {
        get { sendError != nil }
        set { if !newValue { sendError = nil } }
    }

    /// When non-nil, the compose bar shows a "Replying to …" chip and the
    /// next send threads onto this message. Set by `beginReply(to:)`,
    /// cleared by `cancelReply()` or by the send that uses it.
    public var replyContext: ReplyContext?

    /// Bumped each time a main-transcript send (compose bar, retry) puts the
    /// user's optimistic row in the transcript. `ChatTranscript` re-pins to
    /// the live edge on every change, so a message sent while reading
    /// scrollback shows at once instead of being held back with the rest of
    /// the unread backlog.
    private(set) var outgoingSendCount = 0

    // MARK: - Change channel (see `TranscriptStore`)

    /// Publishes pending changes now. Internal so tests can flush
    /// deterministically instead of sleeping out the coalescing window.
    func flushPendingChanges() {
        store.flushPendingChanges()
    }

    /// Every change published after `version`, or `.overrun`. Observation-
    /// free: safe from `updateUIViewController`, `onChange`, scroll callbacks.
    func changes(since version: Int) -> ChatChangeLog.Delta {
        store.changes(since: version)
    }

    /// The visible lines plus the exact log version they reflect.
    func transcriptSnapshot() -> (version: Int, lines: [ChatLine]) {
        store.snapshot()
    }

    /// Every line of the thread rooted at `rootMessageId`, in order.
    public func lines(inThreadRootedAt rootMessageId: String) -> [ChatLine] {
        store.lines(inThreadRootedAt: rootMessageId)
    }

    /// The thread's lines plus the version they reflect — the thread sheet's
    /// counterpart of `transcriptSnapshot()`.
    func threadSnapshot(rootedAt rootMessageId: String) -> (version: Int, lines: [ChatLine]) {
        store.threadSnapshot(rootedAt: rootMessageId)
    }

    // MARK: - Attach / detach

    /// Subscribes to each session, primes the transcript from their combined
    /// current state, and starts draining new rows from each mailbox.
    /// Overlapping attaches resolve by epoch — the LAST one wins (see
    /// `SessionAttachment`); an attach after a completed one re-subscribes.
    ///
    /// - Parameters:
    ///   - highlightKeywords / lineCap: viewer settings read at attach time.
    ///   - draftKey: the composite `ChannelDescriptor.ID` whose draft a send
    ///     clears. Empty (the default, used by tests) skips draft clearing.
    ///   - moderatedChannelIds / onModerationRevoked: the registry's cached
    ///     moderated-set and its eviction — see `ChannelModerationState`.
    /// - Returns: the epoch this call established, for `detach(ifEpoch:)`.
    @discardableResult
    public func attach(
        sessions: [ChannelSession],
        currentUserId: String = "",
        currentUserLogin: String = "",
        currentUserDisplayName: String = "",
        highlightKeywords: [String] = [],
        lineCap: Int = 500,
        draftKey: ChannelDescriptor.ID = "",
        moderatedChannelIds: (@Sendable () async -> Set<String>)? = nil,
        onModerationRevoked: (@Sendable () async -> Void)? = nil
    ) async -> Int {
        // Claimed before any await; re-checked after every suspension.
        let epoch = attachment.claimEpoch()
        store.resize(toCap: lineCap)

        // Tear down any prior subscriptions (unconditional — `ifEpoch: nil`).
        await detach(ifEpoch: nil)
        guard attachment.isCurrent(epoch) else { return epoch }

        // Per-viewer context, consulted for every inbound row. The filter
        // toggles are snapshotted here (like the keywords) so live rows and
        // re-primed history can't drift on a mid-session toggle.
        selfChatter.userId = currentUserId
        selfChatter.login = currentUserLogin
        selfChatter.displayName = currentUserDisplayName
        policy = ChatViewerPolicy(
            viewerUserId: currentUserId,
            filters: dependencies.chatFilters(),
            highlightKeywords: highlightKeywords
        )
        moderation.onRevoked = onModerationRevoked

        guard let subscribed = await attachment.subscribe(to: sessions, epoch: epoch) else {
            return epoch   // superseded mid-subscribe
        }
        self.draftKey = draftKey

        if let session = sessions.first {
            await room.prime(from: session)
            guard attachment.isCurrent(epoch) else { return epoch }
            // Our own timeout / ban lives on the session (it outlives this
            // page); a remounted page picks up the banner and the remaining
            // countdown from there.
            let ownLedger = await session.ownChatRestriction()
            guard attachment.isCurrent(epoch) else { return epoch }
            ownRestriction.restore(from: session, ledger: ownLedger)
            moderation.seed(from: session, moderatedChannelIds: moderatedChannelIds)
            seedSelfColor(from: session)
        }

        // Prime by replaying the snapshot through the same ingest the live
        // path uses, so there's no separate "initial state" path to drift.
        // Single-session tabs arrive in order; multi-session tabs would sort
        // by timestamp here (TODO when N > 1 ships).
        outgoing.forgetLocallySettled()
        store.replay(subscribed.snapshot, policy: policy)
        store.publishPending()

        attachment.startDraining(subscribed.subscriptions) { [weak self] batch in
            guard let self else { return false }
            self.apply(batch)
            return true
        }
        logger.info("ChatTranscriptModel attached to \(sessions.count) session(s) [epoch \(epoch)], primed with \(self.store.currentLines.count) line(s)")
        return epoch
    }

    /// Unsubscribes from every session. Safe to call repeatedly.
    ///
    /// - Parameter ifEpoch: when non-nil, tears down only if that epoch is
    ///   still current — so a dying screen appearance can't detach a model a
    ///   newer appearance just re-attached. `nil` (attach's own teardown)
    ///   always tears down.
    public func detach(ifEpoch epoch: Int? = nil) async {
        if let epoch, !attachment.isCurrent(epoch) { return }
        // Even with no subscriptions: stuck-send wakes must not outlive the
        // attach, and a late moderated-set result must not flip the flag for
        // whatever channel this model attaches to next.
        outgoing.cancelFallbacks()
        moderation.cancelSeed()
        ownRestriction.detachSession()
        let removed = await attachment.tearDown()
        if removed > 0 {
            logger.info("ChatTranscriptModel detached \(removed) subscription(s)")
        }
    }

    // MARK: - Send

    /// Sends a chat message via the first attached session (single-channel
    /// MVP), optimistically: the row appears at once as `.sending`; Helix
    /// accepting leaves it for the echo (or the stuck-send fallback) to
    /// settle, a drop or thrown error turns it `.failed` in place with
    /// tap-to-retry. See `OutgoingMessages`.
    ///
    /// Three paths share it: a plain send, a reply (the main bar's chip, then
    /// cleared), and a thread send (`replyOverride`, from the thread sheet —
    /// which leaves the main bar's chip alone; the user may be mid-reply).
    ///
    /// - Parameter repinsTranscript: whether the main transcript should jump
    ///   to the live edge to show the new row (see `outgoingSendCount`). The
    ///   thread sheet passes false: it shows the row itself, and yanking the
    ///   list behind it would lose the reader's place in scrollback.
    /// - Parameter fromMainComposer: whether this send came from the MAIN
    ///   compose bar. Only such a send consumes that bar's state: its pending
    ///   reply chip (`replyContext`) and its persisted draft (`draftKey`). The
    ///   thread sheet's composer and a failed-row retry pass false — their
    ///   text and reply target never came from the main bar, so they must
    ///   neither discard what the user has half-typed there nor hijack a
    ///   reply chip the user just selected. With false, the reply is exactly
    ///   `replyOverride` (nil = not a reply).
    public func send(
        text: String,
        replyOverride: ReplyContext? = nil,
        repinsTranscript: Bool = true,
        fromMainComposer: Bool = true
    ) async {
        // Trim exactly as `ChannelSession.send` does, or the echo's text
        // match would miss.
        let canonical = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonical.isEmpty else { return }
        guard let session = attachment.primarySession else {
            sendError = "Not connected to chat."
            return
        }

        let reply: ReplyContext?
        if let replyOverride {
            reply = replyOverride
        } else if fromMainComposer {
            reply = replyContext
            replyContext = nil
        } else {
            reply = nil
        }

        // Starting the send is the deliberate draft-clear point: the message
        // is on screen from here, and a failed row offers Retry — restoring
        // the draft on failure would only confuse.
        if fromMainComposer, !draftKey.isEmpty {
            dependencies.clearDraft(draftKey)
        }

        let pendingId = outgoing.begin(text: canonical) { id in
            selfChatter.optimisticLine(id: id, text: canonical, replyingTo: reply)
        }
        if repinsTranscript {
            outgoingSendCount &+= 1
        }
        do {
            let response = try await session.send(canonical, replyParentMessageId: reply?.parentMessageId)
            if response.isSent {
                // Leave the row for the echo to upgrade (pre-swapping the id
                // would dedup the echo away, losing its badges / colour /
                // parsed fragments); Helix's id becomes the primary key.
                outgoing.accepted(pendingId: pendingId, messageId: response.messageId)
                logger.debug("send: Helix accepted; awaiting EventSub echo to upgrade optimistic row")
                return
            }
            // 200 OK but not broadcast: rate limit, AutoMod hold, emote-only,
            // slow mode… Failing in place keeps what the user typed.
            let reason = response.dropReason?.message ?? "Twitch didn't broadcast the message."
            outgoing.failed(pendingId: pendingId, reason: reason, retryText: canonical)
            logger.notice("send dropped by Twitch: code=\(response.dropReason?.code ?? "unknown", privacy: .public) reason=\(reason, privacy: .public)")
            // Timed out / banned / warned: `session.send` already recorded
            // the precise state (and the timeout's end) unless a newer clear
            // or echo made it stale; the banner and compose bar sync to it.
            if OwnChatRestriction(dropCode: response.dropReason?.code, message: response.dropReason?.message) != nil {
                ownRestriction.syncAfterRejectedSend(on: session)
            }
        } catch HelixError.forbidden(let apiError) {
            // Twitch answers a banned sender with 403 rather than a drop.
            outgoing.failed(pendingId: pendingId, reason: apiError.message, retryText: canonical)
            logger.error("send forbidden: \(apiError.message, privacy: .public)")
            if OwnChatRestriction(dropCode: nil, message: apiError.message) != nil {
                ownRestriction.syncAfterRejectedSend(on: session)
            }
        } catch {
            // Network blip, unauthorized after refresh-and-retry, … — same
            // treatment as a drop.
            outgoing.failed(pendingId: pendingId, reason: error.localizedDescription, retryText: canonical)
            logger.error("send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-sends a failed row's text, threaded against the same parent it
    /// replied to. No-ops unless the row is actually `.failed` (a triple-tap
    /// on Retry mid-retry).
    public func retry(failedLineId: String) async {
        guard let failedRow = store.line(id: failedLineId),
              case .failed(_, let retryText) = failedRow.deliveryState else {
            return
        }
        // Check before removing the row: with no session the send below would
        // bail, and the message the user wanted to retry would be gone.
        guard attachment.primarySession != nil else {
            sendError = "Not connected to chat."
            return
        }
        let preservedReply = failedRow.replyParent.map { ReplyContext($0) }
        // Remove first so the retry lands at the bottom like a fresh send,
        // and its echo can't find two rows.
        store.remove(id: failedLineId)
        store.publishPending()
        // The retried text and reply target come from the failed row, not
        // the compose bar — whatever the user has typed or selected there
        // since must survive, and a non-reply stays a non-reply.
        await send(text: retryText, replyOverride: preservedReply, fromMainComposer: false)
    }

    /// View-facing reset for the error alert.
    public func clearSendError() {
        sendError = nil
    }

    // MARK: - Reply

    /// Attaches a reply to the next send. Only `.message` rows can be
    /// replied to (Twitch has no replies to system rows); the row's menu only
    /// offers Reply there anyway.
    public func beginReply(to line: ChatLine) {
        guard case .message = line.kind else { return }
        replyContext = Self.replyContext(for: line)
    }

    /// The user dismissed the reply chip without sending.
    public func cancelReply() {
        replyContext = nil
    }

    // MARK: - Moderation & chat modes

    /// Asks Twitch to delete one message; the delete echo then flips the row.
    /// The caller only offers this when `currentUserCanModerate`; the server
    /// has the final say, and a refusal surfaces as `sendError`.
    public func deleteMessage(withId messageId: String) async {
        guard let session = attachment.primarySession else {
            sendError = "Not connected to chat."
            return
        }
        do {
            try await moderation.deleteMessage(withId: messageId, in: session)
        } catch {
            sendError = "Couldn't delete message: \(error.localizedDescription)"
        }
    }

    /// The session moderation actions target (`ChatTranscriptModel+UserModeration`).
    var primarySession: ChannelSession? { attachment.primarySession }

    /// Forwards a chat-mode change (emote-only, subs-only, followers-only,
    /// slow mode) to the attached channel — see `ChatRoomState.updateSettings`.
    public func updateChatSettings(
        emoteOnly: Bool? = nil,
        subscribersOnly: Bool? = nil,
        followersOnly: Bool? = nil,
        followersDurationMinutes: Int? = nil,
        slowMode: Bool? = nil,
        slowModeSeconds: Int? = nil
    ) async throws {
        try await room.updateSettings(
            on: attachment.primarySession,
            emoteOnly: emoteOnly,
            subscribersOnly: subscribersOnly,
            followersOnly: followersOnly,
            followersDurationMinutes: followersDurationMinutes,
            slowMode: slowMode,
            slowModeSeconds: slowModeSeconds
        )
    }

    // MARK: - Applying session updates

    /// Applies one drained batch — everything the session posted since the
    /// last drain — in a single main-actor turn, then schedules ONE coalesced
    /// publish for all of it. Called by the drain tasks `attach` starts;
    /// internal so tests can drive updates directly.
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
        store.publishPending()
    }

    /// Single-update convenience over `apply(_:)` (tests).
    func apply(_ update: ChannelUpdate) {
        apply([update])
    }

    /// Routes one update. Rows arrive normalized by the session; this decides
    /// only what each one does to THIS transcript.
    private func applyOne(_ update: ChannelUpdate) {
        switch update {
        case .restrictionsUpdated(let restrictions):
            room.apply(restrictions)
        case .moderationStatusChanged(let canModerate):
            moderation.apply(canModerate: canModerate, session: attachment.primarySession)
            logger.info("Mod status changed mid-session for #\(self.draftKey, privacy: .public): canModerate=\(canModerate)")
        case .reprime(let snapshot):
            // Late join history landed above live rows, or this subscriber
            // fell too far behind: rebuild from the session's snapshot.
            reprime(with: snapshot)
        case .message(let normalized):
            applyLiveMessage(normalized)
        case .messagesClearedFromUser(let targetUserId):
            // A mod timed out / banned someone. When that someone is US, the
            // banner explains why our messages vanished (synced from the
            // session, which recorded the clear first). One string compare
            // per clear event — never per message.
            if !selfChatter.userId.isEmpty, targetUserId == selfChatter.userId {
                ownRestriction.noteOwnMessagesCleared()
                logger.notice("Own messages cleared by a moderator in #\(self.draftKey, privacy: .public)")
            }
            store.ingest(update, policy: policy)
        case .row, .messageDeleted, .chatCleared:
            store.ingest(update, policy: policy)
        }
    }

    /// A live chat message: filter, reconcile against our own pending sends,
    /// else append — and maybe ping.
    private func applyLiveMessage(_ normalized: NormalizedMessage) {
        let message = normalized.message
        // Filter first: a hidden message must not reach echo reconciliation,
        // ingest, or the highlight sound (which reads the newest row and
        // would otherwise ping off a stale one). Own messages are exempt.
        if policy.hides(message) { return }
        observeOwnEcho(message)

        let consumed = outgoing.reconcileEcho(of: message, isOwn: selfChatter.wrote(message)) {
            policy.presenting(normalized.line)
        }
        if consumed { return }
        store.ingest(.message(normalized), policy: policy)
        playHighlightSoundIfNeeded(for: normalized)
    }

    /// Pings for a freshly appended highlighted row (`store.last`: a
    /// self-mention or keyword match) — only LIVE (history never pings),
    /// only someone else's (an own message here is a failed send's late
    /// echo), never a blocked user's. The setting is read last, so only an
    /// actual candidate pays for it.
    private func playHighlightSoundIfNeeded(for normalized: NormalizedMessage) {
        guard !normalized.line.isHistorical,
              !selfChatter.wrote(normalized.message),
              !store.blockedIds.contains(normalized.message.chatterUserId),
              store.last?.isHighlighted == true,
              dependencies.isHighlightSoundEnabled() else { return }
        dependencies.playHighlightSound()
    }

    /// What our OWN echoes teach (no-op for anyone else's): a mod badge proves
    /// mod status; colour and badges style the next optimistic row. Shared
    /// with `reprime`, so an echo seen only in a snapshot still counts.
    private func observeOwnEcho(_ message: ChatMessage) {
        guard selfChatter.wrote(message) else { return }
        // Twitch broadcast one of ours, so whatever restriction we inferred
        // is over (timeout lapsed, unbanned, warning acknowledged). The
        // session recorded that already; while restricted this syncs.
        ownRestriction.noteOwnMessageDelivered()
        if moderation.observeOwnEcho(message, session: attachment.primarySession) {
            logger.info("Detected mod status from echoed badges for #\(self.draftKey, privacy: .public)")
        }
        selfChatter.learnStyle(fromOwnEcho: message)
    }

    /// Rebuilds from a session snapshot (the replay attach primes with),
    /// re-appending at the tail the local-only rows the session's ring never
    /// held — sends in flight, failed, or settled locally.
    ///
    /// Own echoes NEW to this transcript (they sat in the backlog the reprime
    /// replaced) already have their rows in the snapshot, so the send each
    /// answers is settled and its optimistic row dropped rather than swapped.
    /// Only new echoes count, so an old identical message in late history
    /// can't settle a fresh send.
    private func reprime(with snapshot: [ChannelUpdate]) {
        let previousLines = store.currentLines
        let previousIds = Set(previousLines.map(\.id))
        let localRows = previousLines.filter { outgoing.isLocalOnly($0) }

        store.replay(snapshot, policy: policy)

        var settledPendingIds = Set<String>()
        for update in snapshot {
            guard case .message(let normalized) = update,
                  selfChatter.wrote(normalized.message),
                  !previousIds.contains(normalized.message.messageId) else { continue }
            observeOwnEcho(normalized.message)
            if let settled = outgoing.settlePending(answeredBy: normalized.message) {
                settledPendingIds.insert(settled)
            }
        }

        var kept = 0
        for row in localRows where !settledPendingIds.contains(row.id) && !store.contains(id: row.id) {
            store.append(row)
            kept += 1
        }
        outgoing.pruneLocallySettled()
        // The live updates this replaces may have included our own clear or
        // echo (a mailbox overflow drops them) — and the snapshot only
        // carries rows. The session's ledger saw them all: resync from it
        // (one actor hop per reprime, adopted by generation).
        ownRestriction.resync()
        logger.info("ChatTranscriptModel re-primed from \(snapshot.count) session update(s); kept \(kept) local row(s), settled \(settledPendingIds.count) send(s) by echo")
    }

    /// Seeds the optimistic rows' colour from /chat/color so even the first
    /// send renders styled. Fire-and-forget; fills only while still empty, so
    /// a colour an echo taught us meanwhile wins.
    private func seedSelfColor(from session: ChannelSession) {
        guard selfChatter.color.isEmpty else { return }
        Task { [weak self] in
            guard let color = await session.fetchOwnChatColor() else { return }
            guard let self, self.selfChatter.color.isEmpty else { return }
            self.selfChatter.color = color
        }
    }
}
