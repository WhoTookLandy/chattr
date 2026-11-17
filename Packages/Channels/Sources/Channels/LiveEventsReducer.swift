import Foundation
import TwitchKit

// MARK: - Decoding (wire → model)

/// One change to a channel's live events, decoded from EventSub or Helix.
/// Pure values — built and reduced on the session actor, never on main.
public enum LiveEventUpdate: Sendable, Equatable {
    case poll(LivePoll)
    /// Helix told us when an already-known poll closes. Separate from
    /// `.poll` so a slower Helix answer can't roll vote counts back to its
    /// older snapshot — it only ever fills in the deadline.
    case pollDeadline(pollId: String, endsAt: Date)
    case prediction(LivePrediction)
    case hypeTrain(LiveHypeTrain)

    /// Decodes an EventSub event belonging to `channelId`. nil for every
    /// other event type (the chat hot path: one enum switch, no allocation)
    /// and for another channel's events.
    public init?(event: EventSubEvent, channelId: String) {
        switch event {
        case .pollBegin(let p) where p.broadcasterUserId == channelId,
             .pollProgress(let p) where p.broadcasterUserId == channelId:
            self = .poll(Self.poll(p, ended: false))
        case .pollEnd(let p) where p.broadcasterUserId == channelId:
            self = .poll(Self.poll(p, ended: true))

        case .predictionBegin(let p) where p.broadcasterUserId == channelId,
             .predictionProgress(let p) where p.broadcasterUserId == channelId:
            self = .prediction(Self.prediction(p, status: .active))
        case .predictionLock(let p) where p.broadcasterUserId == channelId:
            self = .prediction(Self.prediction(p, status: .locked))
        case .predictionEnd(let p) where p.broadcasterUserId == channelId:
            let status: LivePrediction.Status = p.status?.lowercased() == "canceled" ? .canceled : .resolved
            self = .prediction(Self.prediction(p, status: status))

        case .hypeTrainBegin(let h) where h.broadcasterUserId == channelId,
             .hypeTrainProgress(let h) where h.broadcasterUserId == channelId:
            self = .hypeTrain(Self.hypeTrain(h, ended: false))
        case .hypeTrainEnd(let h) where h.broadcasterUserId == channelId:
            self = .hypeTrain(Self.hypeTrain(h, ended: true))

        default:
            return nil
        }
    }

    /// A Helix Get Polls snapshot, in whatever status Helix reports. Used by
    /// `LiveEventsState.reconcile`, which decides whether a finished poll is
    /// news (it isn't, unless it is the one on screen).
    public init(helixPoll p: TwitchPoll) {
        self = .poll(LivePoll(
            id: p.id,
            title: p.title,
            choices: p.choices.map {
                LivePoll.Choice(id: $0.id ?? $0.title, title: $0.title, votes: $0.votes ?? 0)
            },
            startedAt: p.startedAt,
            endsAt: p.startedAt.addingTimeInterval(TimeInterval(p.duration)),
            status: LivePoll.Status(wire: p.status)
        ))
    }

    /// A Helix Get Predictions snapshot. nil only for a status we don't
    /// recognise.
    public init?(helixPrediction p: TwitchPrediction) {
        let status: LivePrediction.Status
        switch p.status.uppercased() {
        case "ACTIVE": status = .active
        case "LOCKED": status = .locked
        case "RESOLVED": status = .resolved
        case "CANCELED", "CANCELLED": status = .canceled
        default: return nil
        }
        self = .prediction(LivePrediction(
            id: p.id,
            title: p.title,
            outcomes: p.outcomes.map {
                LivePrediction.Outcome(
                    id: $0.id ?? $0.title,
                    title: $0.title,
                    color: ($0.color ?? "blue").lowercased(),
                    users: $0.users ?? 0,
                    points: $0.channelPoints ?? 0
                )
            },
            startedAt: p.createdAt,
            locksAt: status == .active
                ? p.createdAt.addingTimeInterval(TimeInterval(p.predictionWindow))
                : nil,
            status: status,
            winningOutcomeId: status == .resolved ? p.winningOutcomeId : nil
        ))
    }

    /// The train Helix Get Hype Train Status reports as `current`. Helix only
    /// reports a running train there, so this is always active.
    public init(helixHypeTrain h: HypeTrainCurrent) {
        self = .hypeTrain(LiveHypeTrain(
            id: h.id,
            startedAt: h.startedAt,
            level: h.level,
            total: h.total,
            progress: h.progress,
            goal: h.goal,
            expiresAt: h.expiresAt,
            status: .active,
            isGoldenKappa: h.type.lowercased() == "golden_kappa"
        ))
    }

