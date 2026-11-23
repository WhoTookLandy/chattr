import Foundation
import Network
import os

/// The app's one `NWPathMonitor`, answering "is this an unmetered
/// connection?" for Wi-Fi autoplay.
///
/// Started on first use (`warmUp()`), on its own utility queue; path
/// updates land in lock-protected state, so reading it is a lock and a
/// load — no main-actor hop, no `@Observable`, nothing re-renders when the
/// network changes. Callers ask at the moment they decide (a chat opening),
/// and only that one request waits for the first sample if it hasn't
/// arrived yet.
final class NetworkReachability: @unchecked Sendable {
    // @unchecked: `monitor` is configured once in `init` and never mutated
    // afterwards; the only shared mutable state is behind `state`'s lock.

    static let shared = NetworkReachability()

    /// Posted whenever `knownIsOnWiFi` changes (e.g., Wi-Fi ↔ cellular), so
    /// non-view controllers like `HomeFeedPreviewController` can re-check
    /// policy without making this type `@Observable`.
    static let didChangeNotification = Notification.Name("com.andrewbeshay.chattr.reachabilityChanged")

    private struct State: Sendable {
        /// nil until the monitor reports its first path.
        var unmetered: Bool?
        /// Requests waiting for that first path (see `isOnWiFi(waitingUpTo:)`).
        var waiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]
    }

    private let monitor = NWPathMonitor()
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            let unmetered = Self.unmetered(path)
            let (waiting, didChange) = state.withLock { (current: inout State) -> ([CheckedContinuation<Bool?, Never>], Bool) in
                let changed = current.unmetered != unmetered
                current.unmetered = unmetered
                let waiting = Array(current.waiters.values)
                current.waiters.removeAll()
                return (waiting, changed)
            }
            for waiter in waiting { waiter.resume(returning: unmetered) }
            if didChange {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.andrewbeshay.chattr.reachability", qos: .utility))
    }

    /// Starts the monitor ahead of the first read, so the first answer
    /// isn't "unknown".
    static func warmUp() {
        _ = shared
    }

    /// The latest answer, or nil before the monitor's first path sample
    /// (right after launch). On Wi-Fi (or wired), and not a hotspot or Low
    /// Data Mode.
    var knownIsOnWiFi: Bool? {
        state.withLock { $0.unmetered }
    }

    /// `knownIsOnWiFi`, waiting up to `timeout` for the first path sample
    /// when there isn't one yet. Still unknown after that counts as no —
    /// autoplay never guesses on a metered connection.
    func isOnWiFi(waitingUpTo timeout: Duration) async -> Bool {
        let id = UUID()
        let sample: Bool? = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let known: Bool? = state.withLock { (current: inout State) -> Bool? in
                if let unmetered = current.unmetered { return unmetered }
                current.waiters[id] = continuation
                return nil
            }
            if let known {
                continuation.resume(returning: known)
                return
            }
            // Whichever comes first resumes it: the first path (above, which
            // removes the waiter) or this deadline.
            Task { [state] in
                try? await Task.sleep(for: timeout)
                let expired = state.withLock { $0.waiters.removeValue(forKey: id) }
                expired?.resume(returning: nil)
            }
        }
        return sample ?? false
    }

    private static func unmetered(_ path: NWPath) -> Bool {
        path.status == .satisfied
            && !path.isExpensive
            && !path.isConstrained
            && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
    }
}
