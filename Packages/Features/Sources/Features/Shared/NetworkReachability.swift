import Foundation
import Network
import os

/// The app's one `NWPathMonitor`, answering "is this an unmetered
/// connection?" for Wi-Fi autoplay.
///
/// Started on first use (`warmUp()`), on its own utility queue; path
/// updates land in a lock-protected flag, so reading it is a lock and a
/// load — no main-actor hop, no `@Observable`, nothing re-renders when the
/// network changes. Callers read it at the moment they decide (a chat
/// opening).
final class NetworkReachability: @unchecked Sendable {
    // @unchecked: `monitor` is configured once in `init` and never mutated
    // afterwards; the only shared mutable state is behind `latest`'s
    // lock.

    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    /// nil until the monitor reports its first path.
    private let latest = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    private init() {
        monitor.pathUpdateHandler = { [latest] path in
            let unmetered = Self.unmetered(path)
            latest.withLock { $0 = unmetered }
        }
        monitor.start(queue: DispatchQueue(label: "com.andrewbeshay.chattr.reachability", qos: .utility))
    }

    /// Starts the monitor ahead of the first read, so the first answer
    /// isn't "unknown".
    static func warmUp() {
        _ = shared
    }

    /// On Wi-Fi (or wired), and not a hotspot or Low Data Mode. Unknown
    /// counts as no — autoplay never guesses on a metered connection.
    var isOnWiFi: Bool {
        if let known = latest.withLock({ $0 }) { return known }
        return Self.unmetered(monitor.currentPath)
    }

    private static func unmetered(_ path: NWPath) -> Bool {
        path.status == .satisfied
            && !path.isExpensive
            && !path.isConstrained
            && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
    }
}
