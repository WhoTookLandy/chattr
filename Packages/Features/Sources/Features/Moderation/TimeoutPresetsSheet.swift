import SwiftUI
import Channels

/// Edits the user card's one-tap timeout durations (`TimeoutPresets`),
/// stored per device. Opened from the card's moderation menu.
struct TimeoutPresetsSheet: View {
    @AppStorage(TimeoutPresets.storageKey) private var raw = TimeoutPresets.defaultRaw
    @Environment(\.dismiss) private var dismiss

    @State private var amount = 5
    @State private var unit: DurationUnit = .minutes

    enum DurationUnit: Int, CaseIterable, Identifiable {
        case seconds = 1
        case minutes = 60
        case hours = 3_600
        case days = 86_400

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .seconds: return "Seconds"
            case .minutes: return "Minutes"
            case .hours: return "Hours"
            case .days: return "Days"
            }
        }
    }

    private var presets: [Int] { TimeoutPresets.decode(raw) }

    private var candidate: Int { amount * unit.rawValue }

    private var canAdd: Bool {
        amount > 0
            && candidate <= ChannelSession.maxTimeoutSeconds
            && !presets.contains(candidate)
            && presets.count < TimeoutPresets.maxCount
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(presets, id: \.self) { seconds in
                        HStack {
                            Text(TimeoutPresets.label(forSeconds: seconds))
                                .font(.body.monospacedDigit().weight(.semibold))
                            Spacer()
                            Text(TimeoutPresets.spokenLabel(forSeconds: seconds))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        var next = presets
                        next.remove(atOffsets: offsets)
                        // Deleting the last one restores the defaults on
                        // decode; store it explicitly so the list matches.
                        raw = TimeoutPresets.encode(next.isEmpty ? TimeoutPresets.defaults : next)
                    }
                } header: {
                    Text("Timeouts")
                } footer: {
                    Text("Shown as one-tap chips on a user's card in channels you moderate. Up to \(TimeoutPresets.maxCount); saved on this device.")
                }

                Section("Add a timeout") {
                    Stepper(value: $amount, in: 1...999) {
                        Text("\(amount)")
                            .font(.body.monospacedDigit())
                    }
                    Picker("Unit", selection: $unit) {
                        ForEach(DurationUnit.allCases) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }
                    Button {
                        raw = TimeoutPresets.encode(presets + [candidate])
                    } label: {
                        Label("Add \(TimeoutPresets.spokenLabel(forSeconds: candidate))", systemImage: "plus.circle.fill")
                    }
                    .disabled(!canAdd)
                }

                Section {
                    Button("Reset to Defaults") {
                        raw = TimeoutPresets.defaultRaw
                    }
                    .disabled(presets == TimeoutPresets.defaults)
                }
            }
            .navigationTitle("Timeout Durations")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
