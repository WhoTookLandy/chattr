import Foundation
import CoreMedia
#if os(iOS)
import AVFoundation
#endif

/// Live-edge target and forward-buffer tuning for native `AVPlayer` streams
/// (video, audio-only, and pinned background audio).
struct PlaybackLatencyProfile: Equatable, Sendable {
    /// Target distance behind the HLS live edge (`AVPlayerItem.configuredTimeOffsetFromLive`)
    /// and the margin subtracted from `seekableTimeRanges.last` on resume.
    let liveOffsetSeconds: Double
    /// Forward buffer cap (`AVPlayerItem.preferredForwardBufferDuration`).
    /// `0` lets AVFoundation pick its automatic buffer size.
    let forwardBufferDuration: TimeInterval
    let isLowLatency: Bool

    var liveOffset: CMTime {
        CMTime(seconds: liveOffsetSeconds, preferredTimescale: 600)
    }

    /// Standard profile: ~3 Twitch 2-second segments behind live with
    /// AVFoundation's automatic forward buffer.
    static let standard = PlaybackLatencyProfile(
        liveOffsetSeconds: 6,
        forwardBufferDuration: 0,
        isLowLatency: false
    )

    /// Low-latency profile: asks AVPlayer for the tightest live-edge offset
    /// (clamped to the HLS playlist's minimum hold-back) and caps forward
    /// buffering to 2 seconds so audio-only and video stay close to live.
    static let lowLatency = PlaybackLatencyProfile(
        liveOffsetSeconds: 2,
        forwardBufferDuration: 2,
        isLowLatency: true
    )

    static func resolve(lowLatency: Bool) -> PlaybackLatencyProfile {
        lowLatency ? .lowLatency : .standard
    }

    static var current: PlaybackLatencyProfile {
        resolve(lowLatency: PlayerSettings.isLowLatencyEnabled)
    }
}

