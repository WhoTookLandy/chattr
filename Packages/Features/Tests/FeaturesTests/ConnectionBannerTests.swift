import Testing
import TwitchKit
@testable import Features

@Suite("ConnectionBanner")
struct ConnectionBannerTests {
    @Test("Down states show Reconnecting")
    func downStates() {
        #expect(ConnectionBanner.next(previous: .connected, current: .reconnecting) == .reconnecting)
        #expect(ConnectionBanner.next(previous: .connected, current: .waitingForNetwork) == .reconnecting)
    }

    @Test("Recovering from a down state shows Live again")
    func recovery() {
        #expect(ConnectionBanner.next(previous: .reconnecting, current: .connected) == .liveAgain)
        #expect(ConnectionBanner.next(previous: .waitingForNetwork, current: .connected) == .liveAgain)
    }

    @Test("Steady connected is hidden")
    func steadyConnected() {
        #expect(ConnectionBanner.next(previous: .connected, current: .connected) == .hidden)
        #expect(ConnectionBanner.next(previous: nil, current: .connected) == .hidden)
    }

    @Test("Connecting and disconnected are hidden")
    func connectingAndDisconnected() {
        #expect(ConnectionBanner.next(previous: nil, current: .connecting) == .hidden)
        #expect(ConnectionBanner.next(previous: .connected, current: .disconnected) == .hidden)
    }

    @Test("First-ever connect (nil → connected) does not flash Live again")
    func firstConnectNoFlash() {
        // Cold start lands on .connected with no prior down state — must stay hidden.
        #expect(ConnectionBanner.next(previous: nil, current: .connected) == .hidden)
    }
}
