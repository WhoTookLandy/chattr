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
}
