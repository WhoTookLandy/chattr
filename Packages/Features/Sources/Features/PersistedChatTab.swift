import Foundation
import SwiftData

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
/// `init(from:order:)` and `toChatTab()` — a 1:1 mapping that costs nothing.
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

    public init(id: UUID, order: Int, channels: [ChannelDescriptor], addedAt: Date = .now) {
        self.id = id
        self.order = order
        self.channels = channels
        self.addedAt = addedAt
    }

    /// Construct a persistence row from a runtime `ChatTab`.
    public convenience init(from tab: ChatTab, order: Int) {
        self.init(id: tab.id, order: order, channels: tab.channels)
    }

    /// Project back to the runtime `ChatTab` representation. SwiftUI views
    /// always see `ChatTab`, never `PersistedChatTab` — this conversion
    /// happens at the persistence boundary in `TabPersistence`.
    public func toChatTab() -> ChatTab {
        // ChatTab's init has a precondition that channels is non-empty.
        // If persistence somehow ended up with an empty channels array
        // (shouldn't happen — we never write that), the precondition will
        // crash, which is correct: it surfaces the data-integrity bug
        // immediately rather than silently rendering a broken tab.
        ChatTab(id: id, channels: channels)
    }
}
