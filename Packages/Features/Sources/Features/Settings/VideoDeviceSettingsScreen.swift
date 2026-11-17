import SwiftUI

/// Settings → Video & Device: the in-chat stream player, and (as they land)
/// device behaviour such as keeping the screen awake or picture-in-picture
/// preferences.
///
/// Adding a setting here: put the control in the matching section (add a
/// "Device" section for device-level toggles), then register it in
/// `SettingsRegistry.entries` with `in: .videoAndDevice` so search finds it.
struct VideoDeviceSettingsScreen: View {
    @AppStorage(StreamHeaderView.expandedKey) private var showVideoInChat = false
    @AppStorage(PlayerSettings.nativePlayerKey) private var useNativePlayer = false
    @AppStorage(PlayerSettings.maxQualityKey) private var maxQuality: PlayerQuality = .auto

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showVideoInChat) {
                    SettingLabel(
                        "Show Video in Chat",
                        systemImage: "play.rectangle",
                        subtitle: "Stream plays above chat; swipe it away to hide it"
                    )
                }
                Toggle(isOn: $useNativePlayer) {
                    SettingLabel(
                        "Native Video Player",
                        systemImage: "play.tv",
                        subtitle: "Experimental: picture-in-picture and quality control"
                    )
                }
                Picker(selection: $maxQuality) {
                    ForEach(PlayerQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                } label: {
                    SettingLabel(
                        "Max Quality",
                        systemImage: "dial.medium",
                        disabledReason: useNativePlayer ? nil : "Needs Native Video Player on"
                    )
                }
                .disabled(!useNativePlayer)
            } header: {
                Text("Player")
            } footer: {
                Text("The native player relies on an unofficial Twitch interface; if it can't load a stream, chattr switches back to Twitch's web player. Audio-only mode always uses the native player, since the web player can't play without showing video.")
            }
        }
        .navigationTitle("Video & Device")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
