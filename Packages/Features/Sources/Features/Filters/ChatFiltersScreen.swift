import SwiftUI

/// You → Chat → Filters. Toggles for dropping transcript noise:
/// command messages and well-known bots. Writes through
/// `ChatFilterSettings`; `TabChatModel` reads the values at attach.
struct ChatFiltersScreen: View {

    /// Working copies seeded from persisted values (HighlightSettings
    /// pattern — the keys live in ChatFilterSettings' namespace).
    @State private var hideCommands: Bool = ChatFilterSettings.hideCommands()
    @State private var hideBots: Bool = ChatFilterSettings.hideBots()

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { hideCommands },
                    set: { hideCommands = $0; ChatFilterSettings.setHideCommands($0) }
                )) {
                    Label("Hide Commands", systemImage: "exclamationmark.circle")
                }
            } footer: {
                Text("Hides messages that start with \"!\" — like !drops or !so. Your own messages always show.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { hideBots },
                    set: { hideBots = $0; ChatFilterSettings.setHideBots($0) }
                )) {
                    Label("Hide Known Bots", systemImage: "cpu")
                }
            } footer: {
                Text("Hides messages from common chat bots — Nightbot, Fossabot, StreamElements and friends. Changes apply the next time you open a channel.")
            }
        }
        .navigationTitle("Filters")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
