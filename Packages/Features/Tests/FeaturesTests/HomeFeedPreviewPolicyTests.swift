import Testing
import CoreGraphics
@testable import Features

@Suite("Home feed live preview policy")
struct HomeFeedPreviewPolicyTests {

    private typealias Frame = HomeFeedPreviewPolicy.CardFrame

    @Test("Selects the visible card closest to the upper-middle focal point")
    func selectsClosestToFocalPoint() {
        let frames = [
            Frame(id: "top", minY: -120, maxY: 200),
            Frame(id: "middle", minY: 200, maxY: 520),
            Frame(id: "bottom", minY: 520, maxY: 840),
        ]
        // Viewport 800pt → focal point at 336pt; "middle" center is 360pt and 100% visible.
        let selected = HomeFeedPreviewPolicy.focusedStreamID(in: frames, viewportHeight: 800)
        #expect(selected == "middle")
    }

    @Test("Ignores cards below the minimum visibility threshold")
    func ignoresBarelyVisibleCards() {
        let frames = [
            // Only 80 / 320 = 25% visible (< 45% threshold)
            Frame(id: "peekingTop", minY: -240, maxY: 80),
            // 100% visible even though farther from focal point
            Frame(id: "fullLower", minY: 420, maxY: 740),
        ]
        let selected = HomeFeedPreviewPolicy.focusedStreamID(in: frames, viewportHeight: 800)
        #expect(selected == "fullLower")
    }

    @Test("Returns nil when no cards are sufficiently visible or viewport is empty")
    func returnsNilWhenNothingVisible() {
        let offscreen = [
            Frame(id: "above", minY: -400, maxY: -10),
            Frame(id: "below", minY: 850, maxY: 1170),
        ]
        #expect(HomeFeedPreviewPolicy.focusedStreamID(in: offscreen, viewportHeight: 800) == nil)
        #expect(HomeFeedPreviewPolicy.focusedStreamID(in: [], viewportHeight: 800) == nil)
        #expect(HomeFeedPreviewPolicy.focusedStreamID(in: [Frame(id: "a", minY: 0, maxY: 300)], viewportHeight: 0) == nil)
    }

    @Test("Respects preview mode, Wi-Fi state, kill switch, visibility, thermal/power state, and video mini player")
    func canPreviewPolicyMatrix() {
        // Default Wi-Fi mode: allowed on Wi-Fi, blocked on cellular.
        #expect(HomeFeedPreviewPolicy.canPreview(
            mode: .wiFiOnly,
            isNativePlaybackEnabled: true,
            isHomeLiveVisible: true,
            isDeviceConstrained: false,
            isOnWiFi: true,
            hasActiveVideoMiniPlayer: false
        ))
        #expect(!HomeFeedPreviewPolicy.canPreview(
            mode: .wiFiOnly,
            isNativePlaybackEnabled: true,
            isHomeLiveVisible: true,
            isDeviceConstrained: false,
            isOnWiFi: false,
            hasActiveVideoMiniPlayer: false
        ))

        // Always mode allows cellular.
        #expect(HomeFeedPreviewPolicy.canPreview(
            mode: .always,
            isNativePlaybackEnabled: true,
            isHomeLiveVisible: true,
            isDeviceConstrained: false,
            isOnWiFi: false,
            hasActiveVideoMiniPlayer: false
        ))

        // Off mode always blocks.
        #expect(!HomeFeedPreviewPolicy.canPreview(
            mode: .off,
            isNativePlaybackEnabled: true,
            isHomeLiveVisible: true,
            isDeviceConstrained: false,
            isOnWiFi: true,
            hasActiveVideoMiniPlayer: false
        ))

        // Kill switch, hidden surface, Low Power / hot device, and active video mini player each block.
        #expect(!HomeFeedPreviewPolicy.canPreview(
            mode: .always, isNativePlaybackEnabled: false, isHomeLiveVisible: true,
            isDeviceConstrained: false, isOnWiFi: true, hasActiveVideoMiniPlayer: false
        ))
        #expect(!HomeFeedPreviewPolicy.canPreview(
            mode: .always, isNativePlaybackEnabled: true, isHomeLiveVisible: false,
            isDeviceConstrained: false, isOnWiFi: true, hasActiveVideoMiniPlayer: false
        ))
        #expect(!HomeFeedPreviewPolicy.canPreview(
            mode: .always, isNativePlaybackEnabled: true, isHomeLiveVisible: true,
            isDeviceConstrained: true, isOnWiFi: true, hasActiveVideoMiniPlayer: false
        ))
        #expect(!HomeFeedPreviewPolicy.canPreview(
            mode: .always, isNativePlaybackEnabled: true, isHomeLiveVisible: true,
            isDeviceConstrained: false, isOnWiFi: true, hasActiveVideoMiniPlayer: true
        ))
    }
}
