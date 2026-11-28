import Foundation
import Core
import os

private let llhlsLogger = AppLogger.make("Features.LLHLS")

/// Shared streaming HTTP client built on a single `URLSession` + `URLSessionDataDelegate`
/// so Twitch's chunked-transfer `#EXT-X-TWITCH-PREFETCH` `.mp4` responses yield
/// `Data` buffers immediately as CMAF chunks arrive without per-byte `AsyncBytes`
/// overhead or leaked `URLSession` instances.
final class ChunkedHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ChunkedHTTPClient()

    private struct StreamState {
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        var receivedStatus = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: [Int: StreamState]())
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 12
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    enum HTTPStreamError: Error {
        case badStatus(Int)
    }

    func fetchData(from url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    func streamBytes(from url: URL) -> AsyncThrowingStream<Data, any Error> {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        return AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            let taskID = task.taskIdentifier
            lock.withLock { $0[taskID] = StreamState(continuation: continuation) }

            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = $0.removeValue(forKey: taskID) }
                task.cancel()
            }
            task.resume()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if (200...299).contains(status) {
            lock.withLock { $0[dataTask.taskIdentifier]?.receivedStatus = true }
            completionHandler(.allow)
        } else {
            let state = lock.withLock { $0.removeValue(forKey: dataTask.taskIdentifier) }
            state?.continuation.finish(throwing: HTTPStreamError.badStatus(status))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        let continuation = lock.withLock { $0[dataTask.taskIdentifier]?.continuation }
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let state = lock.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        guard let state else { return }
        if let error {
            state.continuation.finish(throwing: error)
        } else {
            state.continuation.finish()
        }
    }
}

