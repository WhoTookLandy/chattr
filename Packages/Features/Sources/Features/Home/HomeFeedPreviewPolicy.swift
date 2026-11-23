import CoreGraphics

/// Pure decision logic for Home's inline live video previews:
/// which card in the viewport should preview, and whether playback is allowed
/// under the user's settings and current device/playback state.
///
/// Kept platform-agnostic so unit tests can exercise every branch directly.
enum HomeFeedPreviewPolicy {

    /// One stream card's vertical bounds inside the Home feed's coordinate space.
    struct CardFrame: Equatable, Sendable {
        let id: String
        let minY: CGFloat
        let maxY: CGFloat

        var height: CGFloat { max(0, maxY - minY) }
        var midY: CGFloat { (minY + maxY) * 0.5 }
    }

    /// Picks the single stream card that should play a live preview:
    /// the card with at least `minimumVisibleFraction` of its height inside
    /// `[0, viewportHeight]` whose center sits closest to the viewport's
    /// upper-middle focal point (`viewportHeight * focalPointRatio`).
    static func focusedStreamID(
        in frames: [CardFrame],
        viewportHeight: CGFloat,
        minimumVisibleFraction: CGFloat = 0.45,
        focalPointRatio: CGFloat = 0.42
    ) -> String? {
        guard viewportHeight > 0 else { return nil }
        let focalY = viewportHeight * focalPointRatio
        var bestID: String?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for frame in frames {
            let height = frame.height
            guard height > 0 else { continue }
            let visibleTop = max(0, frame.minY)
            let visibleBottom = min(viewportHeight, frame.maxY)
            let visibleHeight = max(0, visibleBottom - visibleTop)
            guard visibleHeight / height >= minimumVisibleFraction else { continue }

            let distance = abs(frame.midY - focalY)
            if distance < bestDistance {
                bestDistance = distance
                bestID = frame.id
            }
        }
        return bestID
    }

    /// Whether an inline muted live preview may start right now.
    ///
    /// Notice that an active **audio-only** mini player does NOT block the
    /// muted visual preview (matching Twitch's own Home feed), whereas an
    /// active video mini player does so we never decode two live videos at once.
    static func canPreview(
        mode: HomePreviewMode,
        isNativePlaybackEnabled: Bool,
        isHomeLiveVisible: Bool,
        isDeviceConstrained: Bool,
        isOnWiFi: Bool,
        hasActiveVideoMiniPlayer: Bool
    ) -> Bool {
        guard isNativePlaybackEnabled,
              isHomeLiveVisible,
              !isDeviceConstrained,
              !hasActiveVideoMiniPlayer
        else { return false }

        switch mode {
        case .off:
            return false
        case .wiFiOnly:
            return isOnWiFi
        case .always:
            return true
        }
    }
}
