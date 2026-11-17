import Testing
import Foundation
import os
import Accounts
import TwitchKit
@testable import Features

// MARK: - Test doubles

/// A suspension point the test controls: each `wait()` parks until the
/// test resumes it. Deliberately ignores task cancellation, to model a
/// request that completed on the wire before the cancel landed — the exact
/// race the model has to survive.
private final class Gate<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var waiters: [CheckedContinuation<Value, any Error>] = []
        var entered = 0
        var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many times `wait()` has been entered.
    var entered: Int { state.withLock { $0.entered } }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.waiters.append(continuation)
                state.entered += 1
                let entered = state.entered
                let ready = state.entryWaiters.filter { $0.count <= entered }.map(\.continuation)
                state.entryWaiters.removeAll { $0.count <= entered }
                return ready
            }
            ready.forEach { $0.resume() }
        }
    }

    /// Suspends until `wait()` has been entered at least `count` times.
    func entries(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already = state.withLock { state -> Bool in
                if state.entered >= count { return true }
                state.entryWaiters.append((count, continuation))
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Resumes the oldest parked `wait()`.
    func resume(_ result: Result<Value, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            state.waiters.isEmpty ? nil : state.waiters.removeFirst()
        }
        waiter?.resume(with: result)
    }
}

/// Everything the model did to the outside world.
@MainActor
private final class Harness {
    let codeGate = Gate<DeviceCodePrompt>()
    let pollGate = Gate<OAuthToken>()
    /// When false, `requestCode` returns `prompt` immediately.
    var gateCodeRequests = false
    var codeRequests = 0
    let schedules = OSAllocatedUnfairLock<[DeviceCodePollSchedule]>(initialState: [])
    var accountsAdded: [String] = []
    var outcomes: [String] = []
    var model: DeviceCodeSignInModel!

    static let prompt = DeviceCodePrompt(
        deviceCode: "dev-code",
        userCode: "ABCDEFGH",
        verificationURL: URL(string: "https://www.twitch.tv/activate")!,
        interval: 5,
        expiresAt: .distantFuture
    )
    static let token = OAuthToken(
        accessToken: "dcf-access",
        refreshToken: "dcf-refresh",
        expiresIn: 14400,
        scope: ["chat:read"],
        tokenType: "bearer"
    )

    init(gateCodeRequests: Bool = false) {
        self.gateCodeRequests = gateCodeRequests
        let codeGate = codeGate
        let pollGate = pollGate
        let schedules = schedules
        let gated = gateCodeRequests
        let prompt = Self.prompt
        model = DeviceCodeSignInModel(
            dependencies: .init(
                requestCode: { [unowned self] in
                    await MainActor.run { self.codeRequests += 1 }
                    return gated ? try await codeGate.wait() : prompt
                },
                waitForApproval: { _, schedule in
                    schedules.withLock { $0.append(schedule) }
                    return try await pollGate.wait()
                },
                addAccount: { [unowned self] _ in
                    self.accountsAdded.append("u1")
                    return Account(userId: "u1", login: "user", displayName: "User", profileImageURL: "", tokenNamespace: "ns-u1")
                }
            ),
            onFinish: { [unowned self] outcome in
                switch outcome {
                case .signedIn(let account): self.outcomes.append("signedIn:\(account.userId)")
                case .useBrowser: self.outcomes.append("useBrowser")
                case .cancelled: self.outcomes.append("cancelled")
                }
            }
        )
    }

    /// Waits until the most recent run (and the run it replaced) is done.
    func settle() async {
        await model.currentWorkForTesting?.value
    }
}

// MARK: - Tests

@MainActor
@Suite("DeviceCodeSignInModel (run ownership + races)")
struct DeviceCodeSignInModelTests {

