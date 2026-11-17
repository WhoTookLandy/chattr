#if canImport(UIKit)
import SwiftUI
import UIKit
import Accounts
import Core
import os

private let logger = AppLogger.make("Features.DeviceCodeSheetSession")

/// Presents `DeviceCodeSignInSheet` through UIKit and turns it into one
/// async result for `TwitchSignIn.run(accountStore:clientId:)`.
///
/// Presented through UIKit rather than a `.sheet` modifier so callers
/// (`SignInView`, `AccountSwitcherView`) keep calling one async function
/// and need no sheet state of their own.
///
/// ## One completion owner
///
/// Everything that can end the wait — the model reporting an outcome
/// (signed in / use browser / dismissed), UIKit refusing to present, the
/// caller's task being cancelled — goes through `complete(_:)`, which
/// records the first outcome, closes the sheet if it's still up, and then
/// resumes the caller exactly once. The outcome is delivered only after
/// the sheet's dismissal finishes, so the browser flow's auth sheet can
/// present right after.
@MainActor
final class DeviceCodeSheetSession {

    /// Presents the sheet over the top-most view controller and waits for
    /// its outcome. `nil` means the sheet couldn't be shown (no window, or
    /// UIKit refused the presentation): the caller falls back to the
    /// browser flow.
    static func present(accountStore: AccountStore, clientId: String) async -> DeviceCodeSignInModel.Outcome? {
        guard !Task.isCancelled else { return .cancelled }
        // Another modal may be mid-presentation or mid-dismissal (e.g. the
        // account switcher closing). UIKit refuses to present during that,
        // so let it settle first.
        guard let presenter = await settledPresenter() else { return nil }
        guard !Task.isCancelled else { return .cancelled }

        let session = DeviceCodeSheetSession()
        let model = DeviceCodeSignInModel(accountStore: accountStore, clientId: clientId) { [weak session] outcome in
            session?.complete(outcome)
        }
        session.model = model

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.begin(continuation, from: presenter)
            }
            return session.outcome
        } onCancel: {
            Task { @MainActor in session.callerCancelled() }
        }
    }

    private var continuation: CheckedContinuation<Void, Never>?
    private var outcome: DeviceCodeSignInModel.Outcome?
    private var isComplete = false
    private var model: DeviceCodeSignInModel?
    private weak var host: UIViewController?

    private init() {}

    private func begin(_ continuation: CheckedContinuation<Void, Never>, from presenter: UIViewController) {
        self.continuation = continuation
        // Finished before we got here (cancelled in between).
        guard !isComplete, let model else {
            resumeCaller()
            return
        }
        let host = UIHostingController(rootView: DeviceCodeSignInSheet(model: model))
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        self.host = host
        presenter.present(host, animated: true)

        // UIKit refuses a presentation — logging a warning and never calling
        // back — when the presenter is busy (already presenting, or a
        // transition started after we looked). Without this check the
        // caller would wait forever.
        if host.presentingViewController == nil, !host.isBeingPresented {
            logger.warning("Couldn't present the device-code sheet; falling back to the browser")
            complete(nil)
        }
    }

    /// The single completion point. Later calls are ignored.
    private func complete(_ outcome: DeviceCodeSignInModel.Outcome?) {
        guard !isComplete else { return }
        isComplete = true
        self.outcome = outcome
        // Tear the model down too (no-op if it reported this outcome).
        model?.cancel()

        guard let host, host.presentingViewController != nil, !host.isBeingDismissed else {
            // Never shown, or already going away (swipe-down / Cancel).
            resumeCaller()
            return
        }
        Task { @MainActor in
            // Dismissing mid-presentation is unreliable; finish that first.
            if let coordinator = host.transitionCoordinator {
                await Self.waitForTransition(coordinator)
            }
            if host.presentingViewController != nil, !host.isBeingDismissed {
                await withCheckedContinuation { (dismissed: CheckedContinuation<Void, Never>) in
                    let once = ResumeOnce(dismissed)
                    host.dismiss(animated: true) { once.resume() }
                }
            }
            self.resumeCaller()
        }
    }

    /// The task awaiting `present` was cancelled. Goes through the model so
    /// polling stops and an approved sign-in that's already being saved
    /// still reports `.signedIn` rather than a cancel that races it.
    private func callerCancelled() {
        guard !isComplete else { return }
        if let model {
            model.cancel()
        } else {
            complete(.cancelled)
        }
    }

    private func resumeCaller() {
        continuation?.resume()
        continuation = nil
    }

    // MARK: - Presenter lookup

    /// The top-most view controller that isn't being dismissed, once no
    /// presentation transition is in flight. Bounded: if transitions keep
    /// coming, give up (`nil`) and let the browser flow handle sign-in.
    private static func settledPresenter() async -> UIViewController? {
        for _ in 0..<4 {
            guard var top = TwitchSignIn.foregroundWindow()?.rootViewController else { return nil }
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            // A dismissing child or `top`'s own presentation still animating.
            guard let inFlight = top.presentedViewController?.transitionCoordinator ?? top.transitionCoordinator else {
                return top
            }
            await waitForTransition(inFlight)
            if Task.isCancelled { return nil }
        }
        return nil
    }

    private static func waitForTransition(_ coordinator: any UIViewControllerTransitionCoordinator) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let queued = coordinator.animate(alongsideTransition: nil) { _ in once.resume() }
            // Not queued (transition already over): the completion may never run.
            if !queued { once.resume() }
        }
    }
}

/// Resumes a continuation at most once, whichever callback gets there
/// first. Lock-backed so it's safe to capture in UIKit callbacks regardless
/// of their isolation annotations.
private final class ResumeOnce: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume() {
        let pending = continuation.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = nil }
            return state
        }
        pending?.resume()
    }
}
#endif
