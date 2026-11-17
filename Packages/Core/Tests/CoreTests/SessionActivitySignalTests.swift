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

    @Test("One account's open channel doesn't make another account active")
    func perAccountIsolation() {
        let signal = SessionActivitySignal()
        signal.increment(forAccount: "a")
        #expect(signal.hasActiveSessions(forAccount: "a") == true)
        #expect(signal.hasActiveSessions(forAccount: "b") == false)
        #expect(signal.hasActiveSessions == true)
        signal.decrement(forAccount: "a")
        #expect(signal.hasActiveSessions(forAccount: "a") == false)
        #expect(signal.hasActiveSessions == false)
    }

    @Test("Per-account counts balance and never underflow")
    func perAccountCounting() {
        let signal = SessionActivitySignal()
        signal.decrement(forAccount: "a")           // spurious release
        signal.increment(forAccount: "a")
        signal.increment(forAccount: "a")
        signal.decrement(forAccount: "a")
        #expect(signal.hasActiveSessions(forAccount: "a") == true)
        signal.decrement(forAccount: "a")
        #expect(signal.hasActiveSessions(forAccount: "a") == false)
    }

    @Test("An account-less channel counts for every account")
    func unattributedCountsForAll() {
        let signal = SessionActivitySignal()
        signal.increment()
        #expect(signal.hasActiveSessions(forAccount: "a") == true)
        signal.decrement()
        #expect(signal.hasActiveSessions(forAccount: "a") == false)
    }
}
