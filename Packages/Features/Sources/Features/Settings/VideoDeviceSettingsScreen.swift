import SwiftUI

/// Settings → Video & Device: the in-chat stream player (what happens when
/// a chat opens, picture in picture, quality), the landscape layout, and
/// device behaviour (keeping the screen awake, haptics).
///
/// Adding a setting here: put the control in the matching section, then
/// register it in `SettingsRegistry.entries` with `in: .videoAndDevice` so
/// search finds it.
struct VideoDeviceSettingsScreen: View {
    @AppStorage(StreamHeaderView.expandedKey) private var showVideoInChat = false
    @AppStorage(PlayerSettings.nativePlayerKey) private var useNativePlayer = false
    @AppStorage(PlayerSettings.maxQualityKey) private var maxQuality: PlayerQuality = .auto
    @AppStorage(PlaybackPreferences.videoOnOpenKey) private var videoOnOpen: VideoOnOpen = .lastUsed
    @AppStorage(PlaybackPreferences.homePreviewKey) private var homePreview: HomePreviewMode = .wiFiOnly
    @AppStorage(PlaybackPreferences.pictureInPictureKey) private var pictureInPicture: PictureInPictureMode = .whenSoundOn
    @AppStorage(PlayerSettings.systemPictureInPictureKey) private var pictureInPictureLeavingChat = false
    @AppStorage(PlaybackPreferences.keepScreenAwakeKey) private var keepScreenAwake = false
    @AppStorage(HapticSettings.enabledKey) private var hapticsEnabled = true
    /// The native path's kill switch (`PlayerSettings.isNativePlaybackEnabled`).
    /// Observed so the rows follow it; nothing here writes it.
    @AppStorage(PlayerSettings.nativePlaybackDisabledKey) private var nativePlaybackDisabled = false

    private var nativePlaybackEnabled: Bool { !nativePlaybackDisabled }

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
                Picker(selection: $videoOnOpen) {
                    ForEach(VideoOnOpen.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    SettingLabel(
                        "When a Chat Opens",
                        systemImage: "rectangle.portrait.and.arrow.forward",
                        subtitle: "Watch and Listen from a channel's menu always play"
                    )
                }
                .onChange(of: videoOnOpen) { _, option in
                    if option == .autoplayOnWiFi { NetworkReachability.warmUp() }
                }
                Picker(selection: $homePreview) {
                    ForEach(HomePreviewMode.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    SettingLabel(
                        "Home Live Previews",
                        systemImage: "play.rectangle.on.rectangle",
                        subtitle: "Muted live video on Home cards as you scroll",
                        disabledReason: nativePlaybackEnabled ? nil : "Not available right now"
                    )
                }
                .disabled(!nativePlaybackEnabled)
                .onChange(of: homePreview) { _, option in
                    if option == .wiFiOnly { NetworkReachability.warmUp() }
                }
                Toggle(isOn: $useNativePlayer) {
                    SettingLabel(
                        "Native Video Player",
                        systemImage: "play.tv",
                        subtitle: "Experimental: picture-in-picture and quality control",
                        disabledReason: nativePlaybackEnabled ? nil : "Not available right now"
                    )
                }
                .disabled(!nativePlaybackEnabled)
                Picker(selection: $maxQuality) {
                    ForEach(PlayerQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                } label: {
                    SettingLabel(
                        "Max Quality",
                        systemImage: "dial.medium",
                        disabledReason: useNativePlayer && nativePlaybackEnabled ? nil : "Needs Native Video Player on"
                    )
                }
                .disabled(!useNativePlayer || !nativePlaybackEnabled)
                Picker(selection: $pictureInPicture) {
                    ForEach(PictureInPictureMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    SettingLabel(
                        "Picture in Picture",
                        systemImage: "pip",
                        subtitle: pictureInPicture.subtitle
                    )
                }
                Toggle(isOn: $pictureInPictureLeavingChat) {
                    SettingLabel(
                        "PiP When Leaving Chat",
                        systemImage: "pip.exit",
                        subtitle: "Apple's floating player instead of the mini player"
                    )
                }
            } header: {
                Text("Video")
            } footer: {
                Text("Autoplay starts the stream muted, and only on Wi-Fi; on cellular the video stays closed. Picture in picture opens automatically with the native player; with \"With Sound On\", a muted or paused stream pauses when you leave instead.\n\nThe native player relies on an unofficial Twitch interface; if it can't load a stream, chattr switches back to Twitch's web player. Audio-only mode always uses the native player, since the web player can't play without showing video.")
            }

            #if os(iOS)
            TwitchWebSessionSection()
            #endif

            Section {
                NavigationLink {
                    LandscapeSettingsScreen()
                } label: {
                    SettingLabel(
                        "Landscape Layout",
                        systemImage: "rectangle.split.2x1",
                        subtitle: "Chat beside or over the video when sideways"
                    )
                }
            } header: {
                Text("Landscape")
            } footer: {
                Text("Applies when you turn your phone sideways while a stream is showing.")
            }

            Section {
                Toggle(isOn: $keepScreenAwake) {
                    SettingLabel(
                        "Keep Screen Awake",
                        systemImage: "sun.max",
                        subtitle: "Uses more battery"
                    )
                }
                #if os(iOS)
                .onChange(of: keepScreenAwake) { _, _ in
                    IdleTimerController.shared.refresh()
                }
                #endif
                Toggle(isOn: $hapticsEnabled) {
                    SettingLabel("Haptic Feedback", systemImage: "iphone.radiowaves.left.and.right")
                }
            } header: {
                Text("Device")
            }
        }
        .navigationTitle("Video & Device")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