    // MARK: Accessors

    public var kind: LiveEventKind {
        switch self {
        case .poll, .pollDeadline: return .poll
        case .prediction: return .prediction
        case .hypeTrain: return .hypeTrain
        }
    }

    public var eventId: String {
        switch self {
        case .poll(let p): return p.id
        case .pollDeadline(let id, _): return id
        case .prediction(let p): return p.id
        case .hypeTrain(let h): return h.id
        }
    }

    /// Whether this update reports the event as over.
    public var isConcluded: Bool {
        switch self {
        case .poll(let p): return p.status.isConcluded
        case .pollDeadline: return false
        case .prediction(let p): return p.status.isConcluded
        case .hypeTrain(let h): return h.status.isConcluded
        }
    }

    // MARK: Builders

    static func poll(_ p: EventSubPoll, ended: Bool) -> LivePoll {
        // An end event without a recognisable status still means the poll is
        // over — show it as completed rather than keep it live.
        let wireStatus = LivePoll.Status(wire: p.status)
        let status: LivePoll.Status = ended ? (wireStatus.isConcluded ? wireStatus : .completed) : .active
        return LivePoll(
            id: p.id,
            title: p.title,
            choices: p.choices.map {
                LivePoll.Choice(id: $0.id, title: $0.title, votes: $0.votes ?? 0)
            },
            startedAt: p.startedAt,
            endsAt: p.durationSeconds.map { p.startedAt.addingTimeInterval(TimeInterval($0)) },
            status: status
        )
    }

    static func prediction(_ p: EventSubPrediction, status: LivePrediction.Status) -> LivePrediction {
        LivePrediction(
            id: p.id,
            title: p.title,
            outcomes: p.outcomes.map {
                LivePrediction.Outcome(
                    id: $0.id,
                    title: $0.title,
                    color: $0.color.lowercased(),
                    users: $0.users ?? 0,
                    points: $0.channelPoints ?? 0
                )
            },
            startedAt: p.startedAt,
            locksAt: status == .active ? p.locksAt : nil,
            status: status,
            winningOutcomeId: status == .resolved ? p.winningOutcomeId : nil
        )
    }

    static func hypeTrain(_ h: EventSubHypeTrain, ended: Bool) -> LiveHypeTrain {
        LiveHypeTrain(
            id: h.id,
            startedAt: h.startedAt,
            level: h.level,
            total: h.total,
            progress: ended ? nil : h.progress,
            goal: ended ? nil : h.goal,
            expiresAt: ended ? nil : h.expiresAt,
            status: ended ? .ended : .active,
            isGoldenKappa: h.type?.lowercased() == "golden_kappa"
        )
    }
}

extension LivePoll.Status {
    /// EventSub sends lowercase, Helix uppercase.
    init(wire: String?) {
        switch wire?.lowercased() {
        case "completed": self = .completed
        case "terminated": self = .terminated
        case "archived", "moderated", "invalid": self = .archived
        default: self = .active
        }
    }
}

// MARK: - Reducer

extension LiveEventsState {

    /// How long a finished poll / prediction / train keeps showing its
    /// result before the banner goes away.
    public static let resultLinger: TimeInterval = 10

    /// An active event whose deadline (a poll's `endsAt`, a train's
    /// `expiresAt`) passed this long ago without an end event (missed while
    /// the socket was down) is dropped rather than shown forever.
    public static let overdueGrace: TimeInterval = 90

    /// Safety net for an unfinished event with no deadline to go by, above
    /// all a locked prediction, which gets no EventSub traffic until it
    /// resolves. If neither EventSub nor a Helix reconcile has confirmed it
    /// for this long, it is dropped. The session re-checks unfinished events
    /// against Helix every `ChannelSession.liveEventsVerifyInterval`, so a
    /// prediction that really is still locked keeps getting confirmed and
    /// stays up.
    public static let unconfirmedExpiry: TimeInterval = 30 * 60

