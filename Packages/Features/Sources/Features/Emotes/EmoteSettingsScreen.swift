import SwiftUI
import Core

/// You → Chat → Emotes. Per-source toggles for the third-party emote
/// providers, plus emote playback preferences (Animated Emotes moved
/// here from Chat Appearance — it's an emote setting, not a text one).
///
/// Source toggles write through `EmoteSourceSettings` (Core), which
/// `ChannelSessionRegistry` reads when constructing a channel's
/// `EmoteIndex` — so changes apply on the next channel open, the same
/// lifecycle as highlight keywords and chat filters.
struct EmoteSettingsScreen: View {

    /// Working copies seeded from persisted values; writes go through
    /// both (instant UI + persistence). Not @AppStorage because the keys
    /// live in `EmoteSourceSettings`' namespace, mirroring the
    /// HighlightSettings pattern.
    @State private var sevenTV: Bool = EmoteSourceSettings.sevenTVEnabled()
    @State private var bttv: Bool = EmoteSourceSettings.bttvEnabled()
    @State private var ffz: Bool = EmoteSourceSettings.ffzEnabled()

    @AppStorage(ChatAppearance.animatedEmotesKey) private var animatedEmotes: Bool = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { sevenTV },
                    set: { sevenTV = $0; EmoteSourceSettings.setSevenTVEnabled($0) }
                )) {
                    Text("7TV")
                }
                Toggle(isOn: Binding(
                    get: { bttv },
                    set: { bttv = $0; EmoteSourceSettings.setBTTVEnabled($0) }
                )) {
                    Text("BetterTTV")
                }
                Toggle(isOn: Binding(
                    get: { ffz },
                    set: { ffz = $0; EmoteSourceSettings.setFFZEnabled($0) }
                )) {
                    Text("FrankerFaceZ")
                }
            } header: {
                Text("Third-Party Sources")
            } footer: {
                Text("Emotes from these services appear in chat and the emote picker. Twitch's own emotes are always on. Changes apply the next time you open a channel.")
            }

            Section {
                Toggle(isOn: $animatedEmotes) {
                    Label("Animated Emotes", systemImage: "sparkles")
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("When off, animated emotes show their first frame. Saves battery in busy chats.")
            }
        }
        .navigationTitle("Emotes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
