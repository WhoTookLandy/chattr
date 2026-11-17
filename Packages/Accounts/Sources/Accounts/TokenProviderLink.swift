import Foundation
import TwitchKit
import os

/// A weak, late-bound reference from a client's `LifecycleGuardedTokenStore`
/// to that client's `TwitchTokenProvider`.
///
/// The store is built before the `TwitchClient` (TwitchKit builds the
/// provider from it), so `TwitchClientCache` attaches the provider once the
/// client exists. Weak because the provider owns the store: a strong
/// reference would keep every retired client alive.
final class TokenProviderLink: Sendable {
    private struct Reference: @unchecked Sendable {
        weak var provider: TwitchTokenProvider?
    }

    private let reference = OSAllocatedUnfairLock(initialState: Reference())

    var provider: TwitchTokenProvider? {
        reference.withLock { $0.provider }
    }

    func attach(_ provider: TwitchTokenProvider) {
        reference.withLock { $0.provider = provider }
    }
}
