import Foundation
import CoreGraphics

/// The caps the native player puts on which HLS variant AVPlayer may pick.
/// "Auto" on its own means source quality everywhere, which is the wrong
/// default on cellular, on a hot or power-saving device, and for video
/// nobody can see.
struct PlaybackLimits: Equatable {
    /// `.zero` = no cap (AVFoundation's sentinel), as in
    /// `PlayerQuality.maximumResolution`.
    var maximumResolution: CGSize
    /// The cap on cellular and personal hotspots.
    var maximumResolutionOnExpensiveNetworks: CGSize
    /// Bits per second; 0 = no cap.
    var peakBitRate: Double

    static let expensiveNetworkCap = PlayerQuality.p720.maximumResolution
    static let constrainedDeviceCap = PlayerQuality.p480.maximumResolution
    /// Enough for Twitch's smallest video rendition and nothing above it.
    static let hiddenVideoPeakBitRate: Double = 400_000

    /// - Parameters:
    ///   - quality: the user's own cap (Settings → Max Quality).
    ///   - deviceIsConstrained: Low Power Mode, or running hot.
    ///   - videoIsHidden: audio-only is playing the full stream because
    ///     Twitch offered no audio rendition.
    static func resolve(
        quality: PlayerQuality,
        deviceIsConstrained: Bool,
        videoIsHidden: Bool
    ) -> PlaybackLimits {
        var everywhere = quality.maximumResolution
        if deviceIsConstrained {
            everywhere = tighter(everywhere, constrainedDeviceCap)
        }
        return PlaybackLimits(
            maximumResolution: everywhere,
            maximumResolutionOnExpensiveNetworks: tighter(everywhere, expensiveNetworkCap),
            peakBitRate: videoIsHidden ? hiddenVideoPeakBitRate : 0
        )
    }

    /// The smaller of two caps, where `.zero` is "none".
    static func tighter(_ first: CGSize, _ second: CGSize) -> CGSize {
        if first == .zero { return second }
        if second == .zero { return first }
        return first.height <= second.height ? first : second
    }

    /// Low Power Mode is on, or the device is hot enough that the system is
    /// already throttling it.
    static var deviceIsConstrained: Bool {
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return true }
        return process.thermalState == .serious || process.thermalState == .critical
    }
}
