import Foundation

/// Track metadata parsed from an fMP4 / CMAF initialization segment
/// (`#EXT-X-MAP`, i.e. `ftyp` + `moov`).
struct CMAFInitInfo: Equatable, Sendable {
    /// `trackID -> timescale` from each `trak`'s `mdhd` box.
    let trackTimescales: [UInt32: UInt32]
    /// Track ID whose `hdlr` box declares handler type `"vide"`, if any.
    let videoTrackID: UInt32?
    /// Track ID used to compute chunk duration (`videoTrackID` when present,
    /// otherwise the first track — e.g. audio track `1` in `audio_only`).
    let primaryTrackID: UInt32?

    var isAudioOnly: Bool { videoTrackID == nil }

    var primaryTimescale: UInt32? {
        guard let primaryTrackID else { return nil }
        return trackTimescales[primaryTrackID]
    }

    static func parse(initSegment data: Data) -> CMAFInitInfo? {
        var timescales: [UInt32: UInt32] = [:]
        var videoTrackID: UInt32?
        var firstTrackID: UInt32?

        for box in MP4BoxScanner.topLevelBoxes(in: data) where box.type == "moov" {
            for moovChild in MP4BoxScanner.children(of: box, in: data) where moovChild.type == "trak" {
                var trackID: UInt32?
                var timescale: UInt32?
                var isVideo = false

                for trakChild in MP4BoxScanner.children(of: moovChild, in: data) {
                    if trakChild.type == "tkhd" {
                        trackID = parseTrackID(fromTkhd: trakChild, in: data)
                    } else if trakChild.type == "mdia" {
                        for mdiaChild in MP4BoxScanner.children(of: trakChild, in: data) {
                            if mdiaChild.type == "mdhd" {
                                timescale = parseTimescale(fromMdhd: mdiaChild, in: data)
                            } else if mdiaChild.type == "hdlr" {
                                if parseHandlerType(fromHdlr: mdiaChild, in: data) == "vide" {
                                    isVideo = true
                                }
                            }
                        }
                    }
                }

                if let trackID {
                    if firstTrackID == nil { firstTrackID = trackID }
                    if let timescale, timescale > 0 {
                        timescales[trackID] = timescale
                    }
                    if isVideo {
                        videoTrackID = trackID
                    }
                }
            }
        }

        guard !timescales.isEmpty else { return nil }
        return CMAFInitInfo(
            trackTimescales: timescales,
            videoTrackID: videoTrackID,
            primaryTrackID: videoTrackID ?? firstTrackID
        )
    }

    private static func parseTrackID(fromTkhd box: MP4Box, in data: Data) -> UInt32? {
        guard box.payloadLength >= 20 else { return nil }
        let version = data[box.payloadOffset]
        // version 0: 4 (ver+flags) + 4 (creation) + 4 (modification) = +12
        // version 1: 4 (ver+flags) + 8 (creation) + 8 (modification) = +20
        let idOffset = version == 1 ? box.payloadOffset + 20 : box.payloadOffset + 12
        guard idOffset + 4 <= box.endOffset else { return nil }
        return MP4BoxScanner.readUInt32(data, at: idOffset)
    }

    private static func parseTimescale(fromMdhd box: MP4Box, in data: Data) -> UInt32? {
        guard box.payloadLength >= 20 else { return nil }
        let version = data[box.payloadOffset]
        // version 0: 4 (ver+flags) + 4 (creation) + 4 (modification) = +12
        // version 1: 4 (ver+flags) + 8 (creation) + 8 (modification) = +20
        let tsOffset = version == 1 ? box.payloadOffset + 20 : box.payloadOffset + 12
        guard tsOffset + 4 <= box.endOffset else { return nil }
        return MP4BoxScanner.readUInt32(data, at: tsOffset)
    }

    private static func parseHandlerType(fromHdlr box: MP4Box, in data: Data) -> String? {
        // 4 (ver+flags) + 4 (pre_defined) + 4 (handler_type)
        let typeOffset = box.payloadOffset + 8
        guard typeOffset + 4 <= box.endOffset else { return nil }
        return MP4BoxScanner.readFourCC(data, at: typeOffset)
    }
}

