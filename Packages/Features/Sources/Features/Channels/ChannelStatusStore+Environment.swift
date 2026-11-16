import SwiftUI

// MARK: - Environment plumbing
//
// Optional with a nil default, like `\.followsStore` / `\.chatTabs`: SwiftUI
// evaluates environment key paths against environments that don't carry the
// injection, so a trapping getter is never safe (see the build-7 launch
// crash). Readers treat nil as "no status known".
public extension EnvironmentValues {
    /// Live/offline status for open channels. Injected by `RootView`.
    @Entry var channelStatus: ChannelStatusStore? = nil
}
