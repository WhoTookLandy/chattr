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
/// All network work runs in ONE cancellable `Task` (`work`), started by
/// `activate()` and cancelled by `deactivate()`. The sheet calls those on
/// appear / disappear and on app background / foreground, so nothing polls
/// while the sheet isn't visible. There are no timers — the loop's only
/// waits are `Task.sleep` inside `DeviceCodeGrant.waitForApproval`, which
/// cancellation interrupts immediately. Terminal states (`expired`,
/// `denied`, `failed`, `done`) never restart polling on their own; the user
/// has to tap "Get a new code" / "Try again".
///
/// Cancelled runs never write state: `deactivate()` clears `work` itself,
/// and a cancelled run returns early, so a stale run can't clobber a newer
/// one started by a quick background → foreground bounce.
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
        /// Account added; the sheet is closing.
        case done
    }

    /// How the sheet ended, reported once to the presenter.
    enum Outcome {
        case signedIn(Account)
        case useBrowser
        case cancelled
    }

    private(set) var phase: Phase = .requestingCode
    private(set) var prompt: DeviceCodePrompt?

    @ObservationIgnored private let grant: DeviceCodeGrant
    @ObservationIgnored private let accountStore: AccountStore
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var onFinish: ((Outcome) -> Void)?

    init(accountStore: AccountStore, clientId: String, onFinish: @escaping (Outcome) -> Void) {
        self.accountStore = accountStore
        self.grant = TwitchSignIn.deviceCodeGrant(clientId: clientId)
        self.onFinish = onFinish
    }

    // MARK: - Visibility

    /// Sheet visible + app foregrounded. Resumes whatever the current phase
    /// needs (fetch a code, or poll). `pollImmediately` is set when coming
    /// back from the background — the user has most likely just approved in
    /// the Twitch app, so don't make them wait out a full interval.
    func activate(pollImmediately: Bool = false) {
        // Already reported an outcome (sheet gone): never poll again.
        guard onFinish != nil else { return }
        isActive = true
        startWorkIfNeeded(pollImmediately: pollImmediately)
    }

    /// Sheet hidden or app backgrounded: stop polling. A run that's already
    /// adding the account (`signingIn`) is left to finish — the device code
    /// has been consumed, so abandoning it would lose the sign-in.
    func deactivate() {
        isActive = false
        guard phase == .requestingCode || phase == .waiting else { return }
        work?.cancel()
        work = nil
    }

    // MARK: - User actions

    /// "Get a new code" after expiry / denial / a rejected request.
    func requestNewCode() {
        prompt = nil
        phase = .requestingCode
        startWorkIfNeeded(pollImmediately: false)
    }

    /// "Try again" after a network error: keep polling the same code if it's
    /// still valid, otherwise fetch a new one.
    func retry() {
        if let prompt, prompt.expiresAt > .now {
            phase = .waiting
            startWorkIfNeeded(pollImmediately: true)
        } else {
            requestNewCode()
        }
    }

    func useBrowserInstead() {
        work?.cancel()
        work = nil
        finish(.useBrowser)
    }

    /// The sheet went away without finishing (swipe-down / close button).
    func dismissed() {
        deactivate()
        // Approved and mid-add: let `completeSignIn` report the real outcome
        // instead of a cancel that would race the new account appearing.
        guard phase != .signingIn else { return }
        work?.cancel()
        work = nil
        finish(.cancelled)
    }

    // MARK: - Work

    private func startWorkIfNeeded(pollImmediately: Bool) {
        guard isActive, work == nil else { return }
        guard phase == .requestingCode || phase == .waiting else { return }
        work = Task { [weak self] in
            await self?.run(pollImmediately: pollImmediately)
        }
    }

    private func run(pollImmediately: Bool) async {
        let token: OAuthToken
        do {
            let prompt = try await currentOrNewPrompt()
            phase = .waiting
            token = try await grant.waitForApproval(prompt, pollImmediately: pollImmediately)
        } catch {
            // Paused by deactivate() — leave state for the next activate().
            if Task.isCancelled { return }
            handle(error)
            work = nil
            return
        }

        // Approved. From here on the device code is spent, so the account
        // add runs in its own unstructured task (strong `self`, short-lived):
        // cancelling `work` or releasing the sheet must not abandon a
        // sign-in the user already approved.
        phase = .signingIn
        work = nil
        Task { await self.completeSignIn(with: token) }
    }

    private func completeSignIn(with token: OAuthToken) async {
        do {
            let account = try await TwitchSignIn.completeDeviceCodeSignIn(token: token, accountStore: accountStore)
            phase = .done
            finish(.signedIn(account))
        } catch {
            logger.error("Device-code sign-in: adding the account failed: \(error.localizedDescription, privacy: .public)")
            prompt = nil
            phase = .failed(Self.message(for: error))
            // The sheet may already be gone (dismissed mid-add); report so
            // the caller isn't left waiting. No-op if it already finished.
            if !isActive { finish(.cancelled) }
        }
    }

    /// The prompt still on screen if it's valid, else a fresh one.
    private func currentOrNewPrompt() async throws -> DeviceCodePrompt {
        if let prompt, prompt.expiresAt > .now { return prompt }
        if prompt != nil {
            // Ran out while paused (e.g. backgrounded too long).
            throw DeviceCodeGrant.Failure.expired
        }
        phase = .requestingCode
        let fresh = try await grant.start()
        prompt = fresh
        logger.notice("Device code issued (expires in \(Int(fresh.expiresAt.timeIntervalSinceNow)) s)")
        return fresh
    }

    private func handle(_ error: Error) {
        switch error as? DeviceCodeGrant.Failure {
        case .expired?:
            phase = .expired
        case .denied?:
            prompt = nil
            phase = .denied
        case .rejected(let message)?:
            logger.error("Device code rejected by Twitch: \(message, privacy: .public)")
            prompt = nil
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
}
