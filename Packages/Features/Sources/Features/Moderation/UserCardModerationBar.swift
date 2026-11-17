import SwiftUI
import Channels

/// The user card's moderation tools, in ONE compact row so the card's
/// primary content (the user's recent messages) stays right below:
///
///   [Unban]  [1m] [10m] [1h] [1d]  ⋯ [shield menu: Ban… · Warn… · Unban · Edit timeouts…]
///
/// - Timeout chips fire immediately (a timeout is reversible and the most
///   common action, so it gets no confirmation); the list is editable and
///   persisted per device (`TimeoutPresets`).
/// - Ban asks for confirmation with an optional reason; Warn asks for its
///   required reason. Both live behind the shield menu.
/// - Unban sits at the front of the row only when the user is KNOWN to be
///   banned / timed out (GET /moderation/banned on open); when that's
///   unknown it stays in the menu instead.
///
/// Only shown when the viewer moderates the channel and the target is
/// neither themselves nor the broadcaster (decided by the caller).
struct UserCardModerationBar: View {
    @State private var model: UserModerationModel
    @AppStorage(TimeoutPresets.storageKey) private var presetsRaw = TimeoutPresets.defaultRaw

    @State private var confirmingBan = false
    @State private var banReason = ""
    @State private var composingWarning = false
    @State private var warnReason = ""
    @State private var editingPresets = false

    /// Height the row adds to the card's resting detent.
    static let height: CGFloat = 44

    init(targetUserId: String, targetDisplayName: String, chatModel: ChatTranscriptModel) {
        _model = State(initialValue: UserModerationModel(
            targetUserId: targetUserId,
            targetDisplayName: targetDisplayName,
            chatModel: chatModel
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        if model.isRestricted {
                            unbanChip
                        }
                        ForEach(TimeoutPresets.decode(presetsRaw), id: \.self) { seconds in
                            timeoutChip(seconds)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                moreMenu
            }
            .disabled(model.isWorking)

            if let feedback = model.feedback {
                Label(feedback.message, systemImage: feedback.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(feedback.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.feedback)
        .animation(.snappy(duration: 0.2), value: model.isRestricted)
        .task(id: model.targetUserId) { await model.loadBanState() }
        .alert("Ban \(model.targetDisplayName)?", isPresented: $confirmingBan) {
            TextField("Reason (optional)", text: $banReason)
            Button("Ban", role: .destructive) {
                let reason = banReason
                banReason = ""
                Task { await model.ban(reason: reason) }
            }
            Button("Cancel", role: .cancel) { banReason = "" }
        } message: {
            Text("They won't be able to chat in this channel until they're unbanned.")
        }
        .alert("Warn \(model.targetDisplayName)", isPresented: $composingWarning) {
            TextField("Reason", text: $warnReason)
            Button("Warn") {
                let reason = warnReason
                warnReason = ""
                Task { await model.warn(reason: reason) }
            }
            .disabled(warnReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { warnReason = "" }
        } message: {
            Text("They'll see your reason and must acknowledge it before they can chat again.")
        }
        .sheet(isPresented: $editingPresets) {
            TimeoutPresetsSheet()
        }
    }

    // MARK: - Chips

    private func timeoutChip(_ seconds: Int) -> some View {
        Button {
            Task { await model.timeout(seconds: seconds) }
        } label: {
            chipLabel(TimeoutPresets.label(forSeconds: seconds), systemImage: "clock")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Time out for \(TimeoutPresets.spokenLabel(forSeconds: seconds))")
    }

    private var unbanChip: some View {
        Button {
            Task { await model.unban() }
        } label: {
            chipLabel(unbanTitle, systemImage: "lock.open", tint: .green)
        }
        .buttonStyle(.plain)
    }

    private var unbanTitle: String {
        if case .timedOut? = model.banState { return "Untimeout" }
        return "Unban"
    }

    private func chipLabel(_ title: String, systemImage: String, tint: Color? = nil) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
    }

    // MARK: - Menu

    private var moreMenu: some View {
        Menu {
            Button(role: .destructive) {
                confirmingBan = true
            } label: {
                Label("Ban…", systemImage: "nosign")
            }
            Button {
                composingWarning = true
            } label: {
                Label("Warn…", systemImage: "exclamationmark.triangle")
            }
            // Ban state unknown (older token, fetch failed): still offer it.
            if model.banState == nil {
                Button {
                    Task { await model.unban() }
                } label: {
                    Label("Unban", systemImage: "lock.open")
                }
            }
            Divider()
            Button {
                editingPresets = true
            } label: {
                Label("Edit Timeouts…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "shield.lefthalf.filled")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(Circle())
        }
        .accessibilityLabel("More moderation actions for \(model.targetDisplayName)")
    }
}
