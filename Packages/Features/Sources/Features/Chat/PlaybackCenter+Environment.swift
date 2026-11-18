#if os(iOS)
import SwiftUI

private struct PlaybackCenterKey: EnvironmentKey {
    static let defaultValue: PlaybackCenter? = nil
}

extension EnvironmentValues {
    var playback: PlaybackCenter? {
        get { self[PlaybackCenterKey.self] }
        set { self[PlaybackCenterKey.self] = newValue }
    }
}
#endif
