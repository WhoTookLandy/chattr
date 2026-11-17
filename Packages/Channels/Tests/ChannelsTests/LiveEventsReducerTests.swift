import Testing
import Foundation
import TwitchKit
@testable import Channels

/// Decoding (EventSub / Helix → `LiveEventUpdate`) and the
/// `LiveEventsState` reducer behind the poll / prediction / Hype Train
/// banners. Payloads are decoded from JSON in Twitch's wire shape with the
/// same snake_case + ISO-8601 strategy as TwitchKit's decoder, since the
/// TwitchKit models expose no public memberwise inits.
@Suite("Live events: decoding + reducer")
struct LiveEventsReducerTests {

    private let channelId = "chan-1"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Fixtures

    private func poll(
        id: String = "poll-1",
        votes: [Int?] = [nil, nil],
        status: String? = nil,
        broadcasterId: String? = nil
    ) throws -> EventSubPoll {
        let choices = votes.enumerated().map { index, v in
            let votesField = v.map { #", "votes": \#($0), "channel_points_votes": 0, "bits_votes": 0"# } ?? ""
            return #"{ "id": "c\#(index)", "title": "Choice \#(index)"\#(votesField) }"#
        }.joined(separator: ",")
        let statusField = status.map { #""status": "\#($0)","# } ?? ""
        let json = """
        {
            "id": "\(id)",
            "broadcaster_user_id": "\(broadcasterId ?? channelId)",
            "broadcaster_user_login": "me",
            "broadcaster_user_name": "Me",
            "title": "Best map?",
            "choices": [\(choices)],
            "bits_voting": { "is_enabled": false, "amount_per_vote": 0 },
            "channel_points_voting": { "is_enabled": true, "amount_per_vote": 10 },
            \(statusField)
            "started_at": "\(iso(t0))"
        }
        """
        return try decoder.decode(EventSubPoll.self, from: Data(json.utf8))
    }

    private func prediction(
        id: String = "pred-1",
        points: [Int?] = [nil, nil],
        status: String? = nil,
        winner: String? = nil,
        locksAt: Date? = nil
    ) throws -> EventSubPrediction {
        let colors = ["blue", "pink", "blue"]
        let outcomes = points.enumerated().map { index, p in
            let stats = p.map { #", "users": \#($0 / 100), "channel_points": \#($0)"# } ?? ""
            return #"{ "id": "o\#(index)", "title": "Outcome \#(index)", "color": "\#(colors[index % 3])"\#(stats) }"#
        }.joined(separator: ",")
        var extra = ""
        if let status { extra += #""status": "\#(status)","# }
        if let winner { extra += #""winning_outcome_id": "\#(winner)","# }
        if let locksAt { extra += #""locks_at": "\#(iso(locksAt))","# }
        let json = """
        {
            "id": "\(id)",
            "broadcaster_user_id": "\(channelId)",
            "broadcaster_user_login": "me",
            "broadcaster_user_name": "Me",
            "title": "Win the next fight?",
            "outcomes": [\(outcomes)],
            \(extra)
            "started_at": "\(iso(t0))"
        }
        """
        return try decoder.decode(EventSubPrediction.self, from: Data(json.utf8))
    }

    private func hypeTrain(
        id: String = "train-1",
        level: Int = 1,
        total: Int? = 500,
        progress: Int? = 200,
        goal: Int? = 1000,
        expiresAt: Date? = nil,
        type: String = "regular"
    ) throws -> EventSubHypeTrain {
        var extra = ""
        if let total { extra += #""total": \#(total),"# }
        if let progress { extra += #""progress": \#(progress),"# }
        if let goal { extra += #""goal": \#(goal),"# }
        if let expiresAt { extra += #""expires_at": "\#(iso(expiresAt))","# }
        let json = """
        {
            "id": "\(id)",
            "broadcaster_user_id": "\(channelId)",
            "broadcaster_user_login": "me",
            "broadcaster_user_name": "Me",
            "level": \(level),
            "top_contributions": [
                { "user_id": "u1", "user_login": "fan", "user_name": "Fan", "type": "bits", "total": 100 }
            ],
            \(extra)
            "type": "\(type)",
            "started_at": "\(iso(t0))"
        }
        """
        return try decoder.decode(EventSubHypeTrain.self, from: Data(json.utf8))
    }

    private func update(_ event: EventSubEvent) throws -> LiveEventUpdate {
        try #require(LiveEventUpdate(event: event, channelId: channelId))
    }

    // MARK: - Decoding

    @Test("poll begin decodes as an active poll with zeroed choices")
    func pollBeginDecodes() throws {
        guard case .poll(let p) = try update(.pollBegin(poll())) else {
            Issue.record("expected .poll"); return
        }
        #expect(p.id == "poll-1")
        #expect(p.title == "Best map?")
        #expect(p.status == .active)
        #expect(p.choices.map(\.votes) == [0, 0])
        #expect(p.startedAt == t0)
        #expect(p.totalVotes == 0)
        #expect(p.leadingChoiceIds.isEmpty)
    }

    @Test("poll end maps completed / terminated / archived, and a missing status to completed")
    func pollEndStatuses() throws {
        func status(_ wire: String?) throws -> LivePoll.Status? {
            guard case .poll(let p) = try update(.pollEnd(poll(votes: [1, 2], status: wire))) else { return nil }
            return p.status
        }
        #expect(try status("completed") == .completed)
        #expect(try status("terminated") == .terminated)
        #expect(try status("archived") == .archived)
        #expect(try status(nil) == .completed)
    }

    @Test("events for another channel decode to nil")
    func otherChannelIgnored() throws {
        #expect(LiveEventUpdate(event: .pollBegin(try poll(broadcasterId: "someone-else")), channelId: channelId) == nil)
    }

    @Test("prediction lock / end map to locked / resolved / canceled")
    func predictionStatuses() throws {
        guard case .prediction(let locked) = try update(.predictionLock(prediction(points: [100, 300]))) else {
            Issue.record("expected .prediction"); return
        }
        #expect(locked.status == .locked)
        #expect(locked.locksAt == nil)

        guard case .prediction(let resolved) = try update(.predictionEnd(prediction(points: [100, 300], status: "resolved", winner: "o1"))) else {
            Issue.record("expected .prediction"); return
        }
        #expect(resolved.status == .resolved)
        #expect(resolved.winningOutcomeId == "o1")

        guard case .prediction(let canceled) = try update(.predictionEnd(prediction(status: "canceled"))) else {
            Issue.record("expected .prediction"); return
        }
        #expect(canceled.status == .canceled)
        #expect(canceled.winningOutcomeId == nil)
    }

    @Test("prediction math: share of points and payout ratio")
    func predictionMath() throws {
        guard case .prediction(let p) = try update(.predictionProgress(prediction(points: [100, 300]))) else {
            Issue.record("expected .prediction"); return
        }
        #expect(p.totalPoints == 400)
        #expect(p.fraction(of: p.outcomes[0]) == 0.25)
        #expect(p.payoutRatio(of: p.outcomes[0]) == 4)
        #expect(p.payoutRatio(of: p.outcomes[1]).map { abs($0 - 4.0 / 3.0) < 0.0001 } == true)
        #expect(p.outcomes.map(\.color) == ["blue", "pink"])
    }

    @Test("hype train decodes level progress, golden kappa, and drops progress on end")
    func hypeTrainDecodes() throws {
        let expires = t0.addingTimeInterval(300)
        guard case .hypeTrain(let active) = try update(.hypeTrainProgress(hypeTrain(level: 2, expiresAt: expires, type: "golden_kappa"))) else {
            Issue.record("expected .hypeTrain"); return
        }
        #expect(active.level == 2)
        #expect(active.levelFraction == 0.2)
        #expect(active.expiresAt == expires)
        #expect(active.isGoldenKappa)
        #expect(active.status == .active)

        guard case .hypeTrain(let ended) = try update(.hypeTrainEnd(hypeTrain(level: 3, total: nil))) else {
            Issue.record("expected .hypeTrain"); return
        }
        #expect(ended.status == .ended)
        #expect(ended.levelFraction == nil)
        #expect(ended.expiresAt == nil)
    }

    @Test("live events route by broadcaster id")
    func routing() throws {
        #expect(ChannelSession.broadcasterUserId(from: .pollProgress(try poll())) == channelId)
        #expect(ChannelSession.broadcasterUserId(from: .predictionLock(try prediction())) == channelId)
        #expect(ChannelSession.broadcasterUserId(from: .hypeTrainBegin(try hypeTrain())) == channelId)
    }

    // MARK: - Helix seed

    @Test("Helix seed: an active poll carries its deadline; a finished one is not news")
    func helixPollSeed() throws {
        func helixPoll(status: String) throws -> TwitchPoll {
            let json = """
            {
                "id": "poll-9", "broadcaster_id": "\(channelId)", "broadcaster_login": "me", "broadcaster_name": "Me",
                "title": "Snack?",
                "choices": [{ "id": "a", "title": "Chips", "votes": 3, "channel_points_votes": 0, "bits_votes": 0 }],
                "bits_voting_enabled": false, "bits_per_vote": 0,
                "channel_points_voting_enabled": false, "channel_points_per_vote": 0,
                "status": "\(status)", "duration": 120, "started_at": "\(iso(t0))"
            }
            """
            return try decoder.decode(TwitchPoll.self, from: Data(json.utf8))
        }
        guard case .poll(let p) = try #require(LiveEventUpdate(helixPoll: try helixPoll(status: "ACTIVE"))) else {
            Issue.record("expected .poll"); return
        }
        #expect(p.endsAt == t0.addingTimeInterval(120))
        #expect(p.choices.first?.votes == 3)
        #expect(LiveEventUpdate(helixPoll: try helixPoll(status: "COMPLETED")) == nil)
    }

    @Test("Helix seed: active and locked predictions seed, resolved ones don't")
    func helixPredictionSeed() throws {
        func helixPrediction(status: String) throws -> TwitchPrediction {
            let json = """
            {
                "id": "pred-9", "broadcaster_id": "\(channelId)", "broadcaster_login": "me", "broadcaster_name": "Me",
                "title": "Clutch?",
                "outcomes": [
                    { "id": "y", "title": "Yes", "users": 2, "channel_points": 500, "color": "BLUE" },
                    { "id": "n", "title": "No", "users": 1, "channel_points": 100, "color": "PINK" }
                ],
                "prediction_window": 60, "status": "\(status)", "created_at": "\(iso(t0))"
            }
            """
            return try decoder.decode(TwitchPrediction.self, from: Data(json.utf8))
        }
        guard case .prediction(let active) = try #require(LiveEventUpdate(helixPrediction: try helixPrediction(status: "ACTIVE"))) else {
            Issue.record("expected .prediction"); return
        }
        #expect(active.locksAt == t0.addingTimeInterval(60))
        #expect(active.outcomes.map(\.color) == ["blue", "pink"])

        guard case .prediction(let locked) = try #require(LiveEventUpdate(helixPrediction: try helixPrediction(status: "LOCKED"))) else {
            Issue.record("expected .prediction"); return
        }
        #expect(locked.status == .locked)
        #expect(locked.locksAt == nil)
        #expect(LiveEventUpdate(helixPrediction: try helixPrediction(status: "RESOLVED")) == nil)
    }

    // MARK: - Reducer

    @Test("poll lifecycle: begin → progress → end stamps concludedAt; a late progress can't revive it")
    func pollLifecycle() throws {
        var state = LiveEventsState()
        #expect(state.apply(try update(.pollBegin(poll())), at: t0))
        #expect(state.apply(try update(.pollProgress(poll(votes: [3, 1]))), at: t0.addingTimeInterval(5)))
        #expect(state.poll?.leadingChoiceIds == ["c0"])
        #expect(state.poll?.fraction(of: state.poll!.choices[0]) == 0.75)

        let endedAt = t0.addingTimeInterval(60)
        #expect(state.apply(try update(.pollEnd(poll(votes: [3, 4], status: "completed"))), at: endedAt))
        #expect(state.poll?.status == .completed)
        #expect(state.poll?.concludedAt == endedAt)

        // Out-of-order progress after the end: ignored, nothing changes.
        #expect(!state.apply(try update(.pollProgress(poll(votes: [9, 9]))), at: endedAt.addingTimeInterval(1)))
        #expect(state.poll?.choices.map(\.votes) == [3, 4])
        #expect(state.poll?.concludedAt == endedAt)
    }

    @Test("archived poll is removed; an archive for a different poll is ignored")
    func pollArchive() throws {
        var state = LiveEventsState()
        state.apply(try update(.pollBegin(poll(id: "keep"))), at: t0)
        #expect(!state.apply(try update(.pollEnd(poll(id: "other", status: "archived"))), at: t0))
        #expect(state.poll?.id == "keep")
        #expect(state.apply(try update(.pollEnd(poll(id: "keep", status: "archived"))), at: t0))
        #expect(state.poll == nil)
    }

    @Test("poll deadline fills in once and survives later progress events")
    func pollDeadline() throws {
        var state = LiveEventsState()
        state.apply(try update(.pollBegin(poll())), at: t0)
        #expect(state.poll?.endsAt == nil)

        let deadline = t0.addingTimeInterval(90)
        #expect(state.apply(.pollDeadline(pollId: "poll-1", endsAt: deadline), at: t0))
        // For another poll: no-op.
        #expect(!state.apply(.pollDeadline(pollId: "nope", endsAt: t0), at: t0))

        state.apply(try update(.pollProgress(poll(votes: [1, 0]))), at: t0.addingTimeInterval(3))
        #expect(state.poll?.endsAt == deadline)
        #expect(state.poll?.choices.first?.votes == 1)
    }

    @Test("a new poll replaces the previous one")
    func newPollReplaces() throws {
        var state = LiveEventsState()
        state.apply(try update(.pollEnd(poll(id: "old", votes: [1, 1], status: "completed"))), at: t0)
        state.apply(try update(.pollBegin(poll(id: "new"))), at: t0.addingTimeInterval(2))
        #expect(state.poll?.id == "new")
        #expect(state.poll?.status == .active)
        #expect(state.poll?.concludedAt == nil)
    }

    @Test("prediction: a progress after lock is ignored; resolve stamps concludedAt")
    func predictionLifecycle() throws {
        var state = LiveEventsState()
        let locks = t0.addingTimeInterval(120)
        state.apply(try update(.predictionBegin(prediction(locksAt: locks))), at: t0)
        #expect(state.prediction?.locksAt == locks)

        state.apply(try update(.predictionLock(prediction(points: [100, 200]))), at: t0.addingTimeInterval(120))
        #expect(state.prediction?.status == .locked)
        #expect(!state.apply(try update(.predictionProgress(prediction(points: [999, 999], locksAt: locks))), at: t0.addingTimeInterval(121)))
        #expect(state.prediction?.totalPoints == 300)

        let resolvedAt = t0.addingTimeInterval(200)
        state.apply(try update(.predictionEnd(prediction(points: [100, 200], status: "resolved", winner: "o0"))), at: resolvedAt)
        #expect(state.prediction?.status == .resolved)
        #expect(state.prediction?.winningOutcomeId == "o0")
        #expect(state.prediction?.concludedAt == resolvedAt)
    }

    @Test("hype train: end keeps the last known total and stamps concludedAt")
    func hypeTrainLifecycle() throws {
        var state = LiveEventsState()
        state.apply(try update(.hypeTrainBegin(hypeTrain(level: 1, total: 300))), at: t0)
        state.apply(try update(.hypeTrainProgress(hypeTrain(level: 2, total: 1500))), at: t0.addingTimeInterval(10))
        #expect(state.hypeTrain?.level == 2)

        let endedAt = t0.addingTimeInterval(400)
        state.apply(try update(.hypeTrainEnd(hypeTrain(level: 2, total: nil, progress: nil, goal: nil))), at: endedAt)
        #expect(state.hypeTrain?.status == .ended)
        #expect(state.hypeTrain?.total == 1500)
        #expect(state.hypeTrain?.concludedAt == endedAt)
        // A late progress can't restart it.
        #expect(!state.apply(try update(.hypeTrainProgress(hypeTrain(level: 2))), at: endedAt.addingTimeInterval(1)))
    }

    @Test("prune: results linger for resultLinger, overdue active events go after overdueGrace")
    func prune() throws {
        var state = LiveEventsState()
        let endedAt = t0.addingTimeInterval(60)
        state.apply(try update(.pollEnd(poll(votes: [1, 0], status: "completed"))), at: endedAt)
        let trainExpiry = t0.addingTimeInterval(30)
        state.apply(try update(.hypeTrainProgress(hypeTrain(expiresAt: trainExpiry))), at: t0)

        // Next prune is the earlier of: poll result linger, train overdue.
        let pollGone = endedAt.addingTimeInterval(LiveEventsState.resultLinger)
        let trainGone = trainExpiry.addingTimeInterval(LiveEventsState.overdueGrace)
        #expect(state.nextPruneDate() == min(pollGone, trainGone))

        #expect(!state.prune(now: endedAt.addingTimeInterval(1)))
        #expect(state.prune(now: pollGone))
        #expect(state.poll == nil)
        #expect(state.hypeTrain != nil)

        #expect(state.prune(now: trainGone))
        #expect(state.hypeTrain == nil)
        #expect(state.nextPruneDate() == nil)
        #expect(state.isEmpty)
    }

    @Test("attention: appearing, status changes and level-ups pop a banner; plain ticks don't")
    func attention() throws {
        var state = LiveEventsState()
        var old = state
        state.apply(try update(.pollBegin(poll())), at: t0)
        #expect(state.attentionKind(comparedTo: old) == .poll)

        old = state
        state.apply(try update(.pollProgress(poll(votes: [2, 1]))), at: t0)
        #expect(state.attentionKind(comparedTo: old) == nil)

        old = state
        state.apply(try update(.pollEnd(poll(votes: [2, 1], status: "completed"))), at: t0)
        #expect(state.attentionKind(comparedTo: old) == .poll)

        // Priority: a train beginning alongside a prediction wins.
        old = state
        state.apply(try update(.predictionBegin(prediction())), at: t0)
        state.apply(try update(.hypeTrainBegin(hypeTrain(level: 1))), at: t0)
        #expect(state.attentionKind(comparedTo: old) == .hypeTrain)

        old = state
        state.apply(try update(.hypeTrainProgress(hypeTrain(level: 1, progress: 600))), at: t0)
        #expect(state.attentionKind(comparedTo: old) == nil)

        old = state
        state.apply(try update(.hypeTrainProgress(hypeTrain(level: 2, progress: 10))), at: t0)
        #expect(state.attentionKind(comparedTo: old) == .hypeTrain)
    }

    // MARK: - Mailbox

    @Test("subscription is primed and rung, keeps only the latest state, and takes once")
    func subscriptionLatestValue() async throws {
        var first = LiveEventsState()
        first.apply(try update(.pollBegin(poll(id: "a"))), at: t0)
        let subscription = LiveEventsSubscription(initial: first)

        var wakeups = subscription.wakeups.makeAsyncIterator()
        #expect(await wakeups.next() != nil)
        #expect(subscription.takeLatest()?.poll?.id == "a")
        #expect(subscription.takeLatest() == nil)

        var second = LiveEventsState()
        second.apply(try update(.pollBegin(poll(id: "b"))), at: t0)
        var third = LiveEventsState()
        third.apply(try update(.pollBegin(poll(id: "c"))), at: t0)
        subscription.post(second)
        subscription.post(third)
        #expect(subscription.takeLatest()?.poll?.id == "c")

        subscription.finish()
    }
}

/// The session side: live events bypass the chat ring entirely and reach
/// banner consumers through their own mailbox.
@Suite("ChannelSession live events", .timeLimit(.minutes(1)))
struct ChannelSessionLiveEventsTests {

    private struct NullTokenStore: TwitchTokenStore {
        func loadToken() async throws -> OAuthToken? { nil }
        func saveToken(_ token: OAuthToken) async throws {}
        func deleteToken() async throws {}
    }

    private func makeSession() async -> ChannelSession {
        let session = ChannelSession(
            client: TwitchClient(clientId: "test-client", tokenStore: NullTokenStore()),
            channelId: "1",
            channelLoginName: "ch",
            accountUserId: "1",
            fetchBackfill: { _, _ in [] }
        )
        await session.applyBackfill([])
        return session
    }

    private func pollBegin() throws -> EventSubEvent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let json = """
        {
            "id": "poll-1",
            "broadcaster_user_id": "1",
            "broadcaster_user_login": "ch",
            "broadcaster_user_name": "Ch",
            "title": "Best map?",
            "choices": [{ "id": "a", "title": "A" }, { "id": "b", "title": "B" }],
            "bits_voting": { "is_enabled": false },
            "channel_points_voting": { "is_enabled": false },
            "started_at": "2027-01-01T00:00:00Z"
        }
        """
        return .pollBegin(try decoder.decode(EventSubPoll.self, from: Data(json.utf8)))
    }

    @Test("a poll event reaches live-event subscribers and never the chat ring")
    func pollBypassesRing() async throws {
        let session = await makeSession()
        let chat = await session.subscribe()
        let live = await session.subscribeLiveEvents()
        // Primed with the (empty) current state.
        #expect(live.takeLatest()?.isEmpty == true)

        try await session.handle(event: pollBegin())

        #expect(live.takeLatest()?.poll?.title == "Best map?")
        #expect(chat.subscription.takePending().isEmpty)
        #expect(await session.currentSnapshot().isEmpty)

        // A late subscriber is primed with the running poll.
        let late = await session.subscribeLiveEvents()
        #expect(late.takeLatest()?.poll?.id == "poll-1")

        await session.unsubscribeLiveEvents(live.token)
        await session.unsubscribeLiveEvents(late.token)
    }
}
