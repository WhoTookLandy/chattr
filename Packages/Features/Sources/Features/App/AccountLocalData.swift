import Foundation
import SwiftData
import Core
import os

private let logger = AppLogger.make("Features.AccountLocalData")

/// Per-account state that Features keeps outside the `Account` row: the
/// persisted chat-tab strip (`PersistedChatTab` rows), compose drafts, and
/// the block-list cache.
///
/// `Accounts` can't clean these up itself — it sits below Features and must
/// not import it — so the app's composition root wires `remove` to
/// `AccountStore.onAccountRemoved`. Only user-initiated removal triggers it;
/// an expired (`needsReauth`) account keeps its tabs and drafts for when the
/// user re-authorizes.
@MainActor
public enum AccountLocalData {

    /// Delete everything Features persists for `accountUserId`. Best-effort:
    /// a failed tab delete is logged, and the drafts / block-cache cleanup
    /// still runs.
    public static func remove(forAccountUserId accountUserId: String, modelContainer: ModelContainer) {
        // An empty id would match the legacy unowned tab rows that the next
        // account is meant to adopt — never a real account's data.
        guard !accountUserId.isEmpty else { return }
        do {
            try TabPersistence(modelContainer: modelContainer, accountUserId: accountUserId).deleteAll()
        } catch {
            logger.error("Deleting tabs for removed account \(accountUserId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        DraftStorage.removeAll(forAccount: accountUserId)
        BlockStore.removePersisted(forAccountUserId: accountUserId)
        logger.notice("Removed local data for account \(accountUserId, privacy: .public)")
    }
}
