#if os(iOS)
import AVFoundation
import Core
import os

private let logger = AppLogger.make("Features.PlaybackAudioSession")

/// Snapshot of one audio client's current needs, sent across actors to
/// `PlaybackAudioSession` for aggregate category arbitration.
struct AudioSessionClientState: Equatable, Sendable {
    /// Any native `AVPlayer` is loaded or loading (paused/held slots still
    /// count while their `AVPlayer` exists; unloaded slots do not).
    var hasActiveNative: Bool = false
    /// At least one native `AVPlayer` is currently audible (not muted,
    /// volume > 0, not paused, not held).
    var hasAudibleNative: Bool = false
    /// Primary `WKWebView` video is actively playing with sound (foreground
    /// or continuing in background system PiP).
    var hasAudibleWeb: Bool = false

    static let inactive = AudioSessionClientState()
}

/// Identifies each subsystem that participates in `PlaybackAudioSession`
/// arbitration so neither can tear down the session out from under the other.
enum AudioSessionClientID: Hashable, Sendable {
    case playback
    case homePreview
}

/// Desired `AVAudioSession` action derived from all active clients.
enum AudioSessionAction: Equatable, Sendable {
    case deactivate
    case activate(mixable: Bool)
}

/// Synchronous abstraction over `AVAudioSession` I/O, invoked strictly in FIFO
/// order on `PlaybackAudioSession`'s single serial queue so state updates can
/// never overtake each other.
protocol PlaybackAudioSessionDriver: Sendable {
    func apply(_ action: AudioSessionAction, force: Bool)
    func invalidate()
}

/// The app's audio session arbiter.
///
/// Both snapshot updates and `AVAudioSession` I/O execute sequentially on one
/// serial queue (off the main actor), preserving exact FIFO ordering.
///
/// `HighlightSoundPlayer` intentionally stays outside this arbiter;
/// `SystemDriver` always compares against the live `AVAudioSession.sharedInstance()`
/// category so external `.ambient` changes are re-asserted cleanly.
final class PlaybackAudioSession: @unchecked Sendable {
    // @unchecked: `clients` and all `driver` calls are serialized on `queue`.

    static let shared = PlaybackAudioSession()

    private let driver: any PlaybackAudioSessionDriver
    private let queue = DispatchQueue(label: "com.andrewbeshay.chattr.playback-audio", qos: .userInitiated)
    private var clients: [AudioSessionClientID: AudioSessionClientState] = [:]

    init(driver: any PlaybackAudioSessionDriver = SystemDriver()) {
        self.driver = driver
    }

    /// Pure decision function over the union of all registered clients.
    ///
    /// Decision table:
    /// 1. No active native players → `.deactivate`
    /// 2. Active native players, none audible → `.activate(mixable: true)`
    /// 3. Audible native player(s), no audible web primary → `.activate(mixable: false)` (exclusive; owns Lock Screen Now Playing)
    /// 4. Audible native player(s) + audible web primary → `.activate(mixable: true)` (coexists with WebKit media process)
    static func resolveAction(for clients: [AudioSessionClientID: AudioSessionClientState]) -> AudioSessionAction {
        let hasActiveNative = clients.values.contains { $0.hasActiveNative }
        guard hasActiveNative else { return .deactivate }
        let hasAudibleNative = clients.values.contains { $0.hasAudibleNative }
        guard hasAudibleNative else { return .activate(mixable: true) }
        let hasAudibleWeb = clients.values.contains { $0.hasAudibleWeb }
        return .activate(mixable: hasAudibleWeb)
    }

    /// Updates `client`'s state and applies the resulting `AVAudioSession`
    /// action synchronously on the serial queue, returning once applied.
    func updateClient(
        _ client: AudioSessionClientID,
        state: AudioSessionClientState,
        force: Bool = false
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.applyLocked(client: client, state: state, force: force)
                continuation.resume()
            }
        }
    }

    /// Enqueues a client state update and driver application on the same
    /// serial queue in strict FIFO order without blocking the caller.
    func updateClientAsync(
        _ client: AudioSessionClientID,
        state: AudioSessionClientState,
        force: Bool = false
    ) {
        queue.async {
            self.applyLocked(client: client, state: state, force: force)
        }
    }

    /// Media services were reset: invalidate on the serial queue so subsequent
    /// activations force a fresh category/active configuration.
    func invalidate() {
        queue.async {
            self.driver.invalidate()
        }
    }

    private func applyLocked(client: AudioSessionClientID, state: AudioSessionClientState, force: Bool) {
        if state == .inactive {
            clients[client] = nil
        } else {
            clients[client] = state
        }
        let resolved = Self.resolveAction(for: clients)
        driver.apply(resolved, force: force)
    }

    // MARK: - Legacy single-stream shims

    func activate(muted: Bool, force: Bool = false) async {
        await updateClient(
            .playback,
            state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: !muted, hasAudibleWeb: false),
            force: force
        )
    }

    func setMuted(_ muted: Bool) {
        updateClientAsync(
            .playback,
            state: AudioSessionClientState(hasActiveNative: true, hasAudibleNative: !muted, hasAudibleWeb: false)
        )
    }

    func deactivate() {
        updateClientAsync(.playback, state: .inactive)
    }

    // MARK: - System AVAudioSession driver

    final class SystemDriver: PlaybackAudioSessionDriver, @unchecked Sendable {
        // @unchecked: always called exclusively on `PlaybackAudioSession.queue`.
        private var isActive = false

        func apply(_ action: AudioSessionAction, force: Bool) {
            switch action {
            case .deactivate:
                performDeactivate()
            case .activate(let mixable):
                performConfigure(mixable: mixable, forceActivate: force)
            }
        }

        func invalidate() {
            isActive = false
        }

        private func performDeactivate() {
            guard isActive else { return }
            isActive = false
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.warning("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func performConfigure(mixable: Bool, forceActivate: Bool) {
            let session = AVAudioSession.sharedInstance()
            let options: AVAudioSession.CategoryOptions = mixable ? [.mixWithOthers] : []
            do {
                let needsCategory = session.category != .playback
                    || session.mode != .moviePlayback
                    || session.categoryOptions != options
                if needsCategory {
                    try session.setCategory(.playback, mode: .moviePlayback, options: options)
                }
                if forceActivate || !isActive || needsCategory {
                    try session.setActive(true)
                    isActive = true
                }
            } catch {
                logger.warning("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
