import Foundation
import Observation
import Accounts
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Features.DeviceCodeSignInModel")

/// Drives `DeviceCodeSignInSheet`: requests a device code, polls Twitch
/// while the sheet is on screen, and hands the resulting token to
/// `AccountStore` via `TwitchSignIn.completeDeviceCodeSignIn`.
///
/// ## Polling lifetime
///
/// All network work runs in one cancellable `Task` per *run*, started by
/// `activate()` and stopped by `deactivate()`. The sheet calls those on
/// appear / disappear and on app background / foreground, so nothing polls
/// while the sheet isn't visible. There are no timers: the loop's only
/// waits are `Task.sleep` inside `DeviceCodeGrant.waitForApproval`, which
/// cancellation interrupts at once. Pacing lives in a
/// `DeviceCodePollSchedule` kept per device code, so pausing and resuming
/// never polls faster than Twitch allows or forgets a `slow_down`.
/// Terminal phases (`expired`, `denied`, `failed`, `browserRequired`,
/// `done`) never restart polling on their own.
///
/// ## Run ownership
///
/// Every run gets a generation id. Pausing, finishing or starting another
/// run bumps `generation`, and a run re-checks its id after every `await`:
/// a stale run writes no state (no prompt, no phase). A replacement run
/// first awaits the run it replaces, so two runs never poll at once.
///
/// Persisting an account goes through `claimCompletion()`, the single
/// owner of "this sheet signed someone in". It only succeeds while the
/// sheet hasn't reported an outcome, so a poll that comes back approved
/// *after* the user dismissed the sheet, chose "Use browser instead" or the
/// caller cancelled is dropped instead of racing the browser flow. A run
/// that was merely *paused* (backgrounded) while its approved response was
/// in flight may still claim: the device code is spent, that token is the
/// only way to finish, and nothing else owns the sign-in yet.
@MainActor
@Observable
final class DeviceCodeSignInModel {

    enum Phase: Equatable {
        /// Asking Twitch for a code.
        case requestingCode
        /// Code on screen; polling for approval.
        case waiting
        /// User approved; adding the account.
        case signingIn
        /// Code ran out. Needs "Get a new code".
        case expired
        /// User declined on Twitch.
        case denied
        /// Network / server error. `Try again` resumes.
        case failed(String)
        /// Twitch won't run the device flow for this client (e.g. it wants
        /// client authentication). Only the browser flow can sign in.
        case browserRequired(String)
        /// Account added; the sheet is closing.
        case done
    }

    /// How the sheet ended, reported once to the presenter.
    enum Outcome {
        case signedIn(Account)
        case useBrowser
        case cancelled
    }

    /// The model's side effects, injectable so the run-ownership rules are
    /// testable without a network or an `AccountStore`.
    struct Dependencies {
        var requestCode: @Sendable () async throws -> DeviceCodePrompt
        var waitForApproval: @Sendable (DeviceCodePrompt, DeviceCodePollSchedule) async throws -> OAuthToken
        var addAccount: @MainActor (OAuthToken) async throws -> Account
        var now: @Sendable () -> Date = { Date() }
    }

    private(set) var phase: Phase = .requestingCode
    private(set) var prompt: DeviceCodePrompt?

    @ObservationIgnored private let dependencies: Dependencies
    /// Pacing for `prompt`'s device code; replaced together with `prompt`.
    @ObservationIgnored private var schedule: DeviceCodePollSchedule?
    /// The most recent run's task, kept even after it's cancelled so the
    /// next run can wait for it to wind down.
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Bumped whenever runs are invalidated; a run only writes state while
    /// its id is current.
    @ObservationIgnored private var generation = 0
    /// Generation of the run that is live right now, if any.
    @ObservationIgnored private var liveRun: Int?
    @ObservationIgnored private var isActive = false
    /// Set once a run has claimed the sign-in and is persisting it.
    @ObservationIgnored private var completionClaimed = false
    /// The sheet was dismissed / the caller cancelled while an account add
    /// was in flight: if that add fails, report `.cancelled`.
    @ObservationIgnored private var dismissRequested = false
    @ObservationIgnored private var onFinish: ((Outcome) -> Void)?

