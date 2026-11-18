/// Mutable holder for the attach epoch a `ChatScreen` session-lifecycle task
/// owns — see `ChatSessionCoordinator.attachLease`. A reference type so the
/// Retry button and the compose-bar self-heal can record into the lease of
/// the task run that is live when they fire.
@MainActor
final class AttachLease {
    /// The NEWEST epoch any start under this lease established. Epochs only
    /// grow, so keeping the max means a superseded start that finishes late
    /// can't overwrite a newer one with its stale epoch (whose
    /// `detach(ifEpoch:)` would then no-op).
    private(set) var epoch = 0
    /// Set by the lifecycle task's teardown; after that, starts detach what
    /// they establish instead of recording it.
    private(set) var isClosed = false
    /// Out-of-band starts (Retry) in flight, cancelled on close.
    private var pending: [Task<Void, Never>] = []

    func record(_ newEpoch: Int) {
        epoch = max(epoch, newEpoch)
    }

    func track(_ task: Task<Void, Never>) {
        pending.append(task)
    }

    func close() {
        isClosed = true
        for task in pending { task.cancel() }
        pending.removeAll()
    }
}
