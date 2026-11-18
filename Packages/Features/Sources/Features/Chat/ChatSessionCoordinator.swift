import Foundation
import Observation
import Accounts
import Channels
import Core
import os

// The screen's category: a chat page's session start is logged (and
// signposted) next to its emote load.
private let logger = AppLogger.make("Features.ChatScreen")
private let signposter = AppLogger.signposter("Features.ChatScreen")

/// The session lifecycle behind one `ChatScreen`: fetching the channel's
/// session, attaching the screen's `ChatTranscriptModel` to it, and detaching
/// when the screen goes away — plus the two out-of-band starts, the error
/// view's Retry and the compose bar's self-heal.
///
/// `ChatScreen` owns one as `@State` and drives it from its session-lifecycle
/// `.task(id: channelId)` (`run`), the Retry button (`retry`) and the compose
/// bar's send (`reattachIfNeeded`). Everything outside the coordinator comes
/// in as a `Link`, so the lease rules here can be driven without a registry,
/// a session or a network.
@MainActor
@Observable
final class ChatSessionCoordinator {

    /// What a start works against: the channel's session and the screen's
    /// transcript model, as closures. `Link.live` builds the production one.
    struct Link {
        /// For logs and signposts.
        let channelLoginName: String
        /// Fetches the channel's session and attaches the transcript model to
        /// it, returning the attach epoch the model established. Throws when
        /// no session could be had (`CancellationError` when the fetch was
        /// cancelled). Nil when there is no session registry to ask.
        let attach: (@MainActor () async throws -> Int)?
        /// `ChatTranscriptModel.detach(ifEpoch:)`.
        let detach: @MainActor (Int) async -> Void
        /// Whether the transcript model has a live attachment right now.
        let isAttached: @MainActor () -> Bool
    }

    /// Why chat couldn't be opened, after a failed start: `ChatScreen` shows
    /// its error view (with Retry) in place of the transcript. Cleared when
    /// the next start begins.
    private(set) var errorMessage: String?

    /// The attach epoch owned by the CURRENT session-lifecycle task (see
    /// `run`). Each run of that task mints a fresh lease and detaches with
    /// whatever epoch it holds at teardown. Out-of-band attaches — the error
    /// view's Retry button and the compose bar's self-heal — record into the
    /// live lease too, so the attachment they create is torn down when the
    /// view goes away. Without it, a retry after a failed start left the task
    /// holding the `0` sentinel and its `detach(ifEpoch: 0)` no-op'd, keeping
    /// a subscription draining the session offscreen.
    @ObservationIgnored private var attachLease = AttachLease()

    // MARK: - Entry points

    /// The body of `ChatScreen`'s session-lifecycle `.task(id: channelId)`:
    /// starts the session, holds until SwiftUI cancels the task, then
    /// detaches what this run (or an out-of-band start during it) attached.
    func run(_ link: Link) async {
        // A lease per task run: a channelId change starts a new run with
        // a new lease, so the outgoing run's teardown can never detach an
        // epoch the incoming run (or a retry during it) established.
        let lease = AttachLease()
        attachLease = lease
        await startSession(link, recordingInto: lease)
        // Hold the task open until SwiftUI cancels us (view torn down
        // or channelId changes). Sleeping for a year is the canonical
        // SwiftUI idiom — Task.sleep is implemented as a scheduler
        // primitive, not a busy-loop, so the cost is zero CPU.
        try? await Task.sleep(for: .seconds(60 * 60 * 24 * 365))
        // Cancellation reaches here via CancellationError from sleep.
        // Detach ONLY if this appearance still owns the current attachment:
        // a newer ChatScreen appearance (paged re-mount, or a session
        // teardown+rebuild) bumps the model's epoch, so a stale teardown
        // here becomes a no-op and can't strand the freshly re-attached
        // model (the "I see chat but it says Not connected" bug). The link
        // holds the model, so it is still there however late this runs.
        // Close the lease FIRST (synchronously, before any suspension):
        // an out-of-band start still in flight will then detach its own
        // attachment when it lands instead of recording it into a lease
        // nobody will tear down. Cancel it too, so it stops early.
        lease.close()
        await link.detach(lease.epoch)
    }

    /// The error view's Retry button. Without an in-place retry that screen
    /// is a dead end: the error never clears and `.task(id: channelId)` won't
    /// re-fire for the same channel — the only escape was closing the tab.
    ///
    /// - Returns: the start it launched, or nil when the view has already
    ///   gone (its lease is closed) and nothing was started.
    @discardableResult
    func retry(_ link: Link) -> Task<Void, Never>? {
        let lease = attachLease
        guard !lease.isClosed else { return nil }
        let task = Task { await self.startSession(link, recordingInto: lease) }
        lease.track(task)
        return task
    }

    /// The compose bar's self-heal, run before each send: if the model lost
    /// its live session under us (a lifecycle race, or a session
    /// teardown+rebuild that left it detached while still showing primed
    /// lines), re-establish it before sending — so the user never hits a
    /// phantom "Not connected to chat" on a channel that's clearly live.
    /// `startSession`/`attach` are epoch-guarded + idempotent, so a no-op
    /// when already attached.
    func reattachIfNeeded(_ link: Link) async {
        if !link.isAttached() {
            await startSession(link, recordingInto: attachLease)
        }
    }

    // MARK: - Starting

