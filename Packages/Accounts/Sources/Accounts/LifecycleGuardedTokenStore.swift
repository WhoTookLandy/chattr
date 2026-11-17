import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.LifecycleGuardedTokenStore")

/// The token store every chattr-built `TwitchClient` gets. It passes reads
/// through and lets writes through only when the client's
/// `TwitchClientLifecycle` allows them (see the table there):
///
/// - Saves only while the client is `.active`, so a refresh that settles
///   after the account was removed or re-authorized can't put a stale
///   credential back.
/// - Deletes only while chattr is deliberately signing the client out
///   (`.signingOut`). TwitchKit 0.3.4 calls `logout()` on every failed
///   refresh, whatever the reason; those deletes are dropped, so a transient
///   failure can never wipe a credential. A dead refresh token still signs
///   the account out: `AccountStore.forceSignOut` deletes the token itself.
///
/// The lifecycle check and the write it admits are one critical section on
/// the account's `AccountTokenGate`, which every other client for the
/// account and the cache's lifecycle transitions share. A write admitted
/// while the client was active therefore finishes before the client can be
/// retired, and before a re-authorization writes its new credential.
///
/// Within one active client, saves are also ordered by freshness (see
/// `AccountTokenGate.admitSave`): a save of a token older than the newest
/// bridge-issued one is dropped, so a TwitchKit save that arrives late can't
/// roll the account back to a superseded token. TwitchKit's
/// `TwitchTokenProvider.setToken` assigns its in-memory token *before* it
/// calls the store, so dropping the write alone would leave the provider on
/// the old token. After releasing the gate, the store therefore hands the
/// newest token back to the provider (`providerLink`). That second
/// `setToken` re-enters this store, finds the entry already holds the token
/// and writes nothing, so it can't loop.
///
/// Dropped writes don't throw: TwitchKit treats a throwing store as one more
/// refresh failure and calls `logout()` again.
struct LifecycleGuardedTokenStore: TwitchTokenStore {
    let base: any TwitchTokenStore
    let lifecycle: TwitchClientLifecycle
    let gate: AccountTokenGate
    /// The provider of the client this store belongs to, attached once the
    /// client exists. Only used to re-seed it after a superseded save.
    let providerLink: TokenProviderLink

    init(
        base: any TwitchTokenStore,
        lifecycle: TwitchClientLifecycle,
        gate: AccountTokenGate,
        providerLink: TokenProviderLink = TokenProviderLink()
    ) {
        self.base = base
        self.lifecycle = lifecycle
        self.gate = gate
        self.providerLink = providerLink
    }

    func loadToken() async throws -> OAuthToken? {
        try await base.loadToken()
    }

    func saveToken(_ token: OAuthToken) async throws {
        let newest = try await gate.withLock { () async throws -> OAuthToken? in
            guard lifecycle.isActive else {
                logger.notice("Dropped a token save from a client that is no longer the account's client")
                return nil
            }
            switch gate.admitSave(token) {
            case .write:
                try await base.saveToken(token)
                gate.didPersist(token)
                // Re-seed the provider with what was just persisted, too.
                // TwitchKit assigns memory BEFORE calling the store, so a
                // late, stale `setToken(T1)` can have landed in memory
                // while this save of T2 waited at the gate (and got
                // `.alreadyStored` itself, since T1 was still the newest
                // persisted). Re-asserting T2 here leaves memory matching
                // the Keychain. The re-seed comes back as `.alreadyStored`,
                // which never re-seeds, so it can't loop. Only for a
                // bridge-issued token that is now the newest: a save made
                // before any bridge token (newest unset) would be admitted
                // as `.write` again and loop.
                if case .alreadyStored = gate.admitSave(token) { return token }
                return nil
            case .alreadyStored:
                return nil
            case .superseded(let newer):
                logger.notice("Dropped a save of a superseded token; keeping the newest bridge-issued token")
                return newer
            }
        }
        // Outside the gate: this `setToken` comes back through `saveToken`,
        // and the gate isn't reentrant.
        guard let newest, let provider = providerLink.provider else { return }
        do {
            try await provider.setToken(newest)
        } catch {
            // Not expected: the re-seed writes nothing (the entry already
            // holds `newest`), and the provider has taken `newest` in
            // memory before calling the store either way.
            logger.warning("Re-seeding the token provider after a superseded save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteToken() async throws {
        try await gate.withLock {
            guard lifecycle.current == .signingOut else {
                logger.notice("Dropped a token delete chattr didn't ask for (TwitchKit gave up on a refresh)")
                return
            }
            try await base.deleteToken()
        }
    }
}
