import Foundation
import SwiftUI
import TwitchKit
import Channels
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

    /// Messages displayed in the chat. Capped at `lineCap` via a sliding
    /// window — when full, appending drops the oldest message.
    public private(set) var lines: [ChatMessage] = []

    public private(set) var attachState: AttachState = .detached

    /// Max retained messages across all sessions in this tab.
    private static let lineCap = 500

    /// Active subscription tokens, paired with the sessions they belong to.
    /// Stored as tuples (not a dict) because order doesn't matter and we
    /// always operate on all of them together.
    private var subscriptions: [(session: ChannelSession, token: UUID)] = []

    public init() {}

    // MARK: - Attach / detach

    /// Subscribes to each session, primes `lines` from their combined current
    /// state, and starts receiving new messages via callback.
    ///
    /// Idempotent in the sense that calling `attach` twice without `detach` in
    /// between is incorrect usage — it would leak subscriptions. Callers should
    /// pair attach/detach 1:1.
    ///
    /// The prime + subscribe happens atomically per-session (one actor call
    /// each via `session.subscribe(_:)`), so each session's contribution to
    /// `lines` can't have a "primed-but-missed-a-message" gap.
    public func attach(sessions: [ChannelSession]) async {
        attachState = .attaching

        var combined: [ChatMessage] = []
        for session in sessions {
            // Atomic prime + subscribe — see ChannelSession.subscribe docs.
            let (token, snapshot) = await session.subscribe { [weak self] message in
                // Handler runs in whichever actor the Task happens to be on.
                // Hop to MainActor to mutate observable state.
                await self?.append(message)
            }
            subscriptions.append((session, token))
            combined.append(contentsOf: snapshot)
        }

        // For single-session tabs `combined` is already in arrival order; the
        // ring buffer maintains insertion order. For multi-session tabs we'd
        // sort by message timestamp here — TODO when N > 1 ships.
        lines = Self.cap(combined)
        attachState = .attached
        logger.info("TabChatModel attached to \(sessions.count) session(s), primed with \(self.lines.count) messages")
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

    /// Called by the per-session subscriber handler when a new message arrives.
    /// Appends to `lines` and slides the cap window. The @MainActor isolation
    /// is implicit — this method is on a @MainActor class.
    private func append(_ message: ChatMessage) {
        lines.append(message)
        if lines.count > Self.lineCap {
            lines.removeFirst(lines.count - Self.lineCap)
        }
    }

    /// Trim a pre-built array to the cap. Used during the initial prime when
    /// merging multiple sessions' snapshots — if their combined sizes exceed
    /// the cap, keep the most recent.
    private static func cap(_ messages: [ChatMessage]) -> [ChatMessage] {
        if messages.count <= lineCap { return messages }
        return Array(messages.suffix(lineCap))
    }
}
