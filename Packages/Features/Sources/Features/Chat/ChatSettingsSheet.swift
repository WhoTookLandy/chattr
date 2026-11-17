import SwiftUI
import Channels
import ChatModel

/// In-chat settings sheet, modeled on Twitch's native Chat Settings.
///
/// Two sections:
///   - **Chat Modes** — emote-only / subscribers-only / followers-only /
///     slow mode, PATCHed to Helix via `ChatTranscriptModel.updateChatSettings`.
///     Shown ONLY when `chatModel.currentUserCanModerate` (broadcaster
///     detected at attach, moderator detected from own-message badges).
///     Twitch enforces the same gate server-side, so the UI gate is
///     about honesty, not security.
///   - **My Preferences** — the viewer-side appearance knobs every user
///     gets (timestamp / animated-emote quick toggles + a link to the
///     full Chat Appearance screen with its live preview).
///
/// ## Sync model
///
/// The toggles are local `@State` mirrors of `chatModel.chatRestrictions`
/// (the authoritative snapshot, live-updated by EventSub
/// `chat_settings.update` AND by our own PATCH responses). Mirroring is
/// required because a Toggle needs a `Binding`, and we must be able to
/// *revert* it when a PATCH fails.
///
/// Loop prevention: every `onChange` first compares the new local value
/// against the authoritative snapshot and bails when they already agree.
/// That kills both echo loops (model → local sync re-firing onChange)
/// and makes error-revert silent (revert lands the local value back on
/// the authoritative one → guard skips the would-be PATCH).
struct ChatSettingsSheet: View {
    let chatModel: ChatTranscriptModel
    let channelLoginName: String
    /// Signed-in user's login, forwarded to `AppearanceSettingsScreen` for
    /// its "@you" mention preview row.
    let currentUserLogin: String

    @Environment(\.dismiss) private var dismiss

    // Local mirrors of the channel's chat modes — see "Sync model" above.
    @State private var emoteOnly = false
    @State private var subscribersOnly = false
    @State private var followersOnly = false
    @State private var followersDurationMinutes = 0
    @State private var slowMode = false
    @State private var slowModeSeconds = 30

    /// Most recent PATCH failure, shown in an alert. nil = no alert.
    @State private var errorMessage: String?

    // Viewer-preference quick toggles — same UserDefaults keys as
    // AppearanceSettingsScreen, so flipping one here updates open chats and
    // the appearance screen alike.
    @AppStorage(ChatAppearance.showTimestampsKey) private var showTimestamps: Bool = false
    @AppStorage(ChatAppearance.animatedEmotesKey) private var animatedEmotes: Bool = true
    @AppStorage(ChatAppearance.edgeToEdgeKey) private var edgeToEdge: Bool = false
    @AppStorage(ChatAppearance.loginNameDisplayKey) private var loginNameDisplay: ChatAppearance.LoginNameDisplay = .displayFirst

    /// Twitch's standard slow-mode wait times. The current channel value
    /// is spliced in when it's nonstandard (set from another client) so
    /// the Picker always has a valid selection.
    private var slowModeOptions: [Int] {
        var options = [3, 5, 10, 30, 60, 120]
        if !options.contains(slowModeSeconds) {
            options.append(slowModeSeconds)
            options.sort()
        }
        return options
    }

    /// Follow-age requirements (minutes), mirroring Twitch's common
    /// presets. 0 = any follower. Same splice-in trick as slow mode.
    private var followerDurationOptions: [Int] {
        var options = [0, 10, 30, 60, 1440, 10080, 43200]
        if !options.contains(followersDurationMinutes) {
            options.append(followersDurationMinutes)
            options.sort()
        }
        return options
    }