/// One complete CMAF chunk (`[leading metadata boxes] + moof + mdat`) sliced
/// from an incoming fMP4 stream without modifying any bytes.
struct CMAFChunk: Equatable, Sendable {
    let data: Data
    let duration: Double
    let isIndependent: Bool
}

/// Incremental ISO BMFF top-level box framer that turns streaming HTTP bytes
/// from a Twitch `#EXT-X-TWITCH-PREFETCH` `.mp4` segment into standalone
/// `CMAFChunk`s as each `moof` + `mdat` pair completes.
struct CMAFChunkFramer: Sendable {
    static let fallbackChunkDuration: Double = 0.1

    private let initInfo: CMAFInitInfo?
    private var buffer = Data()
    private var pendingPrefix = Data()
    private var pendingMoof: Data?
    private var pendingMoofBoxDuration: Double = fallbackChunkDuration
    private var pendingMoofIndependent = false
    private var emittedChunkCount = 0

    init(initInfo: CMAFInitInfo? = nil) {
        self.initInfo = initInfo
    }

    mutating func append(_ incoming: Data) -> [CMAFChunk] {
        guard !incoming.isEmpty else { return [] }
        buffer.append(incoming)

        var emitted: [CMAFChunk] = []
        var cursor = buffer.startIndex

        while cursor + 8 <= buffer.endIndex {
            let rawSize = MP4BoxScanner.readUInt32(buffer, at: cursor)
            let headerSize: Int
            let boxSize: Int

            if rawSize == 1 {
                guard cursor + 16 <= buffer.endIndex else { break }
                let largeSize = MP4BoxScanner.readUInt64(buffer, at: cursor + 8)
                guard largeSize >= 16, largeSize <= UInt64(Int.max) else {
                    // Malformed stream: drop buffered remainder to avoid spinning.
                    buffer.removeAll(keepingCapacity: false)
                    return emitted
                }
                headerSize = 16
                boxSize = Int(largeSize)
            } else if rawSize >= 8 {
                headerSize = 8
                boxSize = Int(rawSize)
            } else {
                // Size 0 (extends to EOF) or invalid < 8 cannot be framed incrementally.
                buffer.removeAll(keepingCapacity: false)
                return emitted
            }

            guard cursor + boxSize <= buffer.endIndex else { break }
            let boxEnd = cursor + boxSize
            let type = MP4BoxScanner.readFourCC(buffer, at: cursor + 4)
            let boxData = Data(buffer[cursor..<boxEnd])

            switch type {
            case "moof":
                // Parse duration + IDR/sync flag from this moof box.
                let moofBox = MP4Box(
                    type: type,
                    startOffset: boxData.startIndex,
                    payloadOffset: boxData.startIndex + headerSize,
                    endOffset: boxData.endIndex
                )
                let parsed = Self.inspectMoof(
                    moofBox,
                    in: boxData,
                    initInfo: initInfo,
                    isFirstChunk: emittedChunkCount == 0
                )
                pendingMoof = boxData
                pendingMoofBoxDuration = parsed.duration
                pendingMoofIndependent = parsed.isIndependent

            case "mdat":
                if let moof = pendingMoof {
                    var chunkBytes = Data()
                    chunkBytes.reserveCapacity(pendingPrefix.count + moof.count + boxData.count)
                    if !pendingPrefix.isEmpty {
                        chunkBytes.append(pendingPrefix)
                        pendingPrefix.removeAll(keepingCapacity: true)
                    }
                    chunkBytes.append(moof)
                    chunkBytes.append(boxData)
                    pendingMoof = nil
                    emittedChunkCount += 1
                    emitted.append(CMAFChunk(
                        data: chunkBytes,
                        duration: pendingMoofBoxDuration,
                        isIndependent: pendingMoofIndependent
                    ))
                } else {
                    // Orphan mdat before any moof: ignore safely.
                    pendingPrefix.removeAll(keepingCapacity: true)
                }

            default:
                // Attach leading metadata boxes (emsg, styp, sidx, prft) to the
                // next moof+mdat pair so event messages are never lost.
                pendingPrefix.append(boxData)
            }

            cursor = boxEnd
        }

        if cursor > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<cursor)
        }
        return emitted
    }

    /// Extracts fragment duration (in seconds) and whether the fragment begins
    /// with an independently decodable sample from a `moof` box.
    private static func inspectMoof(
        _ moof: MP4Box,
        in data: Data,
        initInfo: CMAFInitInfo?,
        isFirstChunk: Bool
    ) -> (duration: Double, isIndependent: Bool) {
        let primaryTrackID = initInfo?.primaryTrackID
        let isAudioOnly = initInfo?.isAudioOnly ?? false

        var chosenDuration: Double?
        var chosenIndependent: Bool?
        var fallbackDuration: Double?

        for traf in MP4BoxScanner.children(of: moof, in: data) where traf.type == "traf" {
            var trackID: UInt32?
            var defaultSampleDuration: UInt32 = 0
            var defaultSampleFlags: UInt32?
            var totalTicks: UInt64 = 0
            var firstSampleFlags: UInt32?

            for child in MP4BoxScanner.children(of: traf, in: data) {
                if child.type == "tfhd" {
                    let tfhd = parseTfhd(child, in: data)
                    trackID = tfhd.trackID
                    defaultSampleDuration = tfhd.defaultSampleDuration
                    defaultSampleFlags = tfhd.defaultSampleFlags
                } else if child.type == "trun" {
                    let trun = parseTrun(child, in: data, defaultSampleDuration: defaultSampleDuration)
                    totalTicks += trun.totalDuration
                    if firstSampleFlags == nil {
                        firstSampleFlags = trun.firstSampleFlags
                    }
                }
            }

            guard let trackID, totalTicks > 0 else { continue }
            let timescale = initInfo?.trackTimescales[trackID]
            let durationSeconds: Double? = timescale.map { Double(totalTicks) / Double($0) }

            let effectiveFlags = firstSampleFlags ?? defaultSampleFlags
            // ISO 14496-12 §8.8.3.1: bit 16 (0x0001_0000) is `sample_is_non_sync_sample`.
            // When 0, the first sample is a sync (IDR) frame.
            let independent: Bool
            if isAudioOnly {
                independent = true
            } else if let effectiveFlags {
                independent = (effectiveFlags & 0x0001_0000) == 0
            } else {
                independent = isFirstChunk
            }

            if primaryTrackID == nil || trackID == primaryTrackID {
                if let durationSeconds, durationSeconds > 0 {
                    chosenDuration = durationSeconds
                    chosenIndependent = independent
                    if trackID == primaryTrackID { break }
                }
            } else if fallbackDuration == nil, let durationSeconds, durationSeconds > 0 {
                fallbackDuration = durationSeconds
            }
        }

        let finalDuration = chosenDuration ?? fallbackDuration ?? fallbackChunkDuration
        let finalIndependent = chosenIndependent ?? (isAudioOnly || isFirstChunk)
        return (finalDuration, finalIndependent)
    }

    private static func parseTfhd(
        _ box: MP4Box,
        in data: Data
    ) -> (trackID: UInt32?, defaultSampleDuration: UInt32, defaultSampleFlags: UInt32?) {
        guard box.payloadLength >= 8 else { return (nil, 0, nil) }
        let flags = MP4BoxScanner.readUInt32(data, at: box.payloadOffset) & 0x00FF_FFFF
        let trackID = MP4BoxScanner.readUInt32(data, at: box.payloadOffset + 4)
        var offset = box.payloadOffset + 8

        if (flags & 0x000001) != 0 { offset += 8 } // base_data_offset
        if (flags & 0x000002) != 0 { offset += 4 } // sample_description_index

        var defaultDuration: UInt32 = 0
        if (flags & 0x000008) != 0 {
            guard offset + 4 <= box.endOffset else { return (trackID, 0, nil) }
            defaultDuration = MP4BoxScanner.readUInt32(data, at: offset)
            offset += 4
        }
        if (flags & 0x000010) != 0 { offset += 4 } // default_sample_size

        var defaultFlags: UInt32?
        if (flags & 0x000020) != 0, offset + 4 <= box.endOffset {
            defaultFlags = MP4BoxScanner.readUInt32(data, at: offset)
        }
        return (trackID, defaultDuration, defaultFlags)
    }

    private static func parseTrun(
        _ box: MP4Box,
        in data: Data,
        defaultSampleDuration: UInt32
    ) -> (totalDuration: UInt64, firstSampleFlags: UInt32?) {
        guard box.payloadLength >= 8 else { return (0, nil) }
        let flags = MP4BoxScanner.readUInt32(data, at: box.payloadOffset) & 0x00FF_FFFF
        let sampleCount = MP4BoxScanner.readUInt32(data, at: box.payloadOffset + 4)
        var offset = box.payloadOffset + 8

        if (flags & 0x000001) != 0 { offset += 4 } // data_offset

        var firstSampleFlags: UInt32?
        if (flags & 0x000004) != 0 {
            guard offset + 4 <= box.endOffset else { return (0, nil) }
            firstSampleFlags = MP4BoxScanner.readUInt32(data, at: offset)
            offset += 4
        }

        let hasDuration = (flags & 0x000100) != 0
        let hasSize = (flags & 0x000200) != 0
        let hasSampleFlags = (flags & 0x000400) != 0
        let hasCTO = (flags & 0x000800) != 0

        if !hasDuration && !hasSampleFlags {
            return (UInt64(sampleCount) * UInt64(defaultSampleDuration), firstSampleFlags)
        }

        var total: UInt64 = 0
        for index in 0..<sampleCount {
            if hasDuration {
                guard offset + 4 <= box.endOffset else { break }
                total += UInt64(MP4BoxScanner.readUInt32(data, at: offset))
                offset += 4
            } else {
                total += UInt64(defaultSampleDuration)
            }
            if hasSize { offset += 4 }
            if hasSampleFlags {
                guard offset + 4 <= box.endOffset else { break }
                if index == 0, firstSampleFlags == nil {
                    firstSampleFlags = MP4BoxScanner.readUInt32(data, at: offset)
                }
                offset += 4
            }
            if hasCTO { offset += 4 }
        }
        return (total, firstSampleFlags)
    }
}

