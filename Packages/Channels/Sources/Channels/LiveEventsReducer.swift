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

    /// Seeds from Helix Get Polls (the poll already running when chat
    /// opened). nil unless it is still active — a finished poll from before
    /// we joined isn't news.
    public init?(helixPoll p: TwitchPoll) {
        let status = LivePoll.Status(wire: p.status)
        guard status == .active else { return nil }
        self = .poll(LivePoll(
            id: p.id,
            title: p.title,
            choices: p.choices.map {
                LivePoll.Choice(id: $0.id ?? $0.title, title: $0.title, votes: $0.votes ?? 0)
            },
            startedAt: p.startedAt,
            endsAt: p.startedAt.addingTimeInterval(TimeInterval(p.duration)),
            status: .active
        ))
    }

    /// Seeds from Helix Get Predictions. nil unless active or locked.
    public init?(helixPrediction p: TwitchPrediction) {
        let status: LivePrediction.Status
        switch p.status.uppercased() {
        case "ACTIVE": status = .active
        case "LOCKED": status = .locked
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
            locksAt: status == .active
                ? p.createdAt.addingTimeInterval(TimeInterval(p.predictionWindow))
                : nil,
            status: status,
            winningOutcomeId: p.winningOutcomeId
        ))
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
            locksAt: status == .active ? p.locksAt : nil,
            status: status,
            winningOutcomeId: status == .resolved ? p.winningOutcomeId : nil
        )
    }

    static func hypeTrain(_ h: EventSubHypeTrain, ended: Bool) -> LiveHypeTrain {
        LiveHypeTrain(
            id: h.id,
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

    /// An active event whose deadline passed this long ago without an end
    /// event (missed while the socket was down) is dropped rather than shown
    /// forever.
    public static let overdueGrace: TimeInterval = 90

    /// Folds one update in. Returns whether anything changed.
    ///
    /// Rules, per kind:
    /// - A different id replaces the current one (Twitch runs one at a time).
    /// - Same id: a status never moves backwards, so a late `progress` after
    ///   `lock`/`end` is ignored; fields the incoming event lacks (a poll's
    ///   deadline, a train's goal on its end event) keep their last value.
    /// - Concluding stamps `concludedAt = now` once; the result then lingers
    ///   for `resultLinger` (see `prune`).
    /// - An archived poll is removed outright — the broadcaster hid it.
    @discardableResult
    public mutating func apply(_ update: LiveEventUpdate, at now: Date) -> Bool {
        let before = self
        switch update {
        case .poll(var incoming):
            if let current = poll, current.id == incoming.id {
                guard incoming.status.rank >= current.status.rank else { return false }
                incoming.endsAt = incoming.endsAt ?? current.endsAt
                incoming.startedAt = incoming.startedAt ?? current.startedAt
                incoming.concludedAt = current.concludedAt
            }
            if incoming.status == .archived {
                if poll == nil || poll?.id == incoming.id { poll = nil }
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
                guard incoming.status.rank >= current.status.rank else { return false }
                incoming.locksAt = incoming.status == .active ? (incoming.locksAt ?? current.locksAt) : nil
                incoming.concludedAt = current.concludedAt
            }
            if incoming.status.isConcluded, incoming.concludedAt == nil {
                incoming.concludedAt = now
            }
            prediction = incoming

        case .hypeTrain(var incoming):
            if let current = hypeTrain, current.id == incoming.id {
                guard incoming.status.rank >= current.status.rank else { return false }
                incoming.total = incoming.total ?? current.total
                incoming.concludedAt = current.concludedAt
            }
            if incoming.status.isConcluded, incoming.concludedAt == nil {
                incoming.concludedAt = now
            }
            hypeTrain = incoming
        }
        return self != before
    }

    /// Drops results that have lingered `resultLinger`, and active events
    /// long past their deadline. Returns whether anything changed.
    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let before = self
        if let poll, Self.isExpired(concludedAt: poll.concludedAt, deadline: poll.status == .active ? poll.endsAt : nil, now: now) {
            self.poll = nil
        }
        if let prediction, Self.isExpired(concludedAt: prediction.concludedAt, deadline: nil, now: now) {
            self.prediction = nil
        }
        if let hypeTrain, Self.isExpired(concludedAt: hypeTrain.concludedAt, deadline: hypeTrain.status == .active ? hypeTrain.expiresAt : nil, now: now) {
            self.hypeTrain = nil
        }
        return self != before
    }

    /// The earliest moment `prune` would change something — when the next
    /// banner should go away on its own. nil when nothing is pending.
    public func nextPruneDate() -> Date? {
        var dates: [Date] = []
        if let poll {
            if let c = poll.concludedAt { dates.append(c.addingTimeInterval(Self.resultLinger)) }
            else if let e = poll.endsAt { dates.append(e.addingTimeInterval(Self.overdueGrace)) }
        }
        if let c = prediction?.concludedAt {
            dates.append(c.addingTimeInterval(Self.resultLinger))
        }
        if let hypeTrain {
            if let c = hypeTrain.concludedAt { dates.append(c.addingTimeInterval(Self.resultLinger)) }
            else if let e = hypeTrain.expiresAt { dates.append(e.addingTimeInterval(Self.overdueGrace)) }
        }
        return dates.min()
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

    private static func isExpired(concludedAt: Date?, deadline: Date?, now: Date) -> Bool {
        if let concludedAt {
            return now.timeIntervalSince(concludedAt) >= resultLinger
        }
        if let deadline {
            return now.timeIntervalSince(deadline) >= overdueGrace
        }
        return false
    }
}