    /// Folds one update in. Returns whether anything visible changed.
    ///
    /// Rules, per kind:
    /// - **Tombstones**: an update for an id that is already over (see
    ///   `LiveEventTombstones`) is ignored unless that event is still the
    ///   one stored. A duplicate or delayed `end`, or a late `progress`,
    ///   can't revive a finished event.
    /// - **Different id**: replaces the stored event only if it is newer
    ///   (later Twitch start time). Without both start times, it replaces
    ///   only when it is live or the stored one is finished, so a delayed
    ///   end for an old event never covers a running one. The replaced id
    ///   is tombstoned.
    /// - **Same id**: a status never moves backwards, so a late `progress`
    ///   after `lock`/`end` is ignored. At the same status, a snapshot with a
    ///   lower tally (votes, points, train level / total, all of which only
    ///   grow) is older than what we have and is ignored. Fields the
    ///   incoming event lacks (a poll's deadline, a train's total on its end
    ///   event) keep their last value.
    /// - Concluding stamps `concludedAt = now` once; the result then lingers
    ///   for `resultLinger` (see `prune`). Every accepted update stamps
    ///   `confirmedAt = now`.
    /// - An archived poll is removed outright — the broadcaster hid it.
    /// - An id `prune` safety-expired (see `expired`) gets back in only on
    ///   its real end / resolve, never on a non-terminal EventSub update.
    @discardableResult
    public mutating func apply(_ update: LiveEventUpdate, at now: Date) -> Bool {
        fold(update, at: now, fromHelix: false)
    }

    /// `apply`, plus whether the update is an authoritative Helix snapshot,
    /// which may also restore a safety-expired unfinished event.
    @discardableResult
    private mutating func fold(_ update: LiveEventUpdate, at now: Date, fromHelix: Bool) -> Bool {
        let before = self
        switch update {
        case .poll(var incoming):
            if let current = poll, current.id == incoming.id {
                guard incoming.status.rank > current.status.rank
                    || (incoming.status.rank == current.status.rank && incoming.totalVotes >= current.totalVotes)
                else { return false }
                incoming.endsAt = incoming.endsAt ?? current.endsAt
                incoming.startedAt = incoming.startedAt ?? current.startedAt
                incoming.concludedAt = current.concludedAt
            } else if !admit(
                incoming.id, kind: .poll,
                incomingStart: incoming.startedAt, incomingConcluded: incoming.status.isConcluded,
                fromHelix: fromHelix,
                current: poll.map { (id: $0.id, startedAt: $0.startedAt, isConcluded: $0.status.isConcluded) }
            ) {
                return false
            }
            incoming.confirmedAt = now
            if incoming.status.isConcluded {
                tombstones.insert(incoming.id, kind: .poll)
            }
            if incoming.status == .archived {
                poll = nil
            } else {
                if incoming.status.isConcluded, incoming.concludedAt == nil {
                    incoming.concludedAt = now
                }
                poll = incoming
            }

        case .pollDeadline(let id, let endsAt):
            if poll?.id == id, poll?.status == .active {
                poll?.endsAt = endsAt
            }

        case .prediction(var incoming):
            if let current = prediction, current.id == incoming.id {
                guard incoming.status.rank > current.status.rank
                    || (incoming.status.rank == current.status.rank && incoming.totalPoints >= current.totalPoints)
                else { return false }
                incoming.locksAt = incoming.status == .active ? (incoming.locksAt ?? current.locksAt) : nil
                incoming.startedAt = incoming.startedAt ?? current.startedAt
                incoming.concludedAt = current.concludedAt
            } else if !admit(
                incoming.id, kind: .prediction,
                incomingStart: incoming.startedAt, incomingConcluded: incoming.status.isConcluded,
                fromHelix: fromHelix,
                current: prediction.map { (id: $0.id, startedAt: $0.startedAt, isConcluded: $0.status.isConcluded) }
            ) {
                return false
            }
            incoming.confirmedAt = now
            if incoming.status.isConcluded {
                tombstones.insert(incoming.id, kind: .prediction)
                if incoming.concludedAt == nil { incoming.concludedAt = now }
            }
            prediction = incoming

        case .hypeTrain(var incoming):
            if let current = hypeTrain, current.id == incoming.id {
                guard incoming.status.rank > current.status.rank
                    || (incoming.status.rank == current.status.rank && !Self.isBehind(incoming, current))
                else { return false }
                incoming.total = incoming.total ?? current.total
                incoming.startedAt = incoming.startedAt ?? current.startedAt
                incoming.concludedAt = current.concludedAt
            } else if !admit(
                incoming.id, kind: .hypeTrain,
                incomingStart: incoming.startedAt, incomingConcluded: incoming.status.isConcluded,
                fromHelix: fromHelix,
                current: hypeTrain.map { (id: $0.id, startedAt: $0.startedAt, isConcluded: $0.status.isConcluded) }
            ) {
                return false
            }
            incoming.confirmedAt = now
            if incoming.status.isConcluded {
                tombstones.insert(incoming.id, kind: .hypeTrain)
                if incoming.concludedAt == nil { incoming.concludedAt = now }
            }
            hypeTrain = incoming
        }
        // Back on screen (or newly stored): no longer an expired id.
        if let id = storedId(update.kind) {
            expired.remove(id, kind: update.kind)
        }
        return self != before
    }

