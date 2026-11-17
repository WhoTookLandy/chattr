import Foundation

// MARK: - Live channel events (polls, predictions, Hype Trains)
//
// Display-ready, source-agnostic models for the "something is happening in
// this channel right now" banners at the top of chat. Built off the main
// actor by `LiveEventUpdate` (EventSub / Helix → model) and folded into a
// `LiveEventsState` by its reducer, both in `LiveEventsReducer.swift`.
//
// Kept apart from `ChannelUpdate` on purpose: these change every few seconds
// for minutes at a time (vote / point / progress ticks), and routing them
// through the transcript ring would wake the chat list for nothing. They
// travel through their own latest-value mailbox (`LiveEventsSubscription`)
// to their own narrow observable in Features.

/// The kinds of live event the banner area shows, in display priority
/// order (highest first) — `allCases` is the stacking order.
public enum LiveEventKind: String, CaseIterable, Sendable, Hashable {
    case hypeTrain
    case prediction
    case poll
}

/// A channel poll.
public struct LivePoll: Sendable, Equatable, Identifiable {

    public enum Status: Sendable, Equatable {
        case active
        /// Ran its full duration.
        case completed
        /// Ended early by the broadcaster; results still shown.
        case terminated
        /// Ended and hidden by the broadcaster (or moderated / invalid) —
        /// the reducer removes the poll instead of storing this.
        case archived

        /// Orders statuses so a stale event can never move a poll
        /// backwards (a late `progress` after the `end`).
        var rank: Int {
            switch self {
            case .active: return 0
            case .completed, .terminated: return 1
            case .archived: return 2
            }
        }

        public var isConcluded: Bool { self != .active }
    }

    public struct Choice: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// Total votes for this choice, all voting methods combined.
        public var votes: Int

        public init(id: String, title: String, votes: Int) {
            self.id = id
            self.title = title
            self.votes = votes
        }
    }

    public let id: String
    public var title: String
    public var choices: [Choice]
    public var startedAt: Date?
    /// When voting closes. EventSub's poll payload doesn't carry it in
    /// TwitchKit's model, so it is filled from Helix (`duration`) when known;
    /// nil hides the countdown rather than guessing.
    public var endsAt: Date?
    public var status: Status
    /// Local receipt time of the transition into a concluded status — drives
    /// how long the result lingers before the banner dismisses. Local clock on
    /// purpose: comparing against Twitch's `ended_at` would bake device clock
    /// skew into the linger.
    public var concludedAt: Date?
    /// Local receipt time of the last update (EventSub or a Helix
    /// reconcile) that confirmed this event. An unconcluded event that
    /// nothing has confirmed for `LiveEventsState.unconfirmedExpiry` is
    /// dropped: the backstop for an end event lost while the socket was down.
    public var confirmedAt: Date?

    public init(
        id: String,
        title: String,
        choices: [Choice],
        startedAt: Date? = nil,
        endsAt: Date? = nil,
        status: Status = .active,
        concludedAt: Date? = nil,
        confirmedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.choices = choices
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.status = status
        self.concludedAt = concludedAt
        self.confirmedAt = confirmedAt
    }

    public var totalVotes: Int { choices.reduce(0) { $0 + max(0, $1.votes) } }

    /// 0…1 share of the vote; 0 while nobody has voted.
    public func fraction(of choice: Choice) -> Double {
        let total = totalVotes
        guard total > 0 else { return 0 }
        return Double(max(0, choice.votes)) / Double(total)
    }

    /// The choice(s) with the most votes — several on a tie, none before the
    /// first vote.
    public var leadingChoiceIds: Set<String> {
        guard let top = choices.map(\.votes).max(), top > 0 else { return [] }
        return Set(choices.filter { $0.votes == top }.map(\.id))
    }
}

/// A channel-points prediction.
public struct LivePrediction: Sendable, Equatable, Identifiable {

    public enum Status: Sendable, Equatable {
        case active
        /// Predictions closed, awaiting the result.
        case locked
        /// A winning outcome was picked.
        case resolved
        /// Cancelled; points refunded.
        case canceled

        var rank: Int {
            switch self {
            case .active: return 0
            case .locked: return 1
            case .resolved, .canceled: return 2
            }
        }

        public var isConcluded: Bool { self == .resolved || self == .canceled }
    }

    public struct Outcome: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// Twitch's colour hint, lowercased: "blue" / "pink".
        public let color: String
        public var users: Int
        public var points: Int

