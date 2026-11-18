import Foundation

/// Which `AppShell`s are live for each account, by a token minted each time
/// a shell wires itself up. A shell that goes away sweeps the account's
/// leftover sessions only if no other shell is live for it once its tab
/// releases have finished. Switching away and straight back mounts a new
/// shell for the same account, and a second window (iPad) has a shell of its
/// own on the same registry: the sweep ignores refcounts, so it must not run
/// under either.
@MainActor
enum ShellSessionOwners {
    static var live: [String: Set<UUID>] = [:]

    /// Takes `owner` out of the account's live shells. True only when it
    /// was still there and was the last one, which is when the caller may
    /// sweep.
    static func retire(_ owner: UUID, forAccountUserId accountUserId: String) -> Bool {
        guard live[accountUserId]?.remove(owner) != nil else { return false }
        guard live[accountUserId]?.isEmpty == true else { return false }
        live[accountUserId] = nil
        return true
    }
}