    init(dependencies: Dependencies, onFinish: @escaping (Outcome) -> Void) {
        self.dependencies = dependencies
        self.onFinish = onFinish
    }

    convenience init(accountStore: AccountStore, clientId: String, onFinish: @escaping (Outcome) -> Void) {
        let grant = TwitchSignIn.deviceCodeGrant(clientId: clientId)
        self.init(
            dependencies: Dependencies(
                requestCode: { try await grant.start() },
                waitForApproval: { prompt, schedule in
                    try await grant.waitForApproval(prompt, schedule: schedule)
                },
                addAccount: { token in
                    try await TwitchSignIn.completeDeviceCodeSignIn(token: token, accountStore: accountStore)
                }
            ),
            onFinish: onFinish
        )
    }

    private var isFinished: Bool { onFinish == nil }

    // MARK: - Visibility

    /// Sheet visible + app foregrounded. Resumes whatever the current phase
    /// needs (fetch a code, or poll). Polling resumes on the device code's
    /// own schedule: straight away if the interval already passed while
    /// paused, otherwise after the remainder.
    func activate() {
        guard !isFinished else { return }
        isActive = true
        startRunIfNeeded()
    }

    /// Sheet hidden or app backgrounded: stop polling. An account add that
    /// already claimed the sign-in is left to finish — the device code has
    /// been consumed, so abandoning it would lose the sign-in.
    func deactivate() {
        isActive = false
        guard !completionClaimed else { return }
        invalidateRuns()
    }

    // MARK: - User actions

    /// "Get a new code" after expiry / denial / a rejected request.
    func requestNewCode() {
        guard !isFinished, !completionClaimed else { return }
        invalidateRuns()
        prompt = nil
        schedule = nil
        phase = .requestingCode
        startRunIfNeeded()
    }

    /// "Try again" after a network error: keep polling the same code (at
    /// its existing pace) if it's still valid, otherwise fetch a new one.
    func retry() {
        guard !isFinished, !completionClaimed else { return }
        if let prompt, schedule != nil, prompt.expiresAt > dependencies.now() {
            phase = .waiting
            startRunIfNeeded()
        } else {
            requestNewCode()
        }
    }

    func useBrowserInstead() {
        guard !completionClaimed else { return }
        invalidateRuns()
        finish(.useBrowser)
    }

    /// The sheet went away without finishing (swipe-down / Cancel button).
    func dismissed() {
        isActive = false
        dismissRequested = true
        // Approved and mid-add: let the add report the real outcome
        // instead of a cancel that would race the new account appearing.
        guard !completionClaimed else { return }
        invalidateRuns()
        finish(.cancelled)
    }

    /// The task waiting on this sheet was cancelled. Same as a dismissal:
    /// stop now unless an approved sign-in is already being persisted.
    func cancel() {
        dismissed()
    }

    // MARK: - Runs

    /// Cancels the live run (if any) and makes every in-flight run stale.
    /// `work` is kept so the next run can wait for this one to finish.
    private func invalidateRuns() {
        generation += 1
        liveRun = nil
        work?.cancel()
    }

    private func isCurrent(_ run: Int) -> Bool {
        run == generation && !isFinished && !Task.isCancelled
    }

    private func startRunIfNeeded() {
        guard isActive, !isFinished, !completionClaimed, liveRun == nil else { return }
        guard phase == .requestingCode || phase == .waiting else { return }
        generation += 1
        let run = generation
        liveRun = run
        let previous = work
        previous?.cancel()
        work = Task { [weak self] in
            // Serialize: never overlap the run being replaced (its request
            // may still be in flight even though it was cancelled).
            await previous?.value
            await self?.run(run)
        }
    }

