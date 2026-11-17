import SwiftUI

/// Settings → Chat → Filters. Toggles for dropping transcript noise:
/// command messages and well-known bots. Writes through
/// `ChatFilterSettings`; `ChatTranscriptModel` reads the values at attach.
struct ChatFiltersScreen: View {

    // Bind straight to the persisted keys via @AppStorage. These default to
    // `false` (matching `ChatFilterSettings.hideCommands()/hideBots()`, which
    // read the same keys for `ChatTranscriptModel.attach`), and the projected
    // `$` bindings replace the previous closure `Binding(get:set:)` mirrors —
    // no per-body closure allocation, no manual setX write-through.
    @AppStorage(ChatFilterSettings.hideCommandsKey) private var hideCommands = false
    @AppStorage(ChatFilterSettings.hideBotsKey) private var hideBots = false
    @AppStorage(ChatAppearance.compactBotsKey) private var compactBots = false
    // Default true — matches `LiveEventsSettings.isEnabled(_:)`.
    @AppStorage(LiveEventsSettings.pollsKey) private var showPolls = true
    @AppStorage(LiveEventsSettings.predictionsKey) private var showPredictions = true
    @AppStorage(LiveEventsSettings.hypeTrainKey) private var showHypeTrain = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $hideCommands) {
                    Label("Hide Commands", systemImage: "exclamationmark.circle")
                }
            } footer: {
                Text("Hides messages that start with \"!\" — like !drops or !so. Your own messages always show.")
            }

            Section {
                Toggle(isOn: $hideBots) {
                    Label("Hide Known Bots", systemImage: "cpu")
                }
            } footer: {
                Text("Hides messages from common chat bots — Nightbot, Fossabot, StreamElements and friends. Changes apply the next time you open a channel.")
            }

            Section {
                Toggle(isOn: $compactBots) {
                    SettingLabel(
                        "Compact Bot Messages",
                        systemImage: "text.badge.minus",
                        disabledReason: hideBots ? "Not needed while Hide Known Bots is on" : nil
                    )
                }
                .disabled(hideBots)
            } footer: {
                Text("Shows bot messages smaller and dimmed, capped at three lines, with decorative banner lines removed. Applies instantly.")
            }

            // Live-event banners. TODO(settings registry): register these
            // rows once the searchable settings registry lands.
            Section {
                Toggle(isOn: $showPolls) {
                    Label("Polls", systemImage: "chart.bar.fill")
                }
                Toggle(isOn: $showPredictions) {
                    Label("Predictions", systemImage: "sparkles")
                }
                Toggle(isOn: $showHypeTrain) {
                    Label("Hype Train", systemImage: "train.side.front.car")
                }
            } header: {
                Text("Live Event Banners")
            } footer: {
                Text("Shows live polls, predictions and Hype Trains as banners at the top of chat. Twitch only shares these with the broadcaster, so they appear in your own channel. Applies instantly.")
            }
        }
        .navigationTitle("Filters")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