    @Test("An approval that lands after dismissal is discarded, not persisted")
    func delayedSuccessAfterDismissal() async {
        let harness = Harness()
        harness.model.activate()
        await harness.pollGate.entries(1)

        harness.model.dismissed()
        // The poll's response was already on the wire: it still succeeds.
        harness.pollGate.resume(.success(Harness.token))
        await harness.settle()

        #expect(harness.accountsAdded.isEmpty)
        #expect(harness.outcomes == ["cancelled"])
        #expect(harness.model.phase != .signingIn)
    }

    @Test("An approval that lands after \"Use browser instead\" is discarded, so only the browser flow signs in")
    func delayedSuccessAfterBrowserFallback() async {
        let harness = Harness()
        harness.model.activate()
        await harness.pollGate.entries(1)

        harness.model.useBrowserInstead()
        harness.pollGate.resume(.success(Harness.token))
        await harness.settle()

        #expect(harness.accountsAdded.isEmpty)
        #expect(harness.outcomes == ["useBrowser"])
    }

    @Test("Caller cancellation drops a late approval the same way")
    func delayedSuccessAfterCallerCancel() async {
        let harness = Harness()
        harness.model.activate()
        await harness.pollGate.entries(1)

        harness.model.cancel()
        harness.pollGate.resume(.success(Harness.token))
        await harness.settle()

        #expect(harness.accountsAdded.isEmpty)
        #expect(harness.outcomes == ["cancelled"])
    }

    @Test("Foreground re-entry waits for the paused run instead of polling alongside it")
    func reentryIsSerialized() async {
        let harness = Harness()
        harness.model.activate()
        await harness.pollGate.entries(1)

        // Background → foreground while the first poll is in flight.
        harness.model.deactivate()
        harness.model.activate()
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.pollGate.entered == 1, "replacement must not poll before the old run finishes")

        // The paused run's request comes back cancelled; only now does the
        // replacement poll — same device code, same schedule.
        harness.pollGate.resume(.failure(CancellationError()))
        await harness.pollGate.entries(2)

        #expect(harness.codeRequests == 1)
        let schedules = harness.schedules.withLock { $0 }
        #expect(schedules.count == 2)
        #expect(schedules.first === schedules.last)
        #expect(harness.model.phase == .waiting)

        harness.model.dismissed()
        harness.pollGate.resume(.failure(CancellationError()))
        await harness.settle()
    }

    @Test("An approval that lands while paused still signs in exactly once")
    func approvalWhilePausedSignsInOnce() async {
        let harness = Harness()
        harness.model.activate()
        await harness.pollGate.entries(1)

        harness.model.deactivate()
        harness.model.activate()
        // The paused run's response was approval: the device code is spent,
        // so it claims the sign-in and the replacement never polls.
        harness.pollGate.resume(.success(Harness.token))
        await harness.settle()

        #expect(harness.accountsAdded == ["u1"])
        #expect(harness.outcomes == ["signedIn:u1"])
        #expect(harness.pollGate.entered == 1)
        #expect(harness.model.phase == .done)
    }

    @Test("A device code that arrives after cancellation isn't written")
    func staleCodeRequestWritesNothing() async {
        let harness = Harness(gateCodeRequests: true)
        harness.model.activate()
        await harness.codeGate.entries(1)

        harness.model.deactivate()
        harness.codeGate.resume(.success(Harness.prompt))
        await harness.settle()

        #expect(harness.model.prompt == nil)
        #expect(harness.pollGate.entered == 0)
    }

    @Test("A client-authentication failure offers the browser instead of retrying")
    func clientAuthenticationFailureOffersBrowser() async {
        let harness = Harness()
        harness.model.activate()
        await harness.pollGate.entries(1)

        harness.pollGate.resume(.failure(DeviceCodeGrant.Failure.clientAuthenticationFailed("invalid_client")))
        await harness.settle()

        guard case .browserRequired = harness.model.phase else {
            Issue.record("expected .browserRequired, got \(harness.model.phase)")
            return
        }
        harness.model.useBrowserInstead()
        #expect(harness.outcomes == ["useBrowser"])
        #expect(harness.accountsAdded.isEmpty)
    }
}
