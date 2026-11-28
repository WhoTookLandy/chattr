import Foundation

/// Rewrites a Twitch HLS master playlist so every variant media playlist URI
/// routes through the local LL-HLS proxy while keeping `#EXT-X-MEDIA`,
/// `#EXT-X-STREAM-INF`, codecs, resolutions, and bandwidths intact for
/// `AVPlayer`'s native ABR and `Max Quality` caps.
enum TwitchMasterPlaylistRewriter {
    static func rewrite(
        text: String,
        relativeTo masterURL: URL,
        rewriteVariant: (URL) -> URL
    ) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var output: [String] = []
        output.reserveCapacity(lines.count)

        var expectVariantURI = false
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if expectVariantURI, !line.isEmpty, !line.hasPrefix("#") {
                expectVariantURI = false
                if let resolved = URL(string: line, relativeTo: masterURL)?.absoluteURL {
                    output.append(rewriteVariant(resolved).absoluteString)
                } else {
                    output.append(line)
                }
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                expectVariantURI = true
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }
}

/// One finalized LL-HLS partial segment ready to be advertised in a rewritten
/// media playlist.
struct LLHLSPartDescriptor: Equatable, Sendable {
    let partIndex: Int
    let duration: Double
    let isIndependent: Bool
    let uri: String
}

/// Live-edge partial segment state for one media sequence number (`msn`),
/// either still streaming (`isComplete == false`) or already finished from a
/// `#EXT-X-TWITCH-PREFETCH` stream (`isComplete == true`).
struct LLHLSSegmentParts: Equatable, Sendable {
    let msn: Int
    let parts: [LLHLSPartDescriptor]
    let isComplete: Bool
    /// Full segment URI used when promoting a completed prefetch segment ahead
    /// of Twitch's upstream playlist refresh.
    let segmentURI: String
    /// Total duration of all parts in this segment.
    var totalDuration: Double {
        parts.reduce(0) { $0 + $1.duration }
    }
}

