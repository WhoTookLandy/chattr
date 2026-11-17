import Foundation

/// Device and playback preferences (Settings → Video & Device).
///
/// Plain `UserDefaults` keys, read at the moment they matter — leaving the
/// app, opening a chat, a mute change. No chat view observes them, so
/// changing one never re-renders a transcript. Settings binds to the same
/// keys through `@AppStorage`.
enum PlaybackPreferences {
    /// Keep the screen from dimming while a chat or stream is on screen.
    static let keepScreenAwakeKey = "chattr.device.keepScreenAwake"
    /// When leaving the app may open picture in picture.
    static let pictureInPictureKey = "chattr.player.pictureInPicture"
    /// What the video does when a chat opens.
    static let videoOnOpenKey = "chattr.player.videoOnOpen"

    static var keepScreenAwake: Bool {
        UserDefaults.standard.bool(forKey: keepScreenAwakeKey)
    }

    static var pictureInPicture: PictureInPictureMode {
        UserDefaults.standard.string(forKey: pictureInPictureKey)
            .flatMap(PictureInPictureMode.init(rawValue:)) ?? .whenSoundOn
    }

    static var videoOnOpen: VideoOnOpen {
        UserDefaults.standard.string(forKey: videoOnOpenKey)
            .flatMap(VideoOnOpen.init(rawValue:)) ?? .lastUsed
    }
}

/// Whether leaving the app hands the stream to picture in picture.
enum PictureInPictureMode: String, CaseIterable, Identifiable {
    /// Only a stream that's playing with sound — a muted or paused one
    /// pauses instead of floating over other apps.
    case whenSoundOn
    /// Any playing stream (the old behaviour).
    case always
    /// Never automatically; the PiP button still works.
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whenSoundOn: "With Sound On"
        case .always: "Always"
        case .off: "Off"
        }
    }

    /// One line under the setting's title.
    var subtitle: String {
        switch self {
        case .whenSoundOn: "Opens when you leave with sound on"
        case .always: "Opens whenever you leave a playing stream"
        case .off: "Only from the picture in picture button"
        }
    }
}

/// The stream header's state when a chat opens.
enum VideoOnOpen: String, CaseIterable, Identifiable {
    /// However the video was last left (the "Show Video in Chat" switch).
    case lastUsed
    /// Collapsed; the video is a tap away in the header.
    case closed
    /// Open and playing muted on Wi-Fi; collapsed on cellular.
    case autoplayOnWiFi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lastUsed: "As Last Left"
        case .closed: "Closed"
        case .autoplayOnWiFi: "Autoplay on Wi-Fi"
        }
    }
}
