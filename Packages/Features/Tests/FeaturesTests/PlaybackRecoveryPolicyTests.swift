import Testing
import Foundation
import CoreGraphics
@testable import Features

/// The native player's retry-before-fallback policy (`PlaybackRecovery`),
/// driven with explicit instants so nothing waits.
@Suite("Native playback recovery")
struct PlaybackRecoveryPolicyTests {
    struct Boom: Error {}

    @Test("Three tries with a growing wait, then give up")
    func retriesThenGivesUp() {
        var recovery = PlaybackRecovery()
        let start = ContinuousClock.now
        let first = recovery.step(after: Boom(), now: start)
        let second = recovery.step(after: Boom(), now: start.advanced(by: .seconds(2)))
        let third = recovery.step(after: Boom(), now: start.advanced(by: .seconds(5)))
        let fourth = recovery.step(after: Boom(), now: start.advanced(by: .seconds(10)))
        #expect(first == .retry(after: .seconds(1)))
        #expect(second == .retry(after: .seconds(2)))
        #expect(third == .retry(after: .seconds(4)))
        #expect(fourth == .giveUp)
    }

    @Test("A stall that never cleared (no error) counts like any failure")
    func stallCounts() {
        var recovery = PlaybackRecovery()
        let step = recovery.step(after: nil)
        #expect(step == .retry(after: .seconds(1)))
        #expect(recovery.failures == 1)
    }

    @Test("Offline or forbidden: Twitch said no, so no tries are spent on it")
    func refusalsGiveUpAtOnce() {
        var recovery = PlaybackRecovery()
        let offline = recovery.step(after: StreamPlaylistError.offline)
        let forbidden = recovery.step(after: StreamPlaylistError.forbidden)
        #expect(offline == .giveUp)
        #expect(forbidden == .giveUp)
        #expect(recovery.failures == 0)
    }

    @Test("An answer that made no sense is worth asking again")
    func unavailableRetries() {
        var recovery = PlaybackRecovery()
        let step = recovery.step(after: StreamPlaylistError.unavailable)
        #expect(step == .retry(after: .seconds(1)))
    }

    @Test("Failures a quiet period apart are separate incidents")
    func quietPeriodResets() {
        var recovery = PlaybackRecovery()
        let start = ContinuousClock.now
        _ = recovery.step(after: Boom(), now: start)
        _ = recovery.step(after: Boom(), now: start.advanced(by: .seconds(2)))
        _ = recovery.step(after: Boom(), now: start.advanced(by: .seconds(5)))
        // Played on for ten minutes, then failed again: a full set of tries.
        let step = recovery.step(after: Boom(), now: start.advanced(by: .seconds(600)))
        #expect(step == .retry(after: .seconds(1)))
        #expect(recovery.failures == 1)
    }

    @Test("With nothing to fall back to, the tries continue slowly instead of giving up")
    func staysNativeKeepsTrying() {
        var recovery = PlaybackRecovery()
        let start = ContinuousClock.now
        for second in 0..<PlaybackRecovery.maxRetries {
            _ = recovery.step(after: Boom(), staysNative: true, now: start.advanced(by: .seconds(second)))
        }
        let next = recovery.step(after: Boom(), staysNative: true, now: start.advanced(by: .seconds(10)))
        #expect(next == .retry(after: PlaybackRecovery.patientDelay))
        // A refusal still ends it.
        let refused = recovery.step(after: StreamPlaylistError.forbidden, staysNative: true)
        #expect(refused == .giveUp)
    }
}

/// Which HLS variants the native player allows itself (`PlaybackLimits`).
@Suite("Native playback limits")
struct PlaybackLimitsTests {
    @Test("Auto: no cap on Wi-Fi, 720p on cellular")
    func autoQuality() {
        let limits = PlaybackLimits.resolve(quality: .auto, deviceIsConstrained: false, videoIsHidden: false)
        #expect(limits.maximumResolution == CGSize.zero)
        #expect(limits.maximumResolutionOnExpensiveNetworks == PlayerQuality.p720.maximumResolution)
        #expect(limits.peakBitRate == 0)
    }

    @Test("The user's cap wins where it's the tighter one")
    func userCap() {
        let low = PlaybackLimits.resolve(quality: .p360, deviceIsConstrained: false, videoIsHidden: false)
        #expect(low.maximumResolution == PlayerQuality.p360.maximumResolution)
        #expect(low.maximumResolutionOnExpensiveNetworks == PlayerQuality.p360.maximumResolution)

        let high = PlaybackLimits.resolve(quality: .p1080, deviceIsConstrained: false, videoIsHidden: false)
        #expect(high.maximumResolution == PlayerQuality.p1080.maximumResolution)
        #expect(high.maximumResolutionOnExpensiveNetworks == PlayerQuality.p720.maximumResolution)
    }

    @Test("Low Power Mode or heat: 480p everywhere, unless the user's cap is lower")
    func constrainedDevice() {
        let auto = PlaybackLimits.resolve(quality: .auto, deviceIsConstrained: true, videoIsHidden: false)
        #expect(auto.maximumResolution == PlayerQuality.p480.maximumResolution)
        #expect(auto.maximumResolutionOnExpensiveNetworks == PlayerQuality.p480.maximumResolution)

        let low = PlaybackLimits.resolve(quality: .p360, deviceIsConstrained: true, videoIsHidden: false)
        #expect(low.maximumResolution == PlayerQuality.p360.maximumResolution)
    }

    @Test("Video nobody sees is held to the smallest rendition")
    func hiddenVideo() {
        let limits = PlaybackLimits.resolve(quality: .auto, deviceIsConstrained: false, videoIsHidden: true)
        #expect(limits.peakBitRate == PlaybackLimits.hiddenVideoPeakBitRate)
        #expect(limits.peakBitRate > 0)
    }
}
