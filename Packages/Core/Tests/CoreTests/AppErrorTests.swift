import Foundation
import Testing
@testable import Core

@Suite("AppError")
struct AppErrorTests {
    @Test("localizedDescription returns the message field")
    func localizedDescriptionReturnsMessage() {
        let error = AppError(message: "Session expired for @landy - please sign in again")
        #expect(error.localizedDescription == "Session expired for @landy - please sign in again")
    }

    @Test("localizedDescription works when surfaced as Error")
    func localizedDescriptionViaErrorExistential() {
        let error: Error = AppError(message: "Couldn't open chat")
        #expect(error.localizedDescription == "Couldn't open chat")
    }

    @Test("underlying error is captured as a string")
    func underlyingErrorIsCaptured() {
        struct LowLevel: Error, CustomStringConvertible {
            var description: String { "low-level boom" }
        }
        let error = AppError(message: "wrapped", underlying: LowLevel())
        #expect(error.underlying == "low-level boom")
        #expect(error.localizedDescription == "wrapped")
    }

    // MARK: - Structured Kind tests

    @Test("sessionExpired factory builds the right Kind + message")
    func sessionExpiredFactory() {
        let error = AppError.sessionExpired(login: "xqc")
        if case .sessionExpired(let login) = error.kind {
            #expect(login == "xqc")
        } else {
            Issue.record("Expected .sessionExpired case")
        }
        #expect(error.localizedDescription == "Session expired for @xqc — please sign in again")
    }

    @Test("bridgeRefreshFailed factory carries the status code")
    func bridgeRefreshFailedFactory() {
        let error = AppError.bridgeRefreshFailed(status: 503)
        if case .bridgeRefreshFailed(let status) = error.kind {
            #expect(status == 503)
        } else {
            Issue.record("Expected .bridgeRefreshFailed case")
        }
        #expect(error.localizedDescription == "Token refresh failed (HTTP 503)")
    }

    @Test("legacy init(message:) preserves message via .unknown")
    func legacyInitUsesUnknownKind() {
        let error = AppError(message: "weird OAuth callback")
        if case .unknown(let msg) = error.kind {
            #expect(msg == "weird OAuth callback")
        } else {
            Issue.record("Expected .unknown case from legacy init")
        }
        #expect(error.localizedDescription == "weird OAuth callback")
    }

    @Test("Equatable: same kind + underlying compare equal")
    func equatableSameKind() {
        let a = AppError.sessionExpired(login: "lirik")
        let b = AppError.sessionExpired(login: "lirik")
        #expect(a == b)
    }

    @Test("Equatable: different logins compare unequal")
    func equatableDifferentLogins() {
        let a = AppError.sessionExpired(login: "lirik")
        let b = AppError.sessionExpired(login: "shroud")
        #expect(a != b)
    }
}
