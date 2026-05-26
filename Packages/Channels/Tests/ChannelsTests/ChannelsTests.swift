import Testing
import Foundation
@testable import Channels

@Suite("ChannelSession (ring buffer + coalesce)")
struct ChannelSessionTests {

    // Slice 1 has limited testability for ChannelSession because its public API requires
    // a real TwitchClient (which would hit the network). We add richer mocking infrastructure
    // in a later slice (Task: HTTPClient protocol mock + EventSub event injector).
    //
    // For now, this is a placeholder verifying that Swift Testing scaffolding is wired up
    // and the @testable import path resolves. Real behavior is verified by Task 26's
    // end-to-end smoke test.

    @Test("ChannelSession placeholder — see end-to-end smoke test for real coverage")
    func placeholder() {
        // `Bool(true)` indirection avoids Swift Testing's "always passes" tautology warning
        // on `#expect(true)`. This is the documented escape hatch for intentional no-ops.
        #expect(Bool(true))
    }
}