/// Parsed representation of a Twitch HLS media playlist, plus pure RFC 8216bis
/// Apple LL-HLS rendering.
struct TwitchMediaPlaylist: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let msn: Int
        let duration: Double
        let title: String
        let programDateTime: String?
        let hasDiscontinuityBefore: Bool
        let mapLineBefore: String?
        let mapURIBefore: URL?
        let dateRangeLinesBefore: [String]
        let uri: String
    }

    /// Apple LL-HLS `PART-TARGET` we advertise (must be `>=` every part's
    /// actual duration and stay constant across reloads; ordinary dependent
    /// parts target `>= 85%` of this = `>= 0.476s`, matching 5 × ~100ms Twitch
    /// CMAF chunks ≈ 0.500–0.533s).
    static let partTargetDuration: Double = 0.560
    /// Apple LL-HLS `PART-HOLD-BACK` (strictly `>= 3 × PART-TARGET` per
    /// RFC 8216bis §4.4.3.8 for `AVPlayer` stability).
    static let partHoldBack: Double = 1.680

    let version: Int
    let declaredTargetDuration: Int
    let mediaSequence: Int
    let discontinuitySequence: Int?
    let segments: [Segment]
    let prefetchURIs: [URL]
    let isEndList: Bool

    /// Most recent `#EXT-X-MAP` URI declared in the playlist (fMP4 init segment).
    var latestMapURL: URL? {
        segments.reversed().compactMap(\.mapURIBefore).first
    }

    var lastFinalizedMSN: Int? {
        segments.last?.msn
    }

    /// True when this playlist is a live fMP4/CMAF feed with Twitch prefetch
    /// hints that can be translated into Apple LL-HLS partial segments.
    var supportsLLHLS: Bool {
        guard !isEndList, latestMapURL != nil, !prefetchURIs.isEmpty else { return false }
        guard let last = segments.last else { return false }
        // Confirm segments are fMP4 (.mp4), not legacy MPEG-TS (.ts).
        let path = URL(string: last.uri)?.path.lowercased() ?? last.uri.lowercased()
        return path.hasSuffix(".mp4")
    }

    /// Parses a raw Twitch media `.m3u8` string.
    static func parse(_ text: String, relativeTo playlistURL: URL) -> TwitchMediaPlaylist {
        let lines = text.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var version = 6
        var declaredTargetDuration = 6
        var mediaSequence = 0
        var discontinuitySequence: Int?
        var isEndList = false
        var segments: [Segment] = []
        var prefetchURIs: [URL] = []

        var pendingDuration: Double?
        var pendingTitle = ""
        var pendingProgramDateTime: String?
        var pendingDiscontinuity = false
        var pendingMapLine: String?
        var pendingMapURI: URL?
        var pendingDateRanges: [String] = []

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-VERSION:") {
                version = Int(line.dropFirst("#EXT-X-VERSION:".count)) ?? version
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                declaredTargetDuration = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? declaredTargetDuration
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? mediaSequence
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE:") {
                discontinuitySequence = Int(line.dropFirst("#EXT-X-DISCONTINUITY-SEQUENCE:".count))
            } else if line == "#EXT-X-ENDLIST" {
                isEndList = true
            } else if line == "#EXT-X-DISCONTINUITY" {
                pendingDiscontinuity = true
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let resolved = resolveMapLine(line, relativeTo: playlistURL)
                pendingMapLine = resolved.line
                pendingMapURI = resolved.uri
            } else if line.hasPrefix("#EXT-X-DATERANGE:") {
                pendingDateRanges.append(line)
            } else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                pendingProgramDateTime = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
            } else if line.hasPrefix("#EXTINF:") {
                let body = line.dropFirst("#EXTINF:".count)
                let rawValue: Double?
                if let comma = body.firstIndex(of: ",") {
                    rawValue = Double(body[..<comma])
                    pendingTitle = String(body[body.index(after: comma)...])
                } else {
                    rawValue = Double(body)
                    pendingTitle = ""
                }
                // Guard against non-finite / negative durations (`#EXTINF:inf`)
                // so downstream integer target-duration math can never trap.
                if let rawValue, rawValue.isFinite, rawValue >= 0, rawValue < 3600 {
                    pendingDuration = rawValue
                } else {
                    pendingDuration = 2.0
                }
            } else if line.hasPrefix("#EXT-X-TWITCH-PREFETCH:") {
                let raw = String(line.dropFirst("#EXT-X-TWITCH-PREFETCH:".count))
                if let resolved = URL(string: raw, relativeTo: playlistURL)?.absoluteURL {
                    prefetchURIs.append(resolved)
                }
            } else if !line.hasPrefix("#"), let duration = pendingDuration {
                let resolvedURI = URL(string: line, relativeTo: playlistURL)?.absoluteURL.absoluteString ?? line
                let msn = mediaSequence + segments.count
                segments.append(Segment(
                    msn: msn,
                    duration: duration,
                    title: pendingTitle,
                    programDateTime: pendingProgramDateTime,
                    hasDiscontinuityBefore: pendingDiscontinuity,
                    mapLineBefore: pendingMapLine,
                    mapURIBefore: pendingMapURI,
                    dateRangeLinesBefore: pendingDateRanges,
                    uri: resolvedURI
                ))
                pendingDuration = nil
                pendingTitle = ""
                pendingProgramDateTime = nil
                pendingDiscontinuity = false
                pendingMapLine = nil
                pendingMapURI = nil
                pendingDateRanges.removeAll(keepingCapacity: true)
            }
        }

        return TwitchMediaPlaylist(
            version: version,
            declaredTargetDuration: declaredTargetDuration,
            mediaSequence: mediaSequence,
            discontinuitySequence: discontinuitySequence,
            segments: segments,
            prefetchURIs: prefetchURIs,
            isEndList: isEndList
        )
    }

    /// Renders a spec-compliant HLS / Apple LL-HLS media playlist.
    ///
    /// - Parameters:
    ///   - segmentPartsByMSN: Partial-segment state keyed by MSN (covers both
    ///     recent finalized segments and live prefetch segments).
    ///   - pinnedSegmentURIs: Stable `/seg/` URIs for MSNs that were previously
    ///     promoted ahead of Twitch's playlist, so an MSN's advertised URI
    ///     never changes once Twitch finalizes it (RFC 8216bis).
    ///   - preloadHintURI: Next upcoming `#EXT-X-PRELOAD-HINT` URI when a live
    ///     prefetch segment is currently streaming.
    func renderLLHLS(
        segmentPartsByMSN: [Int: LLHLSSegmentParts] = [:],
        pinnedSegmentURIs: [Int: String] = [:],
        preloadHintURI: String? = nil
    ) -> String {
        // Collect any completed prefetch segments contiguous with our upstream
        // tail so we can promote them ahead of Twitch's playlist poll.
        var promotedSegments: [Segment] = []
        if let baseLast = segments.last {
            var nextMSN = baseLast.msn + 1
            var prevDateTime = baseLast.programDateTime
            var prevDuration = baseLast.duration

            while let ready = segmentPartsByMSN[nextMSN], ready.isComplete, !ready.parts.isEmpty {
                let extrapolatedDate = Self.advanceProgramDateTime(prevDateTime, by: prevDuration)
                let duration = max(0.1, ready.totalDuration)
                promotedSegments.append(Segment(
                    msn: nextMSN,
                    duration: duration,
                    title: "live",
                    programDateTime: extrapolatedDate,
                    hasDiscontinuityBefore: false,
                    mapLineBefore: nil,
                    mapURIBefore: nil,
                    dateRangeLinesBefore: [],
                    uri: pinnedSegmentURIs[nextMSN] ?? ready.segmentURI
                ))
                prevDateTime = extrapolatedDate
                prevDuration = duration
                nextMSN += 1
            }
        }

        let allFinalized = segments + promotedSegments
        let lastFinalizedMSN = allFinalized.last?.msn ?? (mediaSequence - 1)

        // Identify the single in-progress segment right after `lastFinalizedMSN`.
        let activeMSN = lastFinalizedMSN + 1
        let activePartial = segmentPartsByMSN[activeMSN].flatMap { !$0.isComplete ? $0 : nil }

        // Only emit LL-HLS server-control + part-inf when we actually have at
        // least one partial segment or preload hint to advertise.
        let recentFinalizedPartMSNs: Set<Int> = Set(
            allFinalized.suffix(3).map(\.msn).filter { msn in
                guard let info = segmentPartsByMSN[msn] else { return false }
                return !info.parts.isEmpty
            }
        )
        let hasAnyParts = !recentFinalizedPartMSNs.isEmpty || (activePartial?.parts.isEmpty == false)
        let emitLLHLS = !isEndList && hasAnyParts

        // Keep `EXT-X-TARGETDURATION` stable across reloads (RFC 8216bis: must
        // not change mid-stream even when 5.5–6s ad segments enter the window).
        // In LL-HLS mode `AVPlayer` uses `PART-HOLD-BACK` (1.68s) rather than
        // `3 × TARGETDURATION`.
        let finiteDurations = allFinalized.map(\.duration).filter { $0.isFinite && $0 >= 0 && $0 < 3600 }
        let maxSegmentCeil = finiteDurations.max().flatMap { Int(exactly: ceil($0)) } ?? 2
        let stableTargetDuration = max(2, declaredTargetDuration, maxSegmentCeil)
        let holdBack = max(6.0, Double(stableTargetDuration) * 3.0)

        // Ensure PART-TARGET is never exceeded by any emitted part.
        let allEmittedPartDurations: [Double] = recentFinalizedPartMSNs.flatMap {
            segmentPartsByMSN[$0]?.parts.map(\.duration) ?? []
        } + (activePartial?.parts.map(\.duration) ?? [])
        let maxPartDur = allEmittedPartDurations.filter(\.isFinite).max() ?? 0
        let effectivePartTarget = max(Self.partTargetDuration, maxPartDur)
        let effectivePartHoldBack = max(Self.partHoldBack, effectivePartTarget * 3.0)

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(max(version, emitLLHLS ? 7 : 6))",
            "#EXT-X-TARGETDURATION:\(stableTargetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
        ]
        if let discontinuitySequence {
            lines.append("#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuitySequence)")
        }

        if emitLLHLS {
            lines.append(
                "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=\(Self.format3(effectivePartHoldBack)),HOLD-BACK=\(Self.format3(holdBack))"
            )
            lines.append("#EXT-X-PART-INF:PART-TARGET=\(Self.format3(effectivePartTarget))")
        } else if !isEndList {
            lines.append("#EXT-X-SERVER-CONTROL:HOLD-BACK=\(Self.format3(holdBack))")
        }

        for segment in allFinalized {
            if segment.hasDiscontinuityBefore {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            for dateRange in segment.dateRangeLinesBefore {
                lines.append(dateRange)
            }
            if let mapLine = segment.mapLineBefore {
                lines.append(mapLine)
            }
            if let pdt = segment.programDateTime {
                lines.append("#EXT-X-PROGRAM-DATE-TIME:\(pdt)")
            }
            if emitLLHLS, recentFinalizedPartMSNs.contains(segment.msn),
               let partInfo = segmentPartsByMSN[segment.msn] {
                for part in partInfo.parts {
                    lines.append(Self.partLine(part))
                }
            }
            lines.append("#EXTINF:\(Self.format3(segment.duration)),\(segment.title)")
            lines.append(pinnedSegmentURIs[segment.msn] ?? segment.uri)
        }

        if emitLLHLS {
            if let activePartial {
                for part in activePartial.parts {
                    lines.append(Self.partLine(part))
                }
            }
            if let preloadHintURI {
                lines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(preloadHintURI)\"")
            }
        }

        if isEndList {
            lines.append("#EXT-X-ENDLIST")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func partLine(_ part: LLHLSPartDescriptor) -> String {
        let ind = part.isIndependent ? ",INDEPENDENT=YES" : ""
        return "#EXT-X-PART:DURATION=\(format3(part.duration)),URI=\"\(part.uri)\"\(ind)"
    }

    private static func format3(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func resolveMapLine(_ line: String, relativeTo baseURL: URL) -> (line: String, uri: URL?) {
        guard let uriStart = line.range(of: "URI=\"") else { return (line, nil) }
        let afterStart = line[uriStart.upperBound...]
        guard let uriEnd = afterStart.firstIndex(of: "\"") else { return (line, nil) }
        let rawURI = String(afterStart[..<uriEnd])
        guard let resolved = URL(string: rawURI, relativeTo: baseURL)?.absoluteURL else {
            return (line, nil)
        }
        let rewritten = String(line[..<uriStart.upperBound]) + resolved.absoluteString + String(line[uriEnd...])
        return (rewritten, resolved)
    }

    static func advanceProgramDateTime(_ isoString: String?, by seconds: Double) -> String? {
        guard let isoString, seconds.isFinite else { return nil }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        guard let date = (try? Date(isoString, strategy: fractional))
            ?? (try? Date(isoString, strategy: whole))
        else { return nil }
        // Advance in integer milliseconds so IEEE-754 floor truncation in
        // `ISO8601FormatStyle` never turns `.693 + 2.0s` into `.692`.
        let totalMs = Int64((date.timeIntervalSince1970 * 1000.0).rounded())
            + Int64((seconds * 1000.0).rounded())
        let wholeSeconds = totalMs >= 0 ? totalMs / 1000 : ((totalMs - 999) / 1000)
        let millis = Int(totalMs - wholeSeconds * 1000)
        let prefix = Date(timeIntervalSince1970: TimeInterval(wholeSeconds)).formatted(whole)
        guard prefix.hasSuffix("Z") else {
            return Date(timeIntervalSince1970: Double(totalMs) / 1000.0).formatted(fractional)
        }
        return String(prefix.dropLast()) + String(format: ".%03dZ", locale: Locale(identifier: "en_US_POSIX"), millis)
    }
}
