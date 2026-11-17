import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.TwitchSignIn")

/// Device Code Grant entry points for the shared sign-in flow. Kept out of
/// `TwitchSignIn.swift` so scope-list edits there and device-code edits here
/// don't collide.
///
/// Both halves reuse `TwitchSignIn.scopes`, so the device-code and browser
/// paths always request (and record) the same scope set.
extension TwitchSignIn {

    /// A `DeviceCodeGrant` for chattr's client and scope list.
    public static func deviceCodeGrant(clientId: String) -> DeviceCodeGrant {
        DeviceCodeGrant(clientId: clientId, scopes: scopes)
    }

    /// Finishes a device-code sign-in: same `AccountStore.add` the browser
    /// flow ends in (`/users` probe, Keychain + refresh-token cache,
    /// SwiftData insert, becomes active). The token's refresh_token is later
    /// renewed through the bridge like any other account's.
    @discardableResult
    public static func completeDeviceCodeSignIn(token: OAuthToken, accountStore: AccountStore) async throws -> Account {
        let account = try await accountStore.add(token: token, scopes: scopes)
        logger.info("Device-code sign-in succeeded for @\(account.login, privacy: .public)")
        return account
    }
}
