import Foundation
import SwiftData
import Core

/// SwiftData on-disk projection of a `ChatTab`. Survives cold start so the
/// user's open tabs persist across app launches.
///
/// ## Why a separate type from `ChatTab`
///
/// `ChatTab` (struct, in `ChatTab.swift`) is the *runtime* model — cheap to
/// copy, `Sendable`, `Hashable`, used as a SwiftUI identity value. Making
/// `ChatTab` itself an `@Model` would force every consumer onto SwiftData's
/// reference-type, `@Observable`-on-`@MainActor` constraints, and would
/// break the struct's value semantics.
///
/// Instead `PersistedChatTab` is the *storage* model. The two convert via
/// `init(from:order:accountUserId:)` and `toChatTab()` — a 1:1 mapping that
/// costs nothing.
///
/// ## Why `channels` is a Codable array, not a relationship
///
/// `ChannelDescriptor` is a `Codable` value type. SwiftData supports
/// `Codable` arrays as native attribute types in iOS 17+, stored as binary
/// plist under the hood. A relationship to a separate `@Model` for
/// `ChannelDescriptor` would buy us nothing today (channels never appear
/// outside of a tab) and add fetch/save complexity. If a future feature
/// needs to query "which tabs contain channel X," we can split then.
///
/// ## Why `order: Int` exists
///
/// SwiftData `FetchDescriptor` doesn't preserve insertion order. The
/// user-visible tab order is itself data — `Lirik · shroud` to the left,
/// `xqc` to the right matters to the user. We sort fetches by `order`,
/// and `TabPersistence.save` writes contiguous integers (0, 1, 2, …) on
/// every change.
@Model
public final class PersistedChatTab {

    /// Mirrors `ChatTab.id`. The UUID is the same on disk and in memory so
    /// "find the persisted row for this in-memory tab" is an O(1) lookup
    /// by primary key.
    @Attribute(.unique) public var id: UUID

    /// User-defined ordering (left-to-right in the strip). Lower = leftward.
    /// Re-numbered on every write to stay contiguous, simplifying the
    /// "where do I insert this new tab" decision.
    public var order: Int

    /// The channels contained in this tab. Encoded as a serialized blob
    /// under the hood by SwiftData (since `ChannelDescriptor` is `Codable`).
    public var channels: [ChannelDescriptor]

    /// Original creation date. Useful for tie-breaking in "newest tab when
    /// active tab is gone" UX, and for future debug/analytics.
    public var addedAt: Date

    /// `Account.userId` of the account that owns this tab. Tabs are
    /// per-account: `TabPersistence` reads and writes only the rows of the
    /// account it was constructed for, so switching accounts restores that
    /// account's own strip.
    ///
    /// Added in `AppSchemaV2`. The `""` default is what lets the V1 → V2
    /// lightweight migration fill the new column on existing rows, so an
    /// empty value means "legacy row from before tabs were account-scoped".
    /// The first account to hydrate after the upgrade adopts those rows (see
    /// `TabPersistence.fetchAll()`).
    public var accountUserId: String = ""

    public init(
        id: UUID,
        order: Int,
        channels: [ChannelDescriptor],
        accountUserId: String,
        addedAt: Date = .now
    ) {
        self.id = id
        self.order = order
        self.channels = channels
        self.accountUserId = accountUserId
        self.addedAt = addedAt
    }

    /// Construct a persistence row from a runtime `ChatTab`.
    public convenience init(from tab: ChatTab, order: Int, accountUserId: String) {
        self.init(id: tab.id, order: order, channels: tab.channels, accountUserId: accountUserId)
    }

    /// Project back to the runtime `ChatTab` representation. SwiftUI views
    /// always see `ChatTab`, never `PersistedChatTab` — this conversion
    /// happens at the persistence boundary in `TabPersistence`.
    ///
    /// Returns `nil` for a corrupt row with no channels. We never write one,
    /// but `ChatTab.init` preconditions non-empty, and a crash on every
    /// launch is the worst way to surface bad data. Callers drop the `nil`s;
    /// the row itself is deleted by the next `TabPersistence.save(tabs:)`,
    /// which removes every row of the account that isn't in the strip.
    public func toChatTab() -> ChatTab? {
        guard !channels.isEmpty else { return nil }
        return ChatTab(id: id, channels: channels)
    }
}