    /// Folds in what Helix says is the channel's latest event of `kind`
    /// (`snapshot`, nil when Helix reports none), fetched starting at
    /// `fetchedAt`. Unlike `apply`, this can also clear: a stored event that
    /// is unfinished, isn't the one Helix reports, and that nothing has
    /// confirmed since the fetch began is over (we missed its end while
    /// disconnected), so it is removed and tombstoned. The `fetchedAt`
    /// check means an EventSub update that lands while the request is in
    /// flight is never undone by the slower Helix answer.
    ///
    /// A finished snapshot only matters for the event on screen (it
    /// concludes it) or one `prune` safety-expired (we showed it and gave up
    /// on it too early, so its result is still news). A finished event we
    /// never showed isn't news, so it is only tombstoned.
    ///
    /// Helix is authoritative: an unfinished snapshot restores a
    /// safety-expired event, and one that still reports the stored
    /// unfinished event confirms it (`confirmedAt`) even when its tally lags
    /// what EventSub already delivered.
    ///
    /// Callers reconcile BEFORE they `prune`, so an event that went past
    /// `unconfirmedExpiry` unchecked (a long background) is confirmed rather
    /// than expired the moment Helix answers again.
    @discardableResult
    public mutating func reconcile(
        _ kind: LiveEventKind,
        snapshot: LiveEventUpdate?,
        fetchedAt: Date,
        now: Date
    ) -> Bool {
        let before = self
        if let snapshot, snapshot.kind == kind {
            if storedId(kind) == nil, snapshot.isConcluded, !expired.contains(snapshot.eventId, kind: kind) {
                tombstones.insert(snapshot.eventId, kind: kind)
            } else {
                fold(snapshot, at: now, fromHelix: true)
                if !snapshot.isConcluded {
                    confirm(kind, id: snapshot.eventId, at: now)
                }
            }
        }
        if let event = stored(kind),
           !event.isConcluded,
           event.id != snapshot?.eventId,
           (event.confirmedAt ?? .distantPast) < fetchedAt {
            remove(kind)
        }
        return self != before
    }