    /// Starts (or re-establishes) the session attachment and records the
    /// resulting epoch into `lease`, which the session-lifecycle task passes
    /// to `detach(ifEpoch:)` on teardown. A failed, cancelled or missing-
    /// registry start records nothing, leaving the lease's previous epoch
    /// (or the `0` pre-attach sentinel, whose teardown no-ops unless nothing
    /// ever attached). If the lease closed while the start was in flight,
    /// its teardown has already run, so this start detaches its own
    /// attachment rather than leaving it orphaned.
    private func startSession(_ link: Link, recordingInto lease: AttachLease) async {
        let epoch = await attachSession(link)
        guard epoch != 0 else { return }
        if lease.isClosed {
            await link.detach(epoch)
        } else {
            lease.record(epoch)
        }
    }

    /// - Returns: the attach epoch the model established, or `0` if no attach
    ///   happened (missing registry, cancelled, or error).
    private func attachSession(_ link: Link) async -> Int {
        // Clear any prior failure so a retry (button or compose-bar
        // self-heal) actually dismisses the error view; a repeat failure
        // re-sets it below.
        errorMessage = nil
        // Badge load runs in a sibling .task modifier (see `ChatScreen.body`)
        // — gives us structured-cancellation parity with this session-start
        // task.
        guard let attach = link.attach else {
            errorMessage = "Couldn't open chat: missing session registry"
            logger.error("ChatScreen has no registry in environment — was RootView injected?")
            return 0
        }
        let channelLoginName = link.channelLoginName

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
            return try await attach()
        } catch is CancellationError {
            // Expected on view tear-down / channel-tab switch. The outgoing
            // instance's `try await registry.session(...)` gets cancelled in
            // flight. Silently exit — don't show a red error.
            logger.info("ChatScreen session-start cancelled for #\(channelLoginName)")
            return 0
        } catch {
            errorMessage = "Couldn't open chat: \(error.localizedDescription)"
            logger.error("ChatScreen failed to acquire session: \(error.localizedDescription)")
            return 0
        }
    }
}

// MARK: - Production link

extension ChatSessionCoordinator.Link {
    /// The link `ChatScreen` uses: sessions come from `registry`, and
    /// `chatModel` is what attaches to them, as `account` in `channel`.
    @MainActor
    static func live(
        registry: ChannelSessionRegistry?,
        chatModel: ChatTranscriptModel,
        account: Account,
        channel: ChannelDescriptor
    ) -> ChatSessionCoordinator.Link {
        let channelId = channel.channelId
        let channelLoginName = channel.channelLoginName
        var attach: (@MainActor () async throws -> Int)?
        if let registry {
            attach = {
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

                // Hand the session to the tab model, which atomically primes its
                // transcript from the session's current ring buffer AND
                // subscribes for future rows via `ChannelSession.subscribe()`.
                //
                // For the MVP this is always a single-element array. When multi-
                // channel tabs ship, `attach(sessions: [a, b, c])` will subscribe
                // to all of them with the same model — the rest of ChatScreen
                // doesn't need to change.
                //
                // Lifecycle: the session-lifecycle `.task(id: channelId)` in
                // `ChatScreen.body` detaches (with the epoch returned here) when
                // SwiftUI cancels it. The model's subscriptions stay live as long
                // as that ChatScreen instance is mounted; on tear-down they're
                // released, but the underlying `ChannelSession` stays alive in
                // the registry (other tabs may share it — it's ref-counted there).
                //
                // Rows arrive already normalized: the session tokenizes each
                // message once, off the main actor, against the registry-owned
                // EmoteIndex (the registry loads it; the screen's emote `.task`
                // retries on remount), and every tab showing the channel shares
                // the result.
                return await chatModel.attach(
                    sessions: [session],
                    currentUserId: account.userId,
                    currentUserLogin: account.login,
                    currentUserDisplayName: account.displayName,
                    // User-configured highlight keywords (Profile → Highlight
                    // Keywords). Read at attach time — changing them mid-session
                    // applies on the next channel attach (reopen / relaunch).
                    // Self-mentions are always highlighted regardless of this
                    // list (the session flags them); keywords are additive and
                    // applied by this model, per attach.
                    highlightKeywords: HighlightSettings.keywords(),
                    // Chat History setting — read at attach time, like the
                    // keywords. Tab remounts re-attach, so a changed setting
                    // takes hold on the next swipe back to (or reopen of) a
                    // channel.
                    lineCap: ChatAppearance.chatHistoryLines(),
                    // Composite draft key — the model clears the persisted
                    // draft under this key after a successful send. Passed
                    // from the descriptor here so the model never has to
                    // compose platform-qualified keys itself.
                    draftKey: channel.id,
                    // Hybrid mod detection: an async provider for the account's
                    // moderated-channel set (`/moderation/channels`, cached per
                    // account on the registry). attach fires it concurrently —
                    // it never blocks chat startup — and seeds
                    // `currentUserCanModerate` when this channel is in the set,
                    // so mods get Delete Message without sending a message
                    // first. Captures the userId string (not `account`, a
                    // non-Sendable @Model) and the registry weakly — if the
                    // registry is gone by resolution time the model just
                    // falls back to badge observation.
                    moderatedChannelIds: { [weak registry, accountUserId = account.userId] in
                        await registry?.moderatedChannelIds(
                            forAccountUserId: accountUserId
                        ) ?? []
                    },
                    // Counterpart hook: a live unmod (channel.moderate event or
                    // subscription revocation) evicts the registry's cached
                    // moderated-set, so reopening the channel refetches instead
                    // of re-seeding mod affordances from the stale entry.
                    onModerationRevoked: { [weak registry, accountUserId = account.userId] in
                        await registry?.invalidateModeratedChannels(
                            forAccountUserId: accountUserId
                        )
                    }
                )
            }
        }
        return ChatSessionCoordinator.Link(
            channelLoginName: channelLoginName,
            attach: attach,
            detach: { epoch in await chatModel.detach(ifEpoch: epoch) },
            isAttached: { chatModel.attachState == .attached }
        )
    }
}