        public init(id: String, title: String, color: String, users: Int, points: Int) {
            self.id = id
            self.title = title
            self.color = color
            self.users = users
            self.points = points
        }
    }

    public let id: String
    public var title: String
    public var outcomes: [Outcome]
    /// Twitch's start time. Orders two different predictions, so a delayed
    /// end for an old one can't replace the one running now.
    public var startedAt: Date?
    /// When predictions close (active only).
    public var locksAt: Date?
    public var status: Status
    public var winningOutcomeId: String?
    /// Local receipt time of the resolve / cancel. See `LivePoll.concludedAt`.
    public var concludedAt: Date?
    /// See `LivePoll.confirmedAt`. A locked prediction gets no EventSub
    /// traffic until it resolves, so this is the lock or the last Helix
    /// check. It is what stops a "Locked" banner from sticking forever.
    public var confirmedAt: Date?

    public init(
        id: String,
        title: String,
        outcomes: [Outcome],
        startedAt: Date? = nil,
        locksAt: Date? = nil,
        status: Status = .active,
        winningOutcomeId: String? = nil,
        concludedAt: Date? = nil,
        confirmedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.outcomes = outcomes
        self.startedAt = startedAt
        self.locksAt = locksAt
        self.status = status
        self.winningOutcomeId = winningOutcomeId
        self.concludedAt = concludedAt
        self.confirmedAt = confirmedAt
    }

    public var totalPoints: Int { outcomes.reduce(0) { $0 + max(0, $1.points) } }

    /// 0…1 share of the points wagered; 0 before the first prediction.
    public func fraction(of outcome: Outcome) -> Double {
        let total = totalPoints
        guard total > 0 else { return 0 }
        return Double(max(0, outcome.points)) / Double(total)
    }

    /// Twitch's payout ratio for an outcome ("1:2.5" → 2.5): total pool over
    /// the outcome's pool. nil while the outcome has no points.
    public func payoutRatio(of outcome: Outcome) -> Double? {
        guard outcome.points > 0 else { return nil }
        return Double(totalPoints) / Double(outcome.points)
    }
}

/// A Hype Train.
public struct LiveHypeTrain: Sendable, Equatable, Identifiable {

    public enum Status: Sendable, Equatable {
        case active
        case ended

        var rank: Int { self == .active ? 0 : 1 }
        public var isConcluded: Bool { self == .ended }
    }

    public let id: String
    /// Twitch's start time. Orders two different trains.
    public var startedAt: Date?
    public var level: Int
    /// Points contributed so far, across all levels.
    public var total: Int?
    /// Points toward the current level's goal.
    public var progress: Int?
    /// Points needed to clear the current level.
    public var goal: Int?
    /// When the train ends unless someone contributes.
    public var expiresAt: Date?
    public var status: Status
    /// Golden Kappa / Treasure trains get distinct styling.
    public var isGoldenKappa: Bool
    /// Local receipt time of the end. See `LivePoll.concludedAt`.
    public var concludedAt: Date?
    /// See `LivePoll.confirmedAt`.
    public var confirmedAt: Date?

    public init(
        id: String,
        startedAt: Date? = nil,
        level: Int,
        total: Int? = nil,
        progress: Int? = nil,
        goal: Int? = nil,
        expiresAt: Date? = nil,
        status: Status = .active,
        isGoldenKappa: Bool = false,
        concludedAt: Date? = nil,
        confirmedAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.level = level
        self.total = total
        self.progress = progress
        self.goal = goal
        self.expiresAt = expiresAt
        self.status = status
        self.isGoldenKappa = isGoldenKappa
        self.concludedAt = concludedAt
        self.confirmedAt = confirmedAt
    }

    /// 0…1 progress through the current level; nil when Twitch didn't send
    /// a goal (the end event carries none).
    public var levelFraction: Double? {
        guard let progress, let goal, goal > 0 else { return nil }
        return min(1, max(0, Double(progress) / Double(goal)))
    }
}

/// Everything live in one channel right now. At most one of each kind —
/// Twitch only runs one poll, one prediction and one Hype Train at a time.
///
/// Equality covers what the banners show (the three events). The reducer's
/// bookkeeping (`tombstones`) is left out on purpose: recording a finished
/// id never counts as a change, so it never publishes and never re-renders
/// a banner.
public struct LiveEventsState: Sendable, Equatable {
    public var poll: LivePoll?
    public var prediction: LivePrediction?
    public var hypeTrain: LiveHypeTrain?

    /// Ids of recently finished events, per kind. See `LiveEventTombstones`.
    var tombstones = LiveEventTombstones()

    public init(poll: LivePoll? = nil, prediction: LivePrediction? = nil, hypeTrain: LiveHypeTrain? = nil) {
        self.poll = poll
        self.prediction = prediction
        self.hypeTrain = hypeTrain
    }

    public var isEmpty: Bool { poll == nil && prediction == nil && hypeTrain == nil }

    public static func == (lhs: LiveEventsState, rhs: LiveEventsState) -> Bool {
        lhs.poll == rhs.poll && lhs.prediction == rhs.prediction && lhs.hypeTrain == rhs.hypeTrain
    }
}

/// A small, bounded memory of event ids that are over: ended, archived,
/// replaced by a newer event, expired, or cleared by a Helix reconcile. The
/// reducer rejects any later update for one of these ids unless it is the
/// event currently shown, so a delayed or duplicated `end`, or a late
/// `progress`, can never bring a finished event back.
///
/// Twitch runs one event of each kind at a time, so the last few ids per
/// kind cover any realistic reordering. The oldest falls off first.
struct LiveEventTombstones: Sendable {
    static let capacity = 8

    private var poll: [String] = []
    private var prediction: [String] = []
    private var hypeTrain: [String] = []

    func contains(_ id: String, kind: LiveEventKind) -> Bool {
        ids(kind).contains(id)
    }

    mutating func insert(_ id: String, kind: LiveEventKind) {
        var list = ids(kind)
        guard !list.contains(id) else { return }
        list.append(id)
        if list.count > Self.capacity {
            list.removeFirst(list.count - Self.capacity)
        }
        switch kind {
        case .poll: poll = list
        case .prediction: prediction = list
        case .hypeTrain: hypeTrain = list
        }
    }

    private func ids(_ kind: LiveEventKind) -> [String] {
        switch kind {
        case .poll: return poll
        case .prediction: return prediction
        case .hypeTrain: return hypeTrain
        }
    }
}
