import SwiftUI
import Channels

/// SwiftUI environment plumbing for `ChannelSessionRegistry`. Lives in Features
/// rather than Channels because Channels intentionally doesn't import SwiftUI
/// (it's a UI-agnostic package).
///
/// Why nil default: `ChannelSessionRegistry.init(accountStore:)` requires an
/// `AccountStore` which can't be constructed in a static context. Optional
/// with nil default is the standard SwiftUI workaround — see GlobalCatalog /
/// FollowsStore for the same pattern. RootView always provides a real value;
/// nil only appears in previews / detached views.
private struct ChannelSessionRegistryKey: EnvironmentKey {
    static let defaultValue: ChannelSessionRegistry? = nil
}

public extension EnvironmentValues {
    /// App-wide registry of live `ChannelSession`s, keyed by (userId, channelId).
    /// Injected by RootView. Reading nil means there's no registry available
    /// (e.g. previews) — callers should treat it as "can't open chat."
    var channelSessionRegistry: ChannelSessionRegistry? {
        get { self[ChannelSessionRegistryKey.self] }
        set { self[ChannelSessionRegistryKey.self] = newValue }
    }
}
