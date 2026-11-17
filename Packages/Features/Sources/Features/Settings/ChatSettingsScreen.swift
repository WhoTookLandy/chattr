import SwiftUI

/// Settings → Chat: how chat behaves. Links to the feature screens that
/// own highlights, filters and emotes, plus the two behaviour settings
/// with no feature home of their own (history length, resume on launch).
///
/// Not to be confused with `ChatSettingsSheet`, the per-channel sheet
/// opened from inside a chat (moderator chat modes + quick toggles).
struct ChatSettingsScreen: View {
    @AppStorage(ChatAppearance.chatHistoryLinesKey) private var chatHistoryLines: Int = ChatAppearance.defaultChatHistoryLines
    /// Read by AppShell / ChatsScreen scene restoration; default on
    /// (resume) matches pre-toggle behaviour.
    @AppStorage("chattr.resumeLastChatOnLaunch") private var resumeLastChatOnLaunch = true

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    HighlightKeywordsScreen()
                } label: {
                    SettingLabel("Highlights", systemImage: "sparkles", subtitle: "Mentions, keywords and sound")
                }
                NavigationLink {
                    ChatFiltersScreen()
                } label: {
                    SettingLabel("Filters", systemImage: "line.3.horizontal.decrease.circle", subtitle: "Commands, bots, live events")
                }
                NavigationLink {
                    EmoteSettingsScreen()
                } label: {
                    SettingLabel("Emotes", systemImage: "face.smiling", subtitle: "7TV, BetterTTV, FrankerFaceZ, animation")
                }
            } footer: {
                Text("Keyword, filter and emote source changes apply the next time you open a channel.")
            }

            Section {
                Picker(selection: $chatHistoryLines) {
                    ForEach(ChatAppearance.chatHistoryOptions, id: \.self) { count in
                        Text("\(count) messages").tag(count)
                    }
                } label: {
                    Label("Chat History", systemImage: "clock.arrow.circlepath")
                }
            } footer: {
                Text("How many messages each chat keeps in scrollback. Larger histories use more memory and make switching between open chats slower. Applies the next time a chat opens.")
            }

            Section {
                Toggle(isOn: $resumeLastChatOnLaunch) {
                    SettingLabel(
                        "Resume Last Chat",
                        systemImage: "arrow.uturn.forward",
                        subtitle: "Reopen the chat you had open when chattr closed"
                    )
                }
            }
        }
        .navigationTitle("Chat")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
