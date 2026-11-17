import Foundation

/// Hands out one `FollowsStore` per account.
///
/// Switching accounts starts a fresh store, so a load still in flight for
/// the previous account finishes into a store nothing displays any more.
/// `FollowsStore` still fences its own entry points by account id; this
/// makes cross-account writes impossible by construction rather than by
/// every caller getting that fencing right.
@MainActor
final class FollowsStoreScope {
    private var accountUserId: String?
    private var current: FollowsStore?

    /// The store for `accountUserId` (`nil` while signed out). The same
    /// instance is returned until the id changes.
    func store(forAccountUserId accountUserId: String?) -> FollowsStore {
        if let current, accountUserId == self.accountUserId {
            return current
        }
        let fresh = FollowsStore()
        self.accountUserId = accountUserId
        current = fresh
        return fresh
    }
}