/// Point-in-time live latency and buffering metrics for a playing stream,
/// displayed in `ChatDebugOverlay` and logged to `AppLogger` on start/stall.
struct PlaybackLatencySnapshot: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case video = "vid"
        case audioOnly = "aud"
        case audioHiddenVideo = "aud*"
        case web = "web"
    }

    let channelLogin: String
    let mode: Mode
    let isLowLatency: Bool
    /// Wall-clock delay estimated from HLS `#EXT-X-PROGRAM-DATE-TIME`
    /// (`now - item.currentDate()`), when the stream provides program dates.
    let endToEndSeconds: Double?
    /// Distance behind the end of `seekableTimeRanges` (`seekableEnd - currentTime`).
    let liveEdgeLagSeconds: Double?
    /// Media currently buffered ahead of `currentTime` in `loadedTimeRanges`.
    let bufferedAheadSeconds: Double?
    /// `AVPlayerItem.configuredTimeOffsetFromLive` in seconds.
    let configuredOffsetSeconds: Double?
    /// `AVPlayerItem.recommendedTimeOffsetFromLive` in seconds (Apple's
    /// network- and playlist-informed hold-back floor).
    let recommendedOffsetSeconds: Double?
    /// `AVPlayerItem.preferredForwardBufferDuration` (`0` = automatic).
    let preferredForwardBufferSeconds: Double
    /// Cumulative stalls reported by `AVPlayerItemAccessLog`.
    let stallCount: Int?

    /// Compact single line for `ChatDebugOverlay`.
    func compactHUDLine(showChannel: Bool = false) -> String {
        let prefix = showChannel ? "play:@\(channelLogin) " : "play:"
        if mode == .web {
            return "\(prefix)web (WKWebView HLS)"
        }
        let profile = isLowLatency ? "LL" : "std"
        var parts = ["\(prefix)\(mode.rawValue)(\(profile))"]
        if let e2e = endToEndSeconds {
            parts.append("e2e:\(Self.formatSeconds(e2e))")
        }
        if let lag = liveEdgeLagSeconds {
            parts.append("lag:\(Self.formatSeconds(lag))")
        }
        if let buf = bufferedAheadSeconds {
            parts.append("buf:\(Self.formatSeconds(buf))")
        }
        if let cfg = configuredOffsetSeconds {
            parts.append("cfg:\(Self.formatSeconds(cfg))")
        }
        if let rec = recommendedOffsetSeconds {
            parts.append("rec:\(Self.formatSeconds(rec))")
        }
        if let stallCount {
            parts.append("stl:\(stallCount)")
        }
        return parts.joined(separator: " ")
    }

    /// Key=value summary for structured `AppLogger` entries.
    var logSummary: String {
        if mode == .web {
            return "channel=@\(channelLogin) mode=web"
        }
        let profile = isLowLatency ? "LL" : "std"
        let e2e = endToEndSeconds.map(Self.formatSeconds) ?? "n/a"
        let lag = liveEdgeLagSeconds.map(Self.formatSeconds) ?? "n/a"
        let buf = bufferedAheadSeconds.map(Self.formatSeconds) ?? "n/a"
        let cfg = configuredOffsetSeconds.map(Self.formatSeconds) ?? "n/a"
        let rec = recommendedOffsetSeconds.map(Self.formatSeconds) ?? "n/a"
        let fwd = preferredForwardBufferSeconds > 0 ? Self.formatSeconds(preferredForwardBufferSeconds) : "auto"
        let stl = stallCount.map(String.init) ?? "n/a"
        return "channel=@\(channelLogin) mode=\(mode.rawValue) profile=\(profile) e2e=\(e2e) lag=\(lag) buf=\(buf) cfg=\(cfg) rec=\(rec) fwdCap=\(fwd) stalls=\(stl)"
    }

    private static func formatSeconds(_ value: Double) -> String {
        String(format: "%.1fs", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Pure metric calculation from raw `CMTime` / `Date` readings so math is
    /// directly unit-testable without a live network HLS stream.
    static func make(
        channelLogin: String,
        mode: Mode,
        isLowLatency: Bool,
        currentTime: CMTime,
        currentDate: Date?,
        now: Date = Date(),
        seekableRanges: [CMTimeRange],
        loadedRanges: [CMTimeRange],
        configuredTimeOffsetFromLive: CMTime,
        recommendedTimeOffsetFromLive: CMTime,
        preferredForwardBufferDuration: TimeInterval,
        stallCounts: [Int]?
    ) -> PlaybackLatencySnapshot {
        let e2e: Double?
        if let currentDate {
            let delta = now.timeIntervalSince(currentDate)
            // Guard against bogus / clock-skewed dates far outside live bounds.
            e2e = (delta >= 0 && delta < 3600) ? delta : nil
        } else {
            e2e = nil
        }

        let liveLag: Double?
        if currentTime.isNumeric,
           let lastSeekable = seekableRanges.last,
           lastSeekable.isValid, !lastSeekable.isEmpty,
           lastSeekable.start.isNumeric, lastSeekable.duration.isNumeric {
            let edge = CMTimeRangeGetEnd(lastSeekable)
            if edge.isNumeric {
                liveLag = max(0, CMTimeGetSeconds(CMTimeSubtract(edge, currentTime)))
            } else {
                liveLag = nil
            }
        } else {
            liveLag = nil
        }

        let bufferedAhead: Double?
        if currentTime.isNumeric {
            let nowSeconds = CMTimeGetSeconds(currentTime)
            var matchedAhead: Double?
            for range in loadedRanges where range.isValid && !range.isEmpty && range.start.isNumeric && range.duration.isNumeric {
                let start = CMTimeGetSeconds(range.start)
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                guard start.isFinite, end.isFinite else { continue }
                if nowSeconds >= start - 0.5, nowSeconds <= end + 0.5 {
                    matchedAhead = max(0, end - nowSeconds)
                    break
                }
            }
            bufferedAhead = matchedAhead
        } else {
            bufferedAhead = nil
        }

        let configured = configuredTimeOffsetFromLive.isNumeric
            ? max(0, CMTimeGetSeconds(configuredTimeOffsetFromLive))
            : nil
        let recommended = recommendedTimeOffsetFromLive.isNumeric
            ? max(0, CMTimeGetSeconds(recommendedTimeOffsetFromLive))
            : nil

        let totalStalls: Int? = stallCounts.map { counts in
            counts.reduce(0) { $0 + max(0, $1) }
        }

        return PlaybackLatencySnapshot(
            channelLogin: channelLogin,
            mode: mode,
            isLowLatency: isLowLatency,
            endToEndSeconds: e2e,
            liveEdgeLagSeconds: liveLag,
            bufferedAheadSeconds: bufferedAhead,
            configuredOffsetSeconds: configured,
            recommendedOffsetSeconds: recommended,
            preferredForwardBufferSeconds: max(0, preferredForwardBufferDuration),
            stallCount: totalStalls
        )
    }

    #if os(iOS)
    @MainActor
    static func sample(
        item: AVPlayerItem,
        channelLogin: String,
        mode: Mode,
        isLowLatency: Bool = PlayerSettings.isLowLatencyEnabled,
        now: Date = Date()
    ) -> PlaybackLatencySnapshot {
        let seekable = item.seekableTimeRanges.map(\.timeRangeValue)
        let loaded = item.loadedTimeRanges.map(\.timeRangeValue)
        let stalls = item.accessLog()?.events.map(\.numberOfStalls)
        return make(
            channelLogin: channelLogin,
            mode: mode,
            isLowLatency: isLowLatency,
            currentTime: item.currentTime(),
            currentDate: item.currentDate(),
            now: now,
            seekableRanges: seekable,
            loadedRanges: loaded,
            configuredTimeOffsetFromLive: item.configuredTimeOffsetFromLive,
            recommendedTimeOffsetFromLive: item.recommendedTimeOffsetFromLive,
            preferredForwardBufferDuration: item.preferredForwardBufferDuration,
            stallCounts: stalls
        )
    }
    #endif
}
