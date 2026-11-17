import Foundation
import os

/// Where one `TwitchClient` built by `TwitchClientCache` is in its life, and
/// therefore what its token store may do.
///
/// ## Why this exists
///
/// Every client for an account shares one Keychain entry (the namespace is
/// derived from the userId). A client that was evicted (the account was
/// removed, force-signed-out or re-authorized) can still be mid-request: its
/// `HelixClient` may be waiting on a bridge refresh. When that refresh
/// settles, TwitchKit would save the result, or (on any failure) call
/// `logout()` and delete the token. Either write lands in the shared entry,
/// so it could restore a removed account's credential or wipe a
/// re-authorized account's new one.
///
/// TwitchKit 0.3.4 offers no failure that skips that delete:
/// `TwitchTokenProvider.refreshIfNeeded()` calls `logout()` for *any* error
/// thrown by the refresh (non-200, decode failure, transport error, failed
/// save). So the guard lives in the token store instead
/// (`LifecycleGuardedTokenStore`), keyed off this state:
///
/// | State         | `saveToken` | `deleteToken` |
/// |---------------|-------------|---------------|
/// | `.active`     | yes         | no: TwitchKit never deletes on its own |
/// | `.signingOut` | no          | yes: chattr's deliberate sign-out |
/// | `.retired`    | no          | no |
///
/// Transitions only move forward: `active → signingOut → retired`, or
/// straight to `retired`.
final class TwitchClientLifecycle: Sendable {
    enum State: Sendable, Equatable {
        case active
        case signingOut
        case retired
    }

    private let state = OSAllocatedUnfairLock(initialState: State.active)

    var current: State { state.withLock { $0 } }

    /// The client is the account's live client: refreshes may be saved.
    var isActive: Bool { current == .active }

    /// chattr is deliberately signing this client out (`remove`,
    /// `forceSignOut`): the delete that follows is allowed, nothing may be
    /// saved any more.
    func beginSignOut() {
        state.withLock {
            if $0 == .active { $0 = .signingOut }
        }
    }

    /// The client is no longer the account's client. Nothing it does may
    /// touch the shared token entry again.
    func retire() {
        state.withLock { $0 = .retired }
    }
}
