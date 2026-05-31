import Testing
@testable import Core

@Suite("SessionActivitySignal")
struct SessionActivitySignalTests {
    @Test("Starts with no active sessions")
    func startsInactive() {
        let signal = SessionActivitySignal()
        #expect(signal.hasActiveSessions == false)
    }

    @Test("Active after an increment, inactive after the matching decrement")
    func incrementDecrement() {
        let signal = SessionActivitySignal()
        signal.increment()
        #expect(signal.hasActiveSessions == true)
        signal.decrement()
        #expect(signal.hasActiveSessions == false)
    }

    @Test("Stays active while any increment outstanding")
    func balancedCounting() {
        let signal = SessionActivitySignal()
        signal.increment()
        signal.increment()
        signal.decrement()
        #expect(signal.hasActiveSessions == true)   // one still open
        signal.decrement()
        #expect(signal.hasActiveSessions == false)
    }

    @Test("Decrement never underflows below zero")
    func noUnderflow() {
        let signal = SessionActivitySignal()
        signal.decrement()                          // spurious release
        #expect(signal.hasActiveSessions == false)
        signal.increment()
        #expect(signal.hasActiveSessions == true)   // count is 1, not 2
    }
}