    private func run(_ run: Int) async {
        defer { if liveRun == run { liveRun = nil } }
        guard isCurrent(run) else { return }

        let current: (prompt: DeviceCodePrompt, schedule: DeviceCodePollSchedule)
        do {
            if let prompt, let schedule {
                // Ran out while paused (e.g. backgrounded too long).
                guard prompt.expiresAt > dependencies.now() else { throw DeviceCodeGrant.Failure.expired }
                current = (prompt, schedule)
            } else {
                phase = .requestingCode
                let fresh = try await dependencies.requestCode()
                // Stale: drop it. The run that replaced this one asks for
                // its own code rather than inheriting one mid-flight.
                guard isCurrent(run) else { return }
                let issuedAt = dependencies.now()
                let freshSchedule = DeviceCodePollSchedule(prompt: fresh, issuedAt: issuedAt)
                prompt = fresh
                schedule = freshSchedule
                current = (fresh, freshSchedule)
                let lifetime = Int(fresh.expiresAt.timeIntervalSince(issuedAt))
                logger.notice("Device code issued (expires in \(lifetime) s)")
            }
        } catch {
            guard isCurrent(run) else { return }
            handle(error)
            return
        }

        phase = .waiting
        let token: OAuthToken
        do {
            token = try await dependencies.waitForApproval(current.prompt, current.schedule)
        } catch {
            guard isCurrent(run) else { return }
            handle(error)
            return
        }

        // Approved. Only one party may turn this into a signed-in account.
        guard claimCompletion() else {
            logger.notice("Device code approved after the sheet finished; discarding the token")
            return
        }
        await completeSignIn(with: token)
    }

    /// Atomically (on the main actor) takes ownership of finishing the
    /// sign-in. Fails once an outcome was reported — dismissed, "Use
    /// browser instead", caller cancelled — or another run already claimed.
    /// On success every other run becomes stale and dismissal / browser
    /// fallback defer to this add.
    private func claimCompletion() -> Bool {
        guard !isFinished, !completionClaimed else { return false }
        completionClaimed = true
        generation += 1
        liveRun = nil
        phase = .signingIn
        return true
    }

    private func completeSignIn(with token: OAuthToken) async {
        do {
            let account = try await dependencies.addAccount(token)
            phase = .done
            finish(.signedIn(account))
        } catch {
            logger.error("Device-code sign-in: adding the account failed: \(error.localizedDescription, privacy: .public)")
            completionClaimed = false
            prompt = nil
            schedule = nil
            phase = .failed(Self.message(for: error))
            // The sheet went away mid-add; report so the caller isn't left
            // waiting. No-op if it already finished.
            if dismissRequested { finish(.cancelled) }
        }
    }

    private func handle(_ error: Error) {
        switch error as? DeviceCodeGrant.Failure {
        case .expired?:
            phase = .expired
        case .denied?:
            prompt = nil
            schedule = nil
            phase = .denied
        case .clientAuthenticationFailed(let message)?:
            logger.error("Twitch rejected the device flow for this client: \(message, privacy: .public)")
            prompt = nil
            schedule = nil
            phase = .browserRequired("Twitch couldn't sign you in with a code. Continue in the browser instead.")
        case .rejected(let message)?:
            logger.error("Device code rejected by Twitch: \(message, privacy: .public)")
            prompt = nil
            schedule = nil
            phase = .failed(message)
        case nil:
            logger.error("Device code polling failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if error is URLError { return "Couldn't reach Twitch. Check your connection." }
        return (error as? AppError)?.message ?? error.localizedDescription
    }

    private func finish(_ outcome: Outcome) {
        guard let onFinish else { return }
        self.onFinish = nil
        onFinish(outcome)
    }

    // MARK: - Testing

    /// The most recent run's task, so tests can wait for a run (including
    /// a stale one) to wind down deterministically.
    var currentWorkForTesting: Task<Void, Never>? { work }
}
