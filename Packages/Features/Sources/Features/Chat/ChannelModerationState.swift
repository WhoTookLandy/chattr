import Observation
import TwitchKit
import Channels
import Core
import os

private let logger = AppLogger.make("Features.ChannelModerationState")

/// Whether the signed-in account can moderate the attached channel — which
/// drives the Delete Message affordance and the mod-only chat modes — plus
/// the moderation actions themselves.
///
/// `canModerate` turns true via three paths:
///   1. **Broadcaster instant** (`seed`): the account IS the channel — true
///      immediately, no waiting.
///   2. **Moderated-channels seed** (`seed`): a fire-and-forget ask of the
///      caller-provided `moderatedChannelIds` (the registry-cached
///      `/moderation/channels` set for this account). One Helix round-trip
///      on the account's first channel-open, instant after.
///   3. **Badge observation** (`observeOwnEcho`): a "moderator" /
///      "broadcaster" badge on one of our own echoes. The fallback for path
///      2's failure modes: tokens without `user:read:moderated_channels`
///      (fetch fails → empty set), transient failures, modded mid-session.
///
/// Every upgrade path routes through `promote`, which also enables the
/// session's `channel.moderate` v2 subscription. From then on the flag is
/// LIVE in both directions: a mod/unmod targeting our account — or Twitch
/// revoking that subscription, which it does on unmod — arrives as
/// `.moderationStatusChanged` (`apply(canModerate:)`). A downgrade fires the
/// revocation hook so the registry's cached moderated-set can't re-seed the
/// stale entry on reopen.
@MainActor
@Observable
final class ChannelModerationState {

    private(set) var canModerate = false

    /// In-flight moderated-channels seed (path 2). Held so detach can cancel
    /// it — a late result after re-attaching elsewhere must not flip the
    /// flag — and so tests can await it.
    @ObservationIgnored private(set) var seedTask: Task<Void, Never>?

    /// Evicts the registry's cached moderated-set on a live downgrade. The
    /// model can't reach the registry itself (Features ↔ Channels layering),
    /// so the view injects it at attach; nil in tests.
    @ObservationIgnored var onRevoked: (@Sendable () async -> Void)?

    /// Attach-time seeding: path 1, then — unless that already proved mod
    /// power — path 2, fire-and-forget so attach never blocks on Helix.
    func seed(
        from session: ChannelSession,
        moderatedChannelIds: (@Sendable () async -> Set<String>)?
    ) {
        // Cancel any previous in-flight seed before starting a new one.
        seedTask?.cancel()
        seedTask = nil
        if session.isAccountBroadcaster {
            promote(session: session)
        }
        guard !canModerate, let moderatedChannelIds else { return }
        let channelId = session.channelId
        seedTask = Task { [weak self] in
            let ids = await moderatedChannelIds()
            // Checked AFTER the await: detach or a live unmod cancels this
            // task, and a stale result must not flip the flag back on.
            guard !Task.isCancelled, let self else { return }
            if ids.contains(channelId) {
                self.promote(session: session)
            }
        }
    }

    /// Stops an unresolved seed and clears per-attach moderation state (detach).
    func cancelSeed() {
        seedTask?.cancel()
        seedTask = nil
        canModerate = false
    }

    /// Path 3 for one of our own echoes. Cheap — the badge array is usually
    /// under five entries, and skipped entirely once we know. Returns true
    /// when this echo promoted us.
    @discardableResult
    func observeOwnEcho(_ message: ChatMessage, session: ChannelSession?) -> Bool {
        guard !canModerate else { return false }
        let hasModBadge = message.badges.contains { badge in
            badge.setId == "moderator" || badge.setId == "broadcaster"
        }
        guard hasModBadge else { return false }
        promote(session: session)
        return true
    }

    /// A live `channel.moderate` status change. Upgrades go through
    /// `promote` (idempotent — the subscription that delivered this is
    /// already live); downgrades also fire the revocation hook.
    func apply(canModerate: Bool, session: ChannelSession?) {
        if canModerate {
            promote(session: session)
            return
        }
        // Cancel any still-running seed so a stale cached moderated-channel
        // list can't flip `canModerate` back to true after a live unmod.
        seedTask?.cancel()
        seedTask = nil
        self.canModerate = false
        if let onRevoked {
            Task { await onRevoked() }
        }
    }

    /// Asks Twitch to delete one message in `session`'s channel. Doesn't
    /// touch the transcript: the `channel.chat.message_delete` echo flips the
    /// row through the same path as a moderator's web-UI delete. Throws when
    /// Helix refuses (e.g. no longer a mod) — the caller surfaces it.
    func deleteMessage(withId messageId: String, in session: ChannelSession) async throws {
        do {
            try await session.deleteMessage(messageId: messageId)
            logger.info("Requested delete for message \(messageId, privacy: .public)")
        } catch {
            logger.error("deleteMessage failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// The single funnel for "we just learned the user can moderate here":
    /// flips the flag AND enables the session's `channel.moderate`
    /// subscription so the status stays live. Safe to repeat — the flag set
    /// is idempotent and `enableModerationEvents` self-guards.
    private func promote(session: ChannelSession?) {
        seedTask?.cancel()
        seedTask = nil
        canModerate = true
        guard let session else { return }
        Task {
            await session.enableModerationEvents()
        }
    }
}
