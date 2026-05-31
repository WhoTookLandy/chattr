import Testing
import TwitchKit
@testable import Channels

@MainActor
@Suite("ConnectionStatusStore")
struct ConnectionStatusStoreTests {
    @Test("Defaults to .connecting")
    func defaultState() {
        let store = ConnectionStatusStore()
        #expect(store.state == .connecting)
    }

    @Test("update(_:) reflects the latest connection state")
    func updates() {
        let store = ConnectionStatusStore()
        store.update(.connected)
        #expect(store.state == .connected)
        store.update(.waitingForNetwork)
        #expect(store.state == .waitingForNetwork)
    }
}