// MARK: - Low-level ISO BMFF box scanning

struct MP4Box: Equatable, Sendable {
    let type: String
    let startOffset: Int
    let payloadOffset: Int
    let endOffset: Int

    var payloadLength: Int { max(0, endOffset - payloadOffset) }
}

enum MP4BoxScanner {
    static func topLevelBoxes(in data: Data) -> [MP4Box] {
        boxes(in: data, range: data.startIndex..<data.endIndex)
    }

    static func children(of parent: MP4Box, in data: Data) -> [MP4Box] {
        boxes(in: data, range: parent.payloadOffset..<parent.endOffset)
    }

    static func boxes(in data: Data, range: Range<Int>) -> [MP4Box] {
        var result: [MP4Box] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let rawSize = readUInt32(data, at: cursor)
            let headerSize: Int
            let boxSize: Int

            if rawSize == 1 {
                guard cursor + 16 <= range.upperBound else { break }
                let large = readUInt64(data, at: cursor + 8)
                guard large >= 16, large <= UInt64(range.upperBound - cursor) else { break }
                headerSize = 16
                boxSize = Int(large)
            } else if rawSize == 0 {
                headerSize = 8
                boxSize = range.upperBound - cursor
            } else if rawSize >= 8 {
                headerSize = 8
                boxSize = Int(rawSize)
            } else {
                break
            }

            guard cursor + boxSize <= range.upperBound else { break }
            let type = readFourCC(data, at: cursor + 4)
            result.append(MP4Box(
                type: type,
                startOffset: cursor,
                payloadOffset: cursor + headerSize,
                endOffset: cursor + boxSize
            ))
            cursor += boxSize
        }
        return result
    }

    static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        (UInt32(data[index]) << 24)
            | (UInt32(data[index + 1]) << 16)
            | (UInt32(data[index + 2]) << 8)
            | UInt32(data[index + 3])
    }

    static func readUInt64(_ data: Data, at index: Int) -> UInt64 {
        (UInt64(readUInt32(data, at: index)) << 32) | UInt64(readUInt32(data, at: index + 4))
    }

    static func readFourCC(_ data: Data, at index: Int) -> String {
        let bytes = [data[index], data[index + 1], data[index + 2], data[index + 3]]
        return String(decoding: bytes, as: UTF8.self)
    }
}