/// Manages one Twitch HLS variant playlist, streaming its `#EXT-X-TWITCH-PREFETCH`
/// fMP4 segments incrementally into Apple LL-HLS partial segments (`#EXT-X-PART`),
/// serving blocking playlist reloads (`_HLS_msn` / `_HLS_part`) and preloaded
/// part fetches for `AVPlayer`.
actor LLHLSVariantTrack {
    struct CachedPart: Sendable {
        let index: Int
        let duration: Double
        let isIndependent: Bool
        let data: Data
    }

    private struct SegmentBuffer {
        let msn: Int
        let upstreamURL: URL
        var parts: [CachedPart] = []
        var pendingData = Data()
        var pendingDuration: Double = 0
        var pendingIndependent = false
        var isComplete = false
        var didFail = false

        var fullData: Data {
            var out = Data()
            out.reserveCapacity(parts.reduce(0) { $0 + $1.data.count })
            for part in parts {
                out.append(part.data)
            }
            return out
        }

        mutating func appendChunk(_ chunk: CMAFChunk) -> Bool {
            var flushed = false
            // Never exceed PART-TARGET (0.600s): flush accumulated chunks first
            // if adding this chunk would push past `maxPartDuration`.
            if !pendingData.isEmpty, pendingDuration + chunk.duration > LLHLSVariantTrack.maxPartDuration {
                flushPending()
                flushed = true
            }
            if pendingData.isEmpty {
                pendingIndependent = chunk.isIndependent
            }
            pendingData.append(chunk.data)
            pendingDuration += chunk.duration
            if pendingDuration >= LLHLSVariantTrack.targetPartDuration {
                flushPending()
                flushed = true
            }
            return flushed
        }

        mutating func finish() {
            if !pendingData.isEmpty {
                flushPending()
            }
            isComplete = true
        }

        private mutating func flushPending() {
            let part = CachedPart(
                index: parts.count,
                duration: max(0.01, pendingDuration),
                isIndependent: pendingIndependent,
                data: pendingData
            )
            parts.append(part)
            pendingData = Data()
            pendingDuration = 0
            pendingIndependent = false
        }
    }

    private struct PlaylistWaiter {
        let requestedMSN: Int
        let requestedPart: Int?
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct PartWaiter {
        let msn: Int
        let partIndex: Int
        let continuation: CheckedContinuation<Data?, Never>
    }

    /// Coalesce ~100ms Twitch CMAF chunks into ~0.40s LL-HLS parts (4–5 parts
    /// per 2s segment), staying strictly under `TwitchMediaPlaylist.partTargetDuration` (0.60s).
    static let targetPartDuration: Double = 0.38
    static let maxPartDuration: Double = 0.58
    /// Maximum time a blocking playlist reload or preload hint request waits.
    private static let blockingTimeout: Duration = .seconds(4)
    /// Maximum time the very first playlist fetch waits to prime initial parts
    /// so `AVPlayer` enters LL-HLS mode immediately without stalling startup.
    private static let coldStartPrimeTimeout: Duration = .milliseconds(900)
    /// How often the upstream Twitch media playlist is polled while active.
    private static let upstreamPollInterval: Duration = .milliseconds(1000)
    /// Stop background polling after this long with no `AVPlayer` requests.
    private static let idleShutdownDelay: Duration = .seconds(15)
    /// Retain only the newest N MSNs' part buffers in memory.
    private static let maxRetainedSegments = 6

    let id: String
    let upstreamURL: URL
    private let client: ChunkedHTTPClient

    private var latestPlaylist: TwitchMediaPlaylist?
    private var initInfo: CMAFInitInfo?
    private var fetchedMapURL: URL?
    private var segmentBuffers: [Int: SegmentBuffer] = [:]
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]
    private var urlToMSN: [String: Int] = [:]

    private var playlistWaiters: [UUID: PlaylistWaiter] = [:]
    private var partWaiters: [UUID: PartWaiter] = [:]
    private var pollTask: Task<Void, Never>?
    private var lastClientActivity = ContinuousClock.now
    private var isStopped = false

    init(id: String, upstreamURL: URL, client: ChunkedHTTPClient = .shared) {
        self.id = id
        self.upstreamURL = upstreamURL
        self.client = client
    }

    var isIdle: Bool {
        ContinuousClock.now - lastClientActivity > Self.idleShutdownDelay
    }

    func stop() {
        isStopped = true
        pollTask?.cancel()
        pollTask = nil
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        for waiter in playlistWaiters.values {
            waiter.continuation.resume()
        }
        playlistWaiters.removeAll()
        for waiter in partWaiters.values {
            waiter.continuation.resume(returning: nil)
        }
        partWaiters.removeAll()
        segmentBuffers.removeAll()
        urlToMSN.removeAll()
    }

    // MARK: - HTTP endpoints

    /// Serves a media playlist request, supporting Apple LL-HLS blocking reloads
    /// (`_HLS_msn` and optional `_HLS_part`).
    func playlistResponse(
        requestedMSN: Int?,
        requestedPart: Int?,
        basePartPrefix: String,
        baseSegmentPrefix: String
    ) async throws -> String {
        guard !isStopped else { throw CancellationError() }
        lastClientActivity = ContinuousClock.now
        ensurePolling()

        if latestPlaylist == nil {
            try await refreshUpstream()
            // On cold start, briefly let the first prefetch emit enough parts
            // to fill PART-HOLD-BACK so AVPlayer starts straight in LL-HLS mode.
            if let playlist = latestPlaylist, playlist.supportsLLHLS, !hasEnoughPartsForColdStart() {
                await waitForColdStartPrime()
            }
        } else if let requestedMSN {
            if !isPlaylistRequestSatisfied(msn: requestedMSN, part: requestedPart) {
                // Kick an immediate upstream refresh if the requested MSN isn't
                // even tracked as an active prefetch yet.
                if segmentBuffers[requestedMSN] == nil {
                    try? await refreshUpstream()
                }
                if !isPlaylistRequestSatisfied(msn: requestedMSN, part: requestedPart) {
                    await waitForPlaylistUpdate(msn: requestedMSN, part: requestedPart)
                }
            }
        } else {
            // Non-blocking refresh (e.g. standard HLS fallback poll): fetch fresh upstream.
            try? await refreshUpstream()
        }

        guard let playlist = latestPlaylist else {
            throw ChunkedHTTPClient.HTTPStreamError.badStatus(503)
        }
        return render(
            playlist: playlist,
            basePartPrefix: basePartPrefix,
            baseSegmentPrefix: baseSegmentPrefix
        )
    }

    /// Serves one LL-HLS partial segment (blocking if it is the current
    /// `#EXT-X-PRELOAD-HINT` still arriving from Twitch's chunked prefetch).
    func partData(msn: Int, partIndex: Int) async -> Data? {
        guard !isStopped else { return nil }
        lastClientActivity = ContinuousClock.now
        ensurePolling()

        if let buffer = segmentBuffers[msn] {
            if partIndex < buffer.parts.count {
                return buffer.parts[partIndex].data
            }
            if buffer.isComplete || buffer.didFail {
                return nil
            }
        } else if let lastFinal = latestPlaylist?.lastFinalizedMSN, msn <= lastFinal {
            // Segment already passed without cached parts.
            return nil
        } else {
            // Maybe prefetch hasn't started yet; wait briefly for it to appear.
            try? await refreshUpstream()
            if let buffer = segmentBuffers[msn] {
                if partIndex < buffer.parts.count { return buffer.parts[partIndex].data }
                if buffer.isComplete || buffer.didFail { return nil }
            } else {
                return nil
            }
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                // Re-check inside actor isolation right before suspending.
                if let buffer = segmentBuffers[msn] {
                    if partIndex < buffer.parts.count {
                        continuation.resume(returning: buffer.parts[partIndex].data)
                        return
                    }
                    if buffer.isComplete || buffer.didFail {
                        continuation.resume(returning: nil)
                        return
                    }
                } else {
                    continuation.resume(returning: nil)
                    return
                }

                partWaiters[waiterID] = PartWaiter(
                    msn: msn,
                    partIndex: partIndex,
                    continuation: continuation
                )
                Task { [weak self] in
                    try? await Task.sleep(for: Self.blockingTimeout)
                    await self?.timeoutPartWaiter(waiterID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.timeoutPartWaiter(waiterID)
            }
        }
    }

    /// Serves a promoted full segment from memory if cached, or returns the
    /// upstream Twitch URL so the proxy can issue a `302 Found` redirect.
    func segmentResponse(msn: Int) -> (data: Data?, redirectURL: URL?) {
        lastClientActivity = ContinuousClock.now
        if let buffer = segmentBuffers[msn], buffer.isComplete, !buffer.parts.isEmpty {
            return (buffer.fullData, nil)
        }
        if let buffer = segmentBuffers[msn] {
            return (nil, buffer.upstreamURL)
        }
        if let seg = latestPlaylist?.segments.first(where: { $0.msn == msn }),
           let url = URL(string: seg.uri) {
            return (nil, url)
        }
        return (nil, nil)
    }

    // MARK: - Polling & Prefetch Ingestion

    private func ensurePolling() {
        guard !isStopped, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.upstreamPollInterval)
                guard !Task.isCancelled, let self else { return }
                let shouldContinue = await self.pollTick()
                if !shouldContinue { return }
            }
        }
    }

    private func pollTick() async -> Bool {
        guard !isStopped else { return false }
        if ContinuousClock.now - lastClientActivity > Self.idleShutdownDelay {
            stop()
            return false
        }
        try? await refreshUpstream()
        if latestPlaylist?.isEndList == true {
            pollTask = nil
            return false
        }
        return true
    }

    private func refreshUpstream() async throws {
        let (data, status) = try await client.fetchData(from: upstreamURL)
        guard (200...299).contains(status), let text = String(data: data, encoding: .utf8) else {
            throw ChunkedHTTPClient.HTTPStreamError.badStatus(status)
        }
        let parsed = TwitchMediaPlaylist.parse(text, relativeTo: upstreamURL)

        // Detect discontinuity or backwards media-sequence jump (e.g. ad break
        // splice): clear stale prefetch buffers so we never emit mismatched MSNs.
        if let previous = latestPlaylist {
            if parsed.mediaSequence < previous.mediaSequence
                || parsed.discontinuitySequence != previous.discontinuitySequence {
                resetPrefetchState()
            }
        }

        latestPlaylist = parsed

        // Fetch `#EXT-X-MAP` once (or whenever Twitch rotates the init map) so
        // `CMAFChunkFramer` knows exact track timescales and video/audio IDs.
        if let mapURL = parsed.latestMapURL, mapURL != fetchedMapURL {
            fetchedMapURL = mapURL
            if let (mapData, mapStatus) = try? await client.fetchData(from: mapURL),
               (200...299).contains(mapStatus),
               let info = CMAFInitInfo.parse(initSegment: mapData) {
                initInfo = info
            }
        }

        // Start streaming up to 2 `#EXT-X-TWITCH-PREFETCH` segments in parallel.
        if parsed.supportsLLHLS, let baseLastMSN = parsed.lastFinalizedMSN {
            for (offset, prefetchURL) in parsed.prefetchURIs.prefix(2).enumerated() {
                let expectedMSN = baseLastMSN + 1 + offset
                let key = prefetchURL.absoluteString
                // If already tracked under the same URL, keep its existing buffer/task.
                if let existingMSN = urlToMSN[key], existingMSN == expectedMSN {
                    continue
                }
                startPrefetch(msn: expectedMSN, url: prefetchURL)
            }
        }

        pruneOldBuffers()
        notifyAllWaiters()
    }

    private func startPrefetch(msn: Int, url: URL) {
        guard !isStopped, segmentBuffers[msn] == nil else { return }
        urlToMSN[url.absoluteString] = msn
        segmentBuffers[msn] = SegmentBuffer(msn: msn, upstreamURL: url)

        let info = initInfo
        let client = self.client
        prefetchTasks[msn] = Task { [weak self] in
            var framer = CMAFChunkFramer(initInfo: info)
            do {
                for try await data in client.streamBytes(from: url) {
                    guard !Task.isCancelled else { return }
                    let chunks = framer.append(data)
                    if !chunks.isEmpty {
                        await self?.ingestChunks(chunks, forMSN: msn)
                    }
                }
                guard !Task.isCancelled else { return }
                await self?.finishPrefetch(msn: msn, failed: false)
            } catch {
                guard !Task.isCancelled else { return }
                llhlsLogger.debug("Prefetch failed msn=\(msn): \(error.localizedDescription, privacy: .public)")
                await self?.finishPrefetch(msn: msn, failed: true)
            }
        }
    }

    private func ingestChunks(_ chunks: [CMAFChunk], forMSN msn: Int) {
        guard var buffer = segmentBuffers[msn], !buffer.isComplete else { return }
        var flushedAny = false
        for chunk in chunks {
            if buffer.appendChunk(chunk) {
                flushedAny = true
            }
        }
        segmentBuffers[msn] = buffer
        if flushedAny {
            notifyAllWaiters()
        }
    }

    private func finishPrefetch(msn: Int, failed: Bool) {
        prefetchTasks[msn] = nil
        guard var buffer = segmentBuffers[msn] else { return }
        if failed {
            buffer.didFail = true
        } else {
            buffer.finish()
        }
        segmentBuffers[msn] = buffer
        notifyAllWaiters()
    }

    private func resetPrefetchState() {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        segmentBuffers.removeAll()
        urlToMSN.removeAll()
    }

    private func pruneOldBuffers() {
        guard let latestMSN = effectiveLatestMSN else { return }
        let cutoff = latestMSN - Self.maxRetainedSegments
        for msn in Array(segmentBuffers.keys) where msn < cutoff {
            prefetchTasks[msn]?.cancel()
            prefetchTasks[msn] = nil
            if let removed = segmentBuffers.removeValue(forKey: msn) {
                urlToMSN[removed.upstreamURL.absoluteString] = nil
            }
        }
    }

    // MARK: - Playlist Rendering & Waiter Resolution

    private var effectiveFinalizedMSN: Int? {
        guard let baseLast = latestPlaylist?.lastFinalizedMSN else { return nil }
        var msn = baseLast
        while let next = segmentBuffers[msn + 1], next.isComplete, !next.parts.isEmpty {
            msn += 1
        }
        return msn
    }

    private var effectiveLatestMSN: Int? {
        let base = effectiveFinalizedMSN ?? -1
        let bufferedMax = segmentBuffers.keys.max() ?? -1
        let highest = max(base, bufferedMax)
        return highest >= 0 ? highest : nil
    }

    private func hasEnoughPartsForColdStart() -> Bool {
        guard let baseLast = latestPlaylist?.lastFinalizedMSN else { return false }
        var totalDuration: Double = 0
        var hasIndependent = false
        for msn in (baseLast + 1)...(baseLast + 2) {
            guard let buffer = segmentBuffers[msn] else { continue }
            for part in buffer.parts {
                totalDuration += part.duration
                if part.isIndependent { hasIndependent = true }
            }
        }
        return hasIndependent && totalDuration >= TwitchMediaPlaylist.partHoldBack
    }

    private func isPlaylistRequestSatisfied(msn: Int, part: Int?) -> Bool {
        if latestPlaylist?.isEndList == true { return true }
        if let finalized = effectiveFinalizedMSN, finalized >= msn { return true }
        if let buffer = segmentBuffers[msn] {
            if buffer.isComplete || buffer.didFail { return true }
            if let part, buffer.parts.count > part { return true }
        }
        return false
    }

    private func waitForColdStartPrime() async {
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if hasEnoughPartsForColdStart() {
                continuation.resume()
                return
            }
            // Wait for any part progress, resolved once `hasEnoughPartsForColdStart`
            // becomes true or after `coldStartPrimeTimeout`.
            playlistWaiters[waiterID] = PlaylistWaiter(
                requestedMSN: Int.max,
                requestedPart: nil,
                continuation: continuation
            )
            Task { [weak self] in
                try? await Task.sleep(for: Self.coldStartPrimeTimeout)
                await self?.timeoutPlaylistWaiter(waiterID)
            }
        }
    }

    private func waitForPlaylistUpdate(msn: Int, part: Int?) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isPlaylistRequestSatisfied(msn: msn, part: part) {
                    continuation.resume()
                    return
                }
                playlistWaiters[waiterID] = PlaylistWaiter(
                    requestedMSN: msn,
                    requestedPart: part,
                    continuation: continuation
                )
                Task { [weak self] in
                    try? await Task.sleep(for: Self.blockingTimeout)
                    await self?.timeoutPlaylistWaiter(waiterID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.timeoutPlaylistWaiter(waiterID)
            }
        }
    }

    private func timeoutPlaylistWaiter(_ id: UUID) {
        guard let waiter = playlistWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume()
    }

    private func timeoutPartWaiter(_ id: UUID) {
        guard let waiter = partWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: nil)
    }

    private func notifyAllWaiters() {
        // 1. Wake satisfied part waiters (and fail any whose segment finished early).
        for (id, waiter) in Array(partWaiters) {
            if let buffer = segmentBuffers[waiter.msn] {
                if waiter.partIndex < buffer.parts.count {
                    partWaiters.removeValue(forKey: id)
                    waiter.continuation.resume(returning: buffer.parts[waiter.partIndex].data)
                } else if buffer.isComplete || buffer.didFail {
                    partWaiters.removeValue(forKey: id)
                    waiter.continuation.resume(returning: nil)
                }
            }
        }

        // 2. Wake satisfied playlist waiters (including cold-start prime waiter).
        let coldStartReady = hasEnoughPartsForColdStart()
        for (id, waiter) in Array(playlistWaiters) {
            let ready: Bool
            if waiter.requestedMSN == Int.max {
                ready = coldStartReady
            } else {
                ready = isPlaylistRequestSatisfied(msn: waiter.requestedMSN, part: waiter.requestedPart)
            }
            if ready {
                playlistWaiters.removeValue(forKey: id)
                waiter.continuation.resume()
            }
        }
    }

    private func render(
        playlist: TwitchMediaPlaylist,
        basePartPrefix: String,
        baseSegmentPrefix: String
    ) -> String {
        var partsByMSN: [Int: LLHLSSegmentParts] = [:]
        for (msn, buffer) in segmentBuffers where !buffer.didFail && !buffer.parts.isEmpty {
            let descriptors = buffer.parts.map { part in
                LLHLSPartDescriptor(
                    partIndex: part.index,
                    duration: part.duration,
                    isIndependent: part.isIndependent,
                    uri: "\(basePartPrefix)/\(msn)/\(part.index).mp4"
                )
            }
            partsByMSN[msn] = LLHLSSegmentParts(
                msn: msn,
                parts: descriptors,
                isComplete: buffer.isComplete,
                segmentURI: "\(baseSegmentPrefix)/\(msn).mp4"
            )
        }

        // Emit `#EXT-X-PRELOAD-HINT` for the next upcoming part of the active
        // in-progress prefetch segment (immediately after the last finalized MSN).
        var preloadHintURI: String?
        if playlist.supportsLLHLS, let finalized = effectiveFinalizedMSN {
            let activeMSN = finalized + 1
            if let active = segmentBuffers[activeMSN], !active.isComplete, !active.didFail {
                preloadHintURI = "\(basePartPrefix)/\(activeMSN)/\(active.parts.count).mp4"
            }
        }

        return playlist.renderLLHLS(
            segmentPartsByMSN: partsByMSN,
            preloadHintURI: preloadHintURI
        )
    }
}
