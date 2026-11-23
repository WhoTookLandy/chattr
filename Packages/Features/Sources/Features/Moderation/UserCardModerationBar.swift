import SwiftUI
import Channels

/// The user card's moderation drawer, using Apple's inset-grouped hierarchy
/// and semantic color tints:
///
/// - When the user is known to be timed out or banned, a tinted status banner
///   surfaces right above the controls with a live countdown (for timeouts)
///   and a one-tap green **Lift** / **Unban** pill.
/// - Inside the grouped **Moderation** card:
///   - Row 1: instant-tap timeout pills (`TimeoutPresets`, editable via
///     `Edit` in the header).
///   - Row 2: semantically tinted high-impact controls (**Warn…** in amber,
///     **Ban…** in red — both confirm via alert — plus **Unban** in green when
///     ban state is unknown, as it always is for ordinary moderators).
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

    @Environment(\.colorScheme) private var colorScheme

    /// Height the drawer adds to the card's resting detent so all controls
    /// remain reachable without dragging up.
    static let height: CGFloat = 122

    init(targetUserId: String, targetDisplayName: String, chatModel: ChatTranscriptModel) {
        _model = State(initialValue: UserModerationModel(
            targetUserId: targetUserId,
            targetDisplayName: targetDisplayName,
            chatModel: chatModel
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRestricted {
                restrictionBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            moderationCard
                .disabled(model.isWorking)

            if let feedback = model.feedback {
                Label(
                    feedback.message,
                    systemImage: feedback.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                )
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

    // MARK: - Active Restriction Banner

    @ViewBuilder
    private var restrictionBanner: some View {
        let isTimedOut: Bool = {
            if case .timedOut? = model.banState { return true }
            return false
        }()
        let tint: Color = isTimedOut ? .orange : .red

        HStack(spacing: 8) {
            Image(systemName: isTimedOut ? "clock.badge.exclamationmark" : "nosign")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)

            restrictionLabel
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            Button {
                Task { await model.unban() }
            } label: {
                Text(isTimedOut ? "Lift" : "Unban")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(colorScheme == .dark ? 0.22 : 0.14), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.38), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(model.isWorking)
            .accessibilityLabel(isTimedOut ? "Lift timeout for \(model.targetDisplayName)" : "Unban \(model.targetDisplayName)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.30 : 0.22), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var restrictionLabel: some View {
        switch model.banState {
        case .timedOut(let until)?:
            let now = Date.now
            if until > now {
                Text("Timed out · \(Text(timerInterval: now...until, countsDown: true).monospacedDigit().bold()) left")
            } else {
                Text("Timed out")
            }
        case .banned?:
            Text("Banned in this channel")
        default:
            EmptyView()
        }
    }

    // MARK: - Grouped Moderation Card

    private var moderationCard: some View {
        let presets = TimeoutPresets.decode(presetsRaw)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Moderation", systemImage: "shield.lefthalf.filled")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") {
                    editingPresets = true
                }
                .font(.caption.weight(.semibold))
                .accessibilityLabel("Edit timeout presets")
            }

            if presets.count <= 4 {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { seconds in
                        timeoutPill(seconds, fillsWidth: true)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { seconds in
                            timeoutPill(seconds, fillsWidth: false)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }

            HStack(spacing: 8) {
                impactButton(
                    "Warn…",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                ) {
                    composingWarning = true
                }
                impactButton(
                    "Ban…",
                    systemImage: "nosign",
                    tint: .red
                ) {
                    confirmingBan = true
                }
                // Ban state unknown (ordinary mod, older token, or fetch failed):
                // still keep Unban one tap away.
                if model.banState == nil {
                    impactButton(
                        "Unban",
                        systemImage: "lock.open",
                        tint: .green
                    ) {
                        Task { await model.unban() }
                    }
                }
            }
        }
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 0.5)
        )
    }

    private func timeoutPill(_ seconds: Int, fillsWidth: Bool) -> some View {
        Button {
            Task { await model.timeout(seconds: seconds) }
        } label: {
            Text(TimeoutPresets.label(forSeconds: seconds))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, fillsWidth ? 6 : 12)
                .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 34)
                .background(
                    Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Time out for \(TimeoutPresets.spokenLabel(forSeconds: seconds))")
    }

    private func impactButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(
                    tint.opacity(colorScheme == .dark ? 0.16 : 0.11),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var cardFill: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.04)
    }

    private var cardBorder: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08)
    }
}