    var body: some View {
        NavigationStack {
            Form {
                if chatModel.currentUserCanModerate {
                    chatModesSection
                }
                preferencesSection
            }
            .navigationTitle("Chat Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        // Seed at mount AND re-sync whenever the authoritative snapshot
        // changes (our PATCH response, an EventSub update from another
        // mod, or the error-revert path calling syncFromModel directly).
        .task(id: chatModel.chatRestrictions) {
            syncFromModel()
        }
        .alert(
            "Couldn't update chat settings",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Chat Modes (mod-gated)

    private var chatModesSection: some View {
        Section {
            Toggle(isOn: $emoteOnly) {
                Label("Emote-Only Chat", systemImage: "face.smiling")
            }
            Toggle(isOn: $subscribersOnly) {
                Label("Subscribers-Only Chat", systemImage: "star")
            }
            Toggle(isOn: $followersOnly) {
                Label("Followers-Only Chat", systemImage: "heart")
            }
            if followersOnly {
                Picker("Minimum Follow Time", selection: $followersDurationMinutes) {
                    ForEach(followerDurationOptions, id: \.self) { minutes in
                        Text(Self.followerDurationLabel(minutes)).tag(minutes)
                    }
                }
            }
            Toggle(isOn: $slowMode) {
                Label("Slow Mode", systemImage: "timer")
            }
            if slowMode {
                Picker("Wait Time", selection: $slowModeSeconds) {
                    ForEach(slowModeOptions, id: \.self) { seconds in
                        Text("\(seconds)s").tag(seconds)
                    }
                }
            }
        } header: {
            Text("Chat Modes")
        } footer: {
            Text("You can change these because you moderate #\(channelLoginName).")
        }
        // Every onChange follows the same shape: bail when local already
        // matches the authoritative snapshot (sync echo / error revert),
        // otherwise PATCH the single field that moved.
        .onChange(of: emoteOnly) { _, new in
            guard new != (chatModel.chatRestrictions?.emoteOnly ?? false) else { return }
            apply { try await chatModel.updateChatSettings(emoteOnly: new) }
        }
        .onChange(of: subscribersOnly) { _, new in
            guard new != (chatModel.chatRestrictions?.subscribersOnly ?? false) else { return }
            apply { try await chatModel.updateChatSettings(subscribersOnly: new) }
        }
        .onChange(of: followersOnly) { _, new in
            guard new != (chatModel.chatRestrictions?.followersOnly ?? false) else { return }
            // Twitch wants the duration alongside the enable flag.
            apply {
                try await chatModel.updateChatSettings(
                    followersOnly: new,
                    followersDurationMinutes: new ? followersDurationMinutes : nil
                )
            }
        }
        .onChange(of: followersDurationMinutes) { _, new in
            guard followersOnly,
                  new != (chatModel.chatRestrictions?.followersDurationMinutes ?? 0)
            else { return }
            apply {
                try await chatModel.updateChatSettings(
                    followersOnly: true, followersDurationMinutes: new
                )
            }
        }
        .onChange(of: slowMode) { _, new in
            guard new != (chatModel.chatRestrictions?.slowModeSeconds != nil) else { return }
            apply {
                try await chatModel.updateChatSettings(
                    slowMode: new,
                    slowModeSeconds: new ? slowModeSeconds : nil
                )
            }
        }
        .onChange(of: slowModeSeconds) { _, new in
            guard slowMode,
                  new != chatModel.chatRestrictions?.slowModeSeconds
            else { return }
            apply {
                try await chatModel.updateChatSettings(slowMode: true, slowModeSeconds: new)
            }
        }
    }

    // MARK: - My Preferences (everyone)

    private var preferencesSection: some View {
        Section {
            Toggle(isOn: $showTimestamps) {
                Label("Timestamps", systemImage: "clock")
            }
            Toggle(isOn: $animatedEmotes) {
                Label("Animated Emotes", systemImage: "sparkles")
            }
            Toggle(isOn: Binding(
                get: { loginNameDisplay != .off },
                set: { loginNameDisplay = $0 ? .displayFirst : .off }
            )) {
                SettingLabel("Show Username", systemImage: "at", subtitle: "Beside localized display names")
            }
            Toggle(isOn: $edgeToEdge) {
                SettingLabel(
                    "Edge-to-Edge Chat",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    subtitle: "Chat scrolls behind the floating header"
                )
            }
            NavigationLink {
                AppearanceSettingsScreen(currentUserLogin: currentUserLogin)
            } label: {
                SettingLabel("All Appearance Settings", systemImage: "textformat.size", subtitle: "Text size, badges, theme")
            }
        } header: {
            Text("My Preferences")
        } footer: {
            Text("Preferences apply on this device, in every channel. Find everything else in Settings, behind your avatar on Home.")
        }
    }

    // MARK: - Sync + apply

    /// Pull the authoritative snapshot into the local control mirrors.
    /// Writing equal values is a no-op for SwiftUI state, and the
    /// onChange guards skip any value this sync genuinely moves.
    private func syncFromModel() {
        let restrictions = chatModel.chatRestrictions
        emoteOnly = restrictions?.emoteOnly ?? false
        subscribersOnly = restrictions?.subscribersOnly ?? false
        followersOnly = restrictions?.followersOnly ?? false
        followersDurationMinutes = restrictions?.followersDurationMinutes ?? 0
        slowMode = restrictions?.slowModeSeconds != nil
        if let seconds = restrictions?.slowModeSeconds {
            slowModeSeconds = seconds
        }
    }

    /// Run one PATCH; on failure surface the error and snap the controls
    /// back to the authoritative state.
    private func apply(_ change: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await change()
            } catch {
                errorMessage = error.localizedDescription
                syncFromModel()
            }
        }
    }

    /// "Any followers" / "10 minutes" / "1 hour" / "1 day" / "1 week" /
    /// "1 month" — human label for a follow-age requirement.
    private static func followerDurationLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Any followers"
        case ..<60: return "\(minutes) minutes"
        case ..<1440: return "\(minutes / 60) hour\(minutes / 60 == 1 ? "" : "s")"
        case ..<10080: return "\(minutes / 1440) day\(minutes / 1440 == 1 ? "" : "s")"
        case ..<43200: return "\(minutes / 10080) week\(minutes / 10080 == 1 ? "" : "s")"
        default: return "\(minutes / 43200) month\(minutes / 43200 == 1 ? "" : "s")"
        }
    }
}