    /// Drops results that have lingered `resultLinger`, active events long
    /// past their deadline, and unfinished events nothing has confirmed for
    /// `unconfirmedExpiry`. A dropped result is tombstoned (it is over); a
    /// dropped unfinished event is only marked `expired`, since a safety
    /// expiry doesn't mean it ended. Returns whether anything changed.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let before = self
        for kind in LiveEventKind.allCases {
            if let event = stored(kind), let expiry = Self.expiry(of: event), now >= expiry {
                if event.isConcluded {
                    remove(kind)
                } else {
                    expired.insert(event.id, kind: kind)
                    clear(kind)
                }
            }
        }
        return self != before
    }

    /// The earliest moment `prune` would change something — when the next
    /// banner should go away on its own. nil when nothing is pending.
    public func nextPruneDate() -> Date? {
        LiveEventKind.allCases.compactMap { stored($0).flatMap(Self.expiry(of:)) }.min()
    }

    /// The kind whose banner deserves a moment of attention after moving
    /// from `old` to `self`: it appeared, changed status (locked, resolved,
    /// ended) or — for a Hype Train — levelled up. Highest priority wins.
    /// Plain vote / point / progress ticks are NOT attention-worthy, so a
    /// collapsed banner stays collapsed while numbers move.
    public func attentionKind(comparedTo old: LiveEventsState) -> LiveEventKind? {
        for kind in LiveEventKind.allCases {
            switch kind {
            case .hypeTrain:
                if let new = hypeTrain,
                   old.hypeTrain?.id != new.id
                    || old.hypeTrain?.status != new.status
                    || (old.hypeTrain?.level ?? 0) < new.level {
                    return .hypeTrain
                }
            case .prediction:
                if let new = prediction,
                   old.prediction?.id != new.id || old.prediction?.status != new.status {
                    return .prediction
                }
            case .poll:
                if let new = poll,
                   old.poll?.id != new.id || old.poll?.status != new.status {
                    return .poll
                }
            }
        }
        return nil
    }

    /// Whether any event is still running (not yet concluded) — what the
    /// session's periodic Helix check looks at.
    public var hasUnconcludedEvent: Bool {
        LiveEventKind.allCases.contains { stored($0).map { !$0.isConcluded } ?? false }
    }

    // MARK: - Internals

    /// The ordering facts the reducer needs about a stored event, whatever
    /// its kind.
    private struct StoredEvent {
        let id: String
        let isConcluded: Bool
        let concludedAt: Date?
        let confirmedAt: Date?
        /// When an active event is due to end on its own (poll close, train
        /// expiry). nil for a prediction: its lock doesn't end it.
        let deadline: Date?
    }

    private func stored(_ kind: LiveEventKind) -> StoredEvent? {
        switch kind {
        case .poll:
            return poll.map {
                StoredEvent(id: $0.id, isConcluded: $0.status.isConcluded, concludedAt: $0.concludedAt,
                            confirmedAt: $0.confirmedAt, deadline: $0.status == .active ? $0.endsAt : nil)
            }
        case .prediction:
            return prediction.map {
                StoredEvent(id: $0.id, isConcluded: $0.status.isConcluded, concludedAt: $0.concludedAt,
                            confirmedAt: $0.confirmedAt, deadline: nil)
            }
        case .hypeTrain:
            return hypeTrain.map {
                StoredEvent(id: $0.id, isConcluded: $0.status.isConcluded, concludedAt: $0.concludedAt,
                            confirmedAt: $0.confirmedAt, deadline: $0.status == .active ? $0.expiresAt : nil)
            }
        }
    }

    private func storedId(_ kind: LiveEventKind) -> String? {
        stored(kind)?.id
    }

    /// Clears the stored event of `kind` and tombstones its id.
    private mutating func remove(_ kind: LiveEventKind) {
        guard let id = storedId(kind) else { return }
        tombstones.insert(id, kind: kind)
        clear(kind)
    }

    private mutating func clear(_ kind: LiveEventKind) {
        switch kind {
        case .poll: poll = nil
        case .prediction: prediction = nil
        case .hypeTrain: hypeTrain = nil
        }
    }

    /// Stamps `confirmedAt` on the stored event of `kind` if it is `id` and
    /// still unfinished.
    private mutating func confirm(_ kind: LiveEventKind, id: String, at now: Date) {
        switch kind {
        case .poll:
            if poll?.id == id, poll?.status.isConcluded == false { poll?.confirmedAt = now }
        case .prediction:
            if prediction?.id == id, prediction?.status.isConcluded == false { prediction?.confirmedAt = now }
        case .hypeTrain:
            if hypeTrain?.id == id, hypeTrain?.status.isConcluded == false { hypeTrain?.confirmedAt = now }
        }
    }

    /// When `prune` drops `event`: its result has lingered; or its deadline
    /// (poll close, train `expires_at`) is `overdueGrace` past; or, with no
    /// deadline to go by (a locked prediction, a poll whose deadline never
    /// arrived), nothing has confirmed it for `unconfirmedExpiry`.
    private static func expiry(of event: StoredEvent) -> Date? {
        if let concludedAt = event.concludedAt {
            return concludedAt.addingTimeInterval(resultLinger)
        }
        if let deadline = event.deadline {
            return deadline.addingTimeInterval(overdueGrace)
        }
        return event.confirmedAt?.addingTimeInterval(unconfirmedExpiry)
    }

    /// Decides whether an update whose id differs from the stored one (or
    /// fills an empty slot) gets in. Tombstones the loser: the replaced
    /// event, or a finished incoming one that lost to a newer stored event.
    private mutating func admit(
        _ id: String,
        kind: LiveEventKind,
        incomingStart: Date?,
        incomingConcluded: Bool,
        fromHelix: Bool,
        current: (id: String, startedAt: Date?, isConcluded: Bool)?
    ) -> Bool {
        if tombstones.contains(id, kind: kind) { return false }
        // Safety-expired, not known to be over: only its real end, or Helix
        // saying it is still running, brings it back.
        if expired.contains(id, kind: kind), !incomingConcluded, !fromHelix { return false }
        guard let current else { return true }
        let isNewer: Bool
        if let incomingStart, let currentStart = current.startedAt, incomingStart != currentStart {
            isNewer = incomingStart > currentStart
        } else {
            isNewer = !incomingConcluded || current.isConcluded
        }
        if isNewer {
            tombstones.insert(current.id, kind: kind)
        } else if incomingConcluded {
            tombstones.insert(id, kind: kind)
        }
        return isNewer
    }

    /// A same-status train update that is older than the stored one: a
    /// lower level, or a lower running total. Both only grow.
    private static func isBehind(_ incoming: LiveHypeTrain, _ current: LiveHypeTrain) -> Bool {
        if incoming.level != current.level { return incoming.level < current.level }
        if let new = incoming.total, let old = current.total { return new < old }
        return false
    }
}
