import Foundation
import Observation
import Channels
import Core
import os

private let logger = AppLogger.make("Features.UserModerationModel")

/// The user card's moderation state for ONE target user: whether they're
/// banned / timed out right now, an action in flight, and the last outcome.
///
/// Lives exactly as long as the card (`@State` in `UserCardModerationBar`),
/// so nothing here outlives the sheet or touches the transcript.
@MainActor
@Observable
final class UserModerationModel {

    let targetUserId: String
    let targetDisplayName: String

    /// nil = unknown (not fetched yet, or Twitch wouldn't say).
    private(set) var banState: UserBanState?
    /// True while a Helix call is in flight; the chips disable meanwhile.
    private(set) var isWorking = false
    /// What just happened ("Timed out for 10 minutes") or why it didn't.
    private(set) var feedback: Feedback?

    struct Feedback: Equatable {
        let message: String
        let isError: Bool
    }

    private let chatModel: ChatTranscriptModel
    @ObservationIgnored private var feedbackClear: Task<Void, Never>?

    init(targetUserId: String, targetDisplayName: String, chatModel: ChatTranscriptModel) {
        self.targetUserId = targetUserId
        self.targetDisplayName = targetDisplayName
        self.chatModel = chatModel
    }

    /// Whether the target currently can't chat, when known.
    var isRestricted: Bool {
        banState?.isRestricted() ?? false
    }

    /// One GET per card open. Failure leaves `banState` nil (unknown).
    func loadBanState() async {
        let state = await chatModel.banState(of: targetUserId)
        guard !Task.isCancelled else { return }
        banState = state
    }

    func timeout(seconds: Int) async {
        let spoken = TimeoutPresets.spokenLabel(forSeconds: seconds)
        if await perform(.timeout(seconds: seconds), success: "Timed out \(targetDisplayName) for \(spoken).") {
            banState = .timedOut(until: Date.now.addingTimeInterval(TimeInterval(seconds)))
        }
    }

    func ban(reason: String) async {
        if await perform(.ban(reason: reason), success: "Banned \(targetDisplayName).") {
            banState = .banned
        }
    }

    func unban() async {
        let wasTimeout: Bool
        if case .timedOut? = banState { wasTimeout = true } else { wasTimeout = false }
        let success = wasTimeout ? "Removed \(targetDisplayName)'s timeout." : "Unbanned \(targetDisplayName)."
        if await perform(.unban, success: success) {
            banState = .notBanned
        }
    }

    func warn(reason: String) async {
        await perform(.warn(reason: reason), success: "Warned \(targetDisplayName).")
    }

    private enum Action {
        case timeout(seconds: Int)
        case ban(reason: String)
        case unban
        case warn(reason: String)
    }

    /// Runs one action with the shared busy flag and outcome reporting;
    /// returns whether it succeeded. Re-entrancy is refused rather than
    /// queued: a double-tap on a chip must not fire two timeouts.
    @discardableResult
    private func perform(_ action: Action, success: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            switch action {
            case .timeout(let seconds):
                try await chatModel.timeoutUser(userId: targetUserId, seconds: seconds)
            case .ban(let reason):
                try await chatModel.banUser(userId: targetUserId, reason: reason)
            case .unban:
                try await chatModel.unbanUser(userId: targetUserId)
            case .warn(let reason):
                try await chatModel.warnUser(userId: targetUserId, reason: reason)
            }
            show(Feedback(message: success, isError: false))
            return true
        } catch is CancellationError {
            feedback = nil
            return false
        } catch {
            logger.error("Moderation action on \(self.targetUserId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            show(Feedback(message: error.localizedDescription, isError: true))
            return false
        }
    }

    /// Successes fade after a few seconds; errors stay until the next action.
    private func show(_ next: Feedback) {
        feedbackClear?.cancel()
        feedback = next
        guard !next.isError else { return }
        feedbackClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.feedback == next else { return }
            self.feedback = nil
        }
    }
}
