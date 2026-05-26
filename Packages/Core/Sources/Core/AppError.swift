import Foundation

/// Domain-agnostic error envelope used at high-level boundaries (UI surfaces, store actors).
/// Specific subsystems can still throw their own typed errors; this is for cases where the
/// UI just needs "something went wrong + display message".
public struct AppError: Error, Sendable, Equatable {
    public let message: String
    public let underlying: String?

    public init(message: String, underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying.map { "\($0)" }
    }
}

extension AppError: LocalizedError {
    public var errorDescription: String? { message }
}
