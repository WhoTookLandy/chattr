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
        var attempts = 1

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
            // Never exceed PART-TARGET (0.560s): flush accumulated chunks first
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

    /// Coalesce ~100ms Twitch CMAF chunks into ~0.50–0.53s LL-HLS parts (4 parts
    /// per 2s segment): strictly `>= 85%` of `PART-TARGET` (`0.476s`) and
    /// `<= PART-TARGET` (`0.560s`) per RFC 8216bis §4.4.4.9.
    static let targetPartDuration: Double = 0.46
    static let maxPartDuration: Double = 0.56
    private static let maxPrefetchAttempts = 3
    /// Maximum time a blocking playlist reload or preload hint request waits.
    private static let blockingTimeout: Duration = .seconds(4)
    /// Maximum time the very first playlist fetch waits to prime initial parts
    /// so `AVPlayer` enters LL-HLS mode immediately without stalling startup.
    private static let coldStartPrimeTimeout: Duration = .milliseconds(900)
    /// How often the upstream Twitch media playlist is polled while active.
    private static let upstreamPollInterval: Duration = .milliseconds(1000)
    /// Suspend background polling after this long with no `AVPlayer` requests
    /// (can seamlessly wake up again if `AVPlayer` ABR-switches back).
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
    /// Stable `/seg/` URIs for MSNs already promoted ahead of Twitch's playlist,
    /// so an MSN's advertised URI never changes once Twitch publishes it.
    private var advertisedSegmentURIs: [Int: String] = [:]

    private var inFlightRefreshTask: Task<Void, any Error>?
    private var playlistWaiters: [UUID: PlaylistWaiter] = [:]
    private var partWaiters: [UUID: PartWaiter] = [:]
    private var pollTask: Task<Void, Never>?
    private var lastClientActivity = ContinuousClock.now
    private var isPermanentlyStopped = false

    init(id: String, upstreamURL: URL, client: ChunkedHTTPClient = .shared) {
        self.id = id
        self.upstreamURL = upstreamURL
        self.client = client
    }

    var isIdle: Bool {
        ContinuousClock.now - lastClientActivity > Self.idleShutdownDelay
    }

    /// Suspends background polling and frees transient prefetch buffers after
    /// inactivity without permanently killing the rendition, so `AVPlayer` can
    /// ABR-switch back to this variant URL later.
    func suspendForIdle() {
        pollTask?.cancel()
        pollTask = nil
        inFlightRefreshTask?.cancel()
        inFlightRefreshTask = nil
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
        latestPlaylist = nil
    }

    /// Permanent teardown (called only when the proxy itself shuts down).
    func stop() {
        isPermanentlyStopped = true
        suspendForIdle()
        advertisedSegmentURIs.removeAll()
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
        guard !isPermanentlyStopped else { throw CancellationError() }
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
                let normalized = normalizeBlockingRequest(msn: requestedMSN, part: requestedPart)
                if segmentBuffers[normalized.msn] == nil {
                    try? await refreshUpstream()
                }
                if !isPlaylistRequestSatisfied(msn: requestedMSN, part: requestedPart) {
                    await waitForPlaylistUpdate(msn: requestedMSN, part: requestedPart)
                }
                // RFC 8216bis: a blocking reload that timed out without
                // satisfying the requested MSN/part must return an error (503),
                // not an unchanged 200 OK playlist.
                if !isPlaylistRequestSatisfied(msn: requestedMSN, part: requestedPart) {
                    throw ChunkedHTTPClient.HTTPStreamError.badStatus(503)
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
        guard !isPermanentlyStopped, partIndex >= 0 else { return nil }
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
            return nil
        } else {
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

    // MARK: - Polling & Coalesced Prefetch Ingestion

    private func ensurePolling() {
        guard !isPermanentlyStopped, pollTask == nil else { return }
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
        guard !isPermanentlyStopped else { return false }
        if ContinuousClock.now - lastClientActivity > Self.idleShutdownDelay {
            suspendForIdle()
            return false
        }
        try? await refreshUpstream()
        if latestPlaylist?.isEndList == true {
            pollTask = nil
            return false
        }
        return true
    }

    /// Coalesces concurrent upstream playlist + init-map refreshes so older
    /// responses can never overtake newer ones or start prefetching with stale
    /// `initInfo`.
    private func refreshUpstream() async throws {
        if let existing = inFlightRefreshTask {
            try await existing.value
            return
        }
        let task = Task<Void, any Error> {
            try await self.performRefreshUpstream()
        }
        inFlightRefreshTask = task
        defer { inFlightRefreshTask = nil }
        try await task.value
    }

    private func performRefreshUpstream() async throws {
        let (data, status) = try await client.fetchData(from: upstreamURL)
        guard (200...299).contains(status), let text = String(data: data, encoding: .utf8) else {
            throw ChunkedHTTPClient.HTTPStreamError.badStatus(status)
        }
        let parsed = TwitchMediaPlaylist.parse(text, relativeTo: upstreamURL)

        // Fetch `#EXT-X-MAP` whenever it changes, committing `fetchedMapURL`
        // ONLY after a successful parse so transient errors are retried and
        // stale metadata is never applied to a new init segment.
        if let mapURL = parsed.latestMapURL, mapURL != fetchedMapURL {
            initInfo = nil
            if let (mapData, mapStatus) = try? await client.fetchData(from: mapURL),
               (200...299).contains(mapStatus),
               let info = CMAFInitInfo.parse(initSegment: mapData) {
                fetchedMapURL = mapURL
                initInfo = info
            }
        }

        // Detect discontinuity or backwards media-sequence jump (e.g. ad break
        // splice): clear stale prefetch buffers so we never emit mismatched MSNs.
        if let previous = latestPlaylist {
            if parsed.mediaSequence < previous.mediaSequence
                || parsed.discontinuitySequence != previous.discontinuitySequence {
                resetPrefetchState()
            }
        }

        latestPlaylist = parsed

        // Start streaming up to 2 `#EXT-X-TWITCH-PREFETCH` segments in parallel
        // once init metadata for the current map is available.
        if parsed.supportsLLHLS, initInfo != nil, let baseLastMSN = parsed.lastFinalizedMSN {
            for (offset, prefetchURL) in parsed.prefetchURIs.prefix(2).enumerated() {
                let expectedMSN = baseLastMSN + 1 + offset
                let key = prefetchURL.absoluteString
                if let existingMSN = urlToMSN[key], existingMSN == expectedMSN,
                   let existing = segmentBuffers[expectedMSN] {
                    // Retry a failed prefetch with no advertised parts up to
                    // `maxPrefetchAttempts`; never disturb already-advertised parts.
                    if existing.didFail, existing.parts.isEmpty, existing.attempts < Self.maxPrefetchAttempts {
                        startPrefetch(msn: expectedMSN, url: prefetchURL, attempt: existing.attempts + 1)
                    }
                    continue
                }
                startPrefetch(msn: expectedMSN, url: prefetchURL, attempt: 1)
            }
        }

        pruneOldBuffers()
        notifyAllWaiters()
    }

    private func startPrefetch(msn: Int, url: URL, attempt: Int) {
        guard !isPermanentlyStopped else { return }
        if attempt == 1, segmentBuffers[msn] != nil { return }

        prefetchTasks[msn]?.cancel()
        urlToMSN[url.absoluteString] = msn
        var buffer = SegmentBuffer(msn: msn, upstreamURL: url)
        buffer.attempts = attempt
        segmentBuffers[msn] = buffer

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
                llhlsLogger.debug("Prefetch failed msn=\(msn) attempt=\(attempt): \(error.localizedDescription, privacy: .public)")
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
        // Keep advertised `/seg/` URIs pinned for the full sliding playlist window.
        if let windowStart = latestPlaylist?.mediaSequence {
            for msn in Array(advertisedSegmentURIs.keys) where msn < windowStart {
                advertisedSegmentURIs[msn] = nil
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

    /// RFC 8216bis §6.2.5.2: if a client requests `_HLS_part` beyond a parent
    /// segment that has already completed with fewer parts, normalize to part 0
    /// of the next media sequence (`msn + 1`).
    private func normalizeBlockingRequest(msn: Int, part: Int?) -> (msn: Int, part: Int?) {
        guard let part else { return (msn, nil) }
        if let buffer = segmentBuffers[msn], buffer.isComplete, part >= buffer.parts.count {
            return (msn + 1, 0)
        }
        return (msn, part)
    }

    private func isPlaylistRequestSatisfied(msn: Int, part: Int?) -> Bool {
        if latestPlaylist?.isEndList == true { return true }
        let normalized = normalizeBlockingRequest(msn: msn, part: part)
        let targetMSN = normalized.msn
        let targetPart = normalized.part

        if let targetPart {
            if let buffer = segmentBuffers[targetMSN] {
                if buffer.parts.count > targetPart { return true }
                if buffer.isComplete {
                    // Normalized target itself completed with fewer parts: wait
                    // unless a subsequent segment is already finalized or has parts.
                    if let nextBuf = segmentBuffers[targetMSN + 1], !nextBuf.parts.isEmpty { return true }
                    if let finalized = effectiveFinalizedMSN, finalized > targetMSN { return true }
                    return false
                }
                if buffer.didFail { return true }
                return false
            }
            if let finalized = effectiveFinalizedMSN, finalized >= targetMSN { return true }
            return false
        } else {
            if let finalized = effectiveFinalizedMSN, finalized >= targetMSN { return true }
            if let buffer = segmentBuffers[targetMSN], buffer.isComplete || buffer.didFail { return true }
            return false
        }
    }

    private func waitForColdStartPrime() async {
        let waiterID = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if hasEnoughPartsForColdStart() {
                continuation.resume()
                return
            }
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
        let baseLastMSN = playlist.lastFinalizedMSN ?? -1

        for (msn, buffer) in segmentBuffers where !buffer.didFail && !buffer.parts.isEmpty {
            let segURI = advertisedSegmentURIs[msn] ?? "\(baseSegmentPrefix)/\(msn).mp4"
            // Pin the `/seg/` URI whenever this MSN is being promoted ahead of
            // Twitch's upstream playlist so future reloads never change its URI.
            if buffer.isComplete, msn > baseLastMSN {
                advertisedSegmentURIs[msn] = segURI
            }
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
                segmentURI: segURI
            )
        }

        var preloadHintURI: String?
        if playlist.supportsLLHLS, let finalized = effectiveFinalizedMSN {
            let activeMSN = finalized + 1
            if let active = segmentBuffers[activeMSN], !active.isComplete, !active.didFail {
                preloadHintURI = "\(basePartPrefix)/\(activeMSN)/\(active.parts.count).mp4"
            }
        }

        return playlist.renderLLHLS(
            segmentPartsByMSN: partsByMSN,
            pinnedSegmentURIs: advertisedSegmentURIs,
            preloadHintURI: preloadHintURI
        )
    }
}
