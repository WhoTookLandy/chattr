import Testing
import Foundation
@testable import Channels

/// The reconnect gap-fill's bookkeeping in isolation: one fetch at a time,
/// one coalesced follow-up, and the gap floor a client rebind leaves behind
/// when chat couldn't be subscribed straight away.
@Suite("ReconnectResyncState")
struct ReconnectResyncStateTests {

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    @Test("Starts idle with nothing queued")
    func startsIdle() {
        let state = ReconnectResyncState()
        #expect(!state.isInFlight)
        #expect(state.followUpFloor == nil)
        #expect(state.chatGapFloor == nil)
    }

    @Test("The first request fetches, from the newest live receipt when no drop time is known")
    func firstRequestFetches() {
        var state = ReconnectResyncState()
        let floor = state.request(lastLiveReceiptAt: at(100), droppedAt: nil)
        #expect(floor == at(100))
        #expect(state.isInFlight)
        #expect(state.followUpFloor == nil)
    }

    @Test("The floor is the earlier of the drop time and the newest live receipt")
    func floorIsTheEarlierOfDropAndReceipt() {
        // Live rows arrived after the reconnect: the drop time still floors
        // the gap.
        var afterReconnect = ReconnectResyncState()
        let dropFloor = afterReconnect.request(lastLiveReceiptAt: at(100), droppedAt: at(40))
        #expect(dropFloor == at(40))

        // The socket was seen down only after the last live row.
        var quietBeforeDrop = ReconnectResyncState()
        let receiptFloor = quietBeforeDrop.request(lastLiveReceiptAt: at(100), droppedAt: at(130))
        #expect(receiptFloor == at(100))
    }

    @Test("A request during a fetch is queued, not run and not dropped")
    func requestDuringFetchIsQueued() {
        var state = ReconnectResyncState()
        _ = state.request(lastLiveReceiptAt: at(100), droppedAt: nil)

        let second = state.request(lastLiveReceiptAt: at(200), droppedAt: nil)
        #expect(second == nil)
        #expect(state.isInFlight)
        #expect(state.followUpFloor == at(200))
    }

    @Test("Any number of queued requests collapse into one follow-up from the earliest floor")
    func queuedRequestsCoalesce() {
        var state = ReconnectResyncState()
        _ = state.request(lastLiveReceiptAt: at(100), droppedAt: nil)
        _ = state.request(lastLiveReceiptAt: at(200), droppedAt: nil)
        _ = state.request(lastLiveReceiptAt: at(300), droppedAt: at(150))
        _ = state.request(lastLiveReceiptAt: at(400), droppedAt: nil)
        #expect(state.followUpFloor == at(150))

        let followUp = state.takeFollowUp()
        #expect(followUp == at(150))
        // Exactly one: the fetch after it finds nothing queued.
        let afterFollowUp = state.takeFollowUp()
        #expect(afterFollowUp == nil)
        #expect(state.followUpFloor == nil)
        // Still the same loop until the caller says it ended.
        #expect(state.isInFlight)
    }

    @Test("A request that arrives during the follow-up fetch queues another one")
    func requestDuringFollowUpQueuesAgain() {
        var state = ReconnectResyncState()
        _ = state.request(lastLiveReceiptAt: at(100), droppedAt: nil)
        _ = state.request(lastLiveReceiptAt: at(200), droppedAt: nil)
        _ = state.takeFollowUp()

        let third = state.request(lastLiveReceiptAt: at(300), droppedAt: nil)
        #expect(third == nil)
        let next = state.takeFollowUp()
        #expect(next == at(300))
    }

    @Test("Once the loop ends, the next request fetches again")
    func finishAllowsTheNextFetch() {
        var state = ReconnectResyncState()
        _ = state.request(lastLiveReceiptAt: at(100), droppedAt: nil)
        _ = state.takeFollowUp()
        state.finish()
        #expect(!state.isInFlight)

        let floor = state.request(lastLiveReceiptAt: at(500), droppedAt: nil)
        #expect(floor == at(500))
        #expect(state.isInFlight)
    }

    // MARK: - Gap floor after a client rebind

    @Test("A rebind that subscribed chat leaves no gap open")
    func reboundWithChatLeavesNoGap() {
        var state = ReconnectResyncState()
        state.rebound(chatFailed: false, gapFloor: at(100))
        #expect(state.chatGapFloor == nil)
        let floor = state.takeChatGapFloor(chatSubscribed: true)
        #expect(floor == nil)
    }

    @Test("A rebind that couldn't subscribe chat keeps its floor until a retry subscribes it")
    func reboundWithoutChatKeepsTheFloor() {
        var state = ReconnectResyncState()
        state.rebound(chatFailed: true, gapFloor: at(100))
        #expect(state.chatGapFloor == at(100))

        // A retry round where chat still failed: the gap stays open.
        let stillFailing = state.takeChatGapFloor(chatSubscribed: false)
        #expect(stillFailing == nil)
        #expect(state.chatGapFloor == at(100))

        // Chat is back: resync from the floor, once.
        let floor = state.takeChatGapFloor(chatSubscribed: true)
        #expect(floor == at(100))
        let again = state.takeChatGapFloor(chatSubscribed: true)
        #expect(again == nil)
    }

    @Test("A later rebind that subscribes chat closes the gap an earlier one left open")
    func laterReboundClosesTheGap() {
        var state = ReconnectResyncState()
        state.rebound(chatFailed: true, gapFloor: at(100))
        state.rebound(chatFailed: false, gapFloor: at(200))
        #expect(state.chatGapFloor == nil)
    }

    @Test("The rebind's gap floor and the fetch in flight don't disturb each other")
    func gapFloorIsIndependentOfTheFetch() {
        var state = ReconnectResyncState()
        _ = state.request(lastLiveReceiptAt: at(100), droppedAt: nil)
        state.rebound(chatFailed: true, gapFloor: at(50))
        #expect(state.isInFlight)

        // The retry's resync arrives while the rebind's own is in flight:
        // it is queued from the rebind's floor.
        let gapFloor = state.takeChatGapFloor(chatSubscribed: true)
        #expect(gapFloor == at(50))
        let queued = state.request(lastLiveReceiptAt: at(300), droppedAt: gapFloor)
        #expect(queued == nil)
        #expect(state.followUpFloor == at(50))
    }
}
