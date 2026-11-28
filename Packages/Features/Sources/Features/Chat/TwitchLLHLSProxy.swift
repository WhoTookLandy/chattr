import Foundation
import Core
import os
#if os(iOS)
import Network
#endif

/// Minimal HTTP/1.1 request parser for loopback proxy connections (pure value
/// type so routing and query parsing are directly unit-testable).
struct LocalHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let queryItems: [String: String]
    let wantsKeepAlive: Bool

    static func parse(headerData: Data) -> LocalHTTPRequest? {
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let pieces = requestLine.split(separator: " ")
        guard pieces.count >= 2 else { return nil }

        let method = String(pieces[0]).uppercased()
        let rawTarget = String(pieces[1])
        let httpVersion = pieces.count >= 3 ? String(pieces[2]).uppercased() : "HTTP/1.1"

        let path: String
        var queryItems: [String: String] = [:]
        if let qIndex = rawTarget.firstIndex(of: "?") {
            path = String(rawTarget[..<qIndex])
            let queryString = rawTarget[rawTarget.index(after: qIndex)...]
            for pair in queryString.split(separator: "&") {
                if let eq = pair.firstIndex(of: "=") {
                    let key = String(pair[..<eq]).removingPercentEncoding ?? String(pair[..<eq])
                    let val = String(pair[pair.index(after: eq)...]).removingPercentEncoding ?? String(pair[pair.index(after: eq)...])
                    queryItems[key] = val
                }
            }
        } else {
            path = rawTarget
        }

        var connectionHeader: String?
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if name == "connection" {
                    connectionHeader = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
                }
            }
        }

        let keepAlive: Bool
        if let connectionHeader {
            keepAlive = !connectionHeader.contains("close")
        } else {
            keepAlive = httpVersion != "HTTP/1.0"
        }

        return LocalHTTPRequest(
            method: method,
            path: path,
            queryItems: queryItems,
            wantsKeepAlive: keepAlive
        )
    }
}

#if os(iOS)
private let proxyLogger = AppLogger.make("Features.LLHLSProxy")

/// In-process localhost (`127.0.0.1`) HTTP proxy translating Twitch's proprietary
/// `#EXT-X-TWITCH-PREFETCH` fMP4 streams into standard Apple LL-HLS
/// (`#EXT-X-PART` + `#EXT-X-PRELOAD-HINT` + `CAN-BLOCK-RELOAD=YES`) so native
/// `AVPlayer` achieves ~2–4s live latency with native PiP and background audio.
///
/// Started lazily on first Low Latency native playback; Standard mode never
/// opens a socket.
actor TwitchLLHLSProxy {
    static let shared = TwitchLLHLSProxy()

    private let token: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let listenerQueue = DispatchQueue(label: "com.andrewbeshay.chattr.llhls-proxy", qos: .userInitiated)

    private var listener: NWListener?
    private var listenerGeneration = 0
    private var listenerStartupTask: Task<UInt16?, Never>?
    private var port: UInt16?
    private var masterURLs: [String: URL] = [:]
    private var masterOrder: [String] = []
    private var variantTracks: [String: LLHLSVariantTrack] = [:]
    private var variantIDByUpstream: [String: String] = [:]
    private var nextID = 0

    /// Returns a loopback proxy URL for `playlist`, starting the local server
    /// on demand. Returns `nil` if the listener couldn't bind so callers fall
    /// back directly to `playlist.url`.
    func proxiedURL(for playlist: StreamPlaylist) async -> URL? {
        guard playlist.url.scheme?.lowercased() == "https" else { return nil }
        guard let boundPort = await ensureListening() else { return nil }

        await pruneIdleTracks()

        if playlist.isAudioOnlyRendition {
            let vid = registerVariant(upstreamURL: playlist.url)
            return URL(string: "http://127.0.0.1:\(boundPort)/\(token)/media/\(vid).m3u8")
        } else {
            nextID += 1
            let masterID = "m\(nextID)"
            masterURLs[masterID] = playlist.url
            masterOrder.append(masterID)
            // Evict strictly by registration order (FIFO) so `m100` never
            // sorts ahead of `m99` and evicts itself.
            while masterOrder.count > 24 {
                let evicted = masterOrder.removeFirst()
                masterURLs[evicted] = nil
            }
            return URL(string: "http://127.0.0.1:\(boundPort)/\(token)/master/\(masterID).m3u8")
        }
    }

    /// Stops all tracks and tears down the listener (used in tests / cleanup).
    func stopAll() async {
        listenerStartupTask?.cancel()
        listenerStartupTask = nil
        listenerGeneration += 1
        listener?.cancel()
        listener = nil
        port = nil
        for track in variantTracks.values {
            await track.stop()
        }
        variantTracks.removeAll()
        variantIDByUpstream.removeAll()
        masterURLs.removeAll()
        masterOrder.removeAll()
    }

    // MARK: - Listener Lifecycle

    private func ensureListening() async -> UInt16? {
        if let port, listener != nil {
            return port
        }
        if let inFlight = listenerStartupTask {
            return await inFlight.value
        }

        let task = Task<UInt16?, Never> {
            await self.startNewListener()
        }
        listenerStartupTask = task
        let result = await task.value
        listenerStartupTask = nil
        return result
    }

    private func startNewListener() async -> UInt16? {
        if let port, listener != nil {
            return port
        }
        listener?.cancel()
        listener = nil
        port = nil

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true

        guard let newListener = try? NWListener(using: params) else {
            proxyLogger.warning("Failed to create NWListener on 127.0.0.1")
            return nil
        }

        listenerGeneration += 1
        let generation = listenerGeneration

        let boundPort: UInt16? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (UInt16?) -> Void = { value in
                let first = resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }

            newListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    finish(newListener.port?.rawValue)
                case .failed(let error):
                    proxyLogger.warning("LL-HLS proxy listener failed: \(error.localizedDescription, privacy: .public)")
                    finish(nil)
                    Task { await self?.handleListenerDown(generation: generation) }
                case .cancelled:
                    finish(nil)
                    Task { await self?.handleListenerDown(generation: generation) }
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                let task = Task.detached(priority: .userInitiated) {
                    await self.serveConnection(connection)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .failed, .cancelled:
                        task.cancel()
                    default:
                        break
                    }
                }
            }

            newListener.start(queue: listenerQueue)
        }

        // If `stopAll()` or another listener superseded us while suspended,
        // cancel our own listener and never overwrite the committed one.
        guard let boundPort, generation == listenerGeneration else {
            newListener.cancel()
            return port
        }
        listener = newListener
        port = boundPort
        proxyLogger.notice("LL-HLS loopback proxy listening on 127.0.0.1:\(boundPort)")
        return boundPort
    }

    private func handleListenerDown(generation: Int) {
        if listenerGeneration == generation {
            listener = nil
            port = nil
        }
    }

    private func registerVariant(upstreamURL: URL) -> String {
        let key = upstreamURL.absoluteString
        if let existing = variantIDByUpstream[key], variantTracks[existing] != nil {
            return existing
        }
        nextID += 1
        let id = "v\(nextID)"
        variantIDByUpstream[key] = id
        variantTracks[id] = LLHLSVariantTrack(id: id, upstreamURL: upstreamURL)
        return id
    }

    private func pruneIdleTracks() async {
        for (id, track) in Array(variantTracks) {
            if await track.isIdle {
                // Suspend background work without permanently disabling the URL
                // so AVPlayer ABR switches back cleanly; only evict entries when
                // the table grows large.
                await track.suspendForIdle()
                if variantTracks.count > 48 {
                    await track.stop()
                    variantTracks[id] = nil
                    variantIDByUpstream[track.upstreamURL.absoluteString] = nil
                }
            }
        }
    }

    // MARK: - HTTP Connection Loop

    private nonisolated func serveConnection(_ connection: NWConnection) async {
        let connQueue = DispatchQueue(label: "com.andrewbeshay.chattr.llhls-conn", qos: .userInitiated)
        connection.start(queue: connQueue)
        defer { connection.cancel() }

        var readBuffer = Data()
        let headerDelimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        for _ in 0..<128 {
            // Read until end of HTTP headers.
            while readBuffer.range(of: headerDelimiter) == nil {
                guard let chunk = await receiveChunk(from: connection), !chunk.isEmpty else {
                    return
                }
                readBuffer.append(chunk)
                if readBuffer.count > 65_536 {
                    return
                }
            }

            guard let delimiterRange = readBuffer.range(of: headerDelimiter) else { return }
            let headerData = Data(readBuffer[..<delimiterRange.lowerBound])
            readBuffer.removeSubrange(..<delimiterRange.upperBound)

            guard let request = LocalHTTPRequest.parse(headerData: headerData) else {
                _ = await sendResponse(
                    status: "400 Bad Request",
                    contentType: "text/plain",
                    body: Data(),
                    keepAlive: false,
                    on: connection
                )
                return
            }

            let response = await route(request)
            let keepAlive = request.wantsKeepAlive && response.allowKeepAlive
            let headOnly = request.method == "HEAD"
            let sent = await sendResponse(
                status: response.status,
                contentType: response.contentType,
                extraHeaders: response.extraHeaders,
                body: headOnly ? Data() : response.body,
                contentLengthOverride: headOnly ? response.body.count : nil,
                keepAlive: keepAlive,
                on: connection
            )
            if !sent || !keepAlive {
                return
            }
        }
    }

    private struct HTTPResponsePayload: Sendable {
        let status: String
        let contentType: String
        let body: Data
        var extraHeaders: [(String, String)] = []
        var allowKeepAlive: Bool = true
    }

    private func route(_ request: LocalHTTPRequest) async -> HTTPResponsePayload {
        guard request.method == "GET" || request.method == "HEAD" else {
            return HTTPResponsePayload(status: "405 Method Not Allowed", contentType: "text/plain", body: Data(), allowKeepAlive: false)
        }
        guard let boundPort = port else {
            return HTTPResponsePayload(status: "503 Service Unavailable", contentType: "text/plain", body: Data(), allowKeepAlive: false)
        }

        // Expected paths:
        //   /<token>/master/<masterId>.m3u8
        //   /<token>/media/<variantId>.m3u8
        //   /<token>/part/<variantId>/<msn>/<partIndex>.mp4
        //   /<token>/seg/<variantId>/<msn>.mp4
        let components = request.path.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == token else {
            return HTTPResponsePayload(status: "403 Forbidden", contentType: "text/plain", body: Data(), allowKeepAlive: false)
        }

        let origin = "http://127.0.0.1:\(boundPort)/\(token)"

        switch components[1] {
        case "master":
            let masterID = components[2].replacingOccurrences(of: ".m3u8", with: "")
            guard let upstreamMaster = masterURLs[masterID] else {
                return HTTPResponsePayload(status: "404 Not Found", contentType: "text/plain", body: Data())
            }
            do {
                let (data, status) = try await ChunkedHTTPClient.shared.fetchData(from: upstreamMaster)
                guard (200...299).contains(status), let text = String(data: data, encoding: .utf8) else {
                    return HTTPResponsePayload(status: "\(status) Upstream Error", contentType: "text/plain", body: Data(), allowKeepAlive: false)
                }
                let rewritten = TwitchMasterPlaylistRewriter.rewrite(text: text, relativeTo: upstreamMaster) { variantURL in
                    let vid = self.registerVariant(upstreamURL: variantURL)
                    return URL(string: "\(origin)/media/\(vid).m3u8") ?? variantURL
                }
                return HTTPResponsePayload(
                    status: "200 OK",
                    contentType: "application/vnd.apple.mpegurl",
                    body: Data(rewritten.utf8)
                )
            } catch {
                return HTTPResponsePayload(status: "502 Bad Gateway", contentType: "text/plain", body: Data(), allowKeepAlive: false)
            }

        case "media":
            let variantID = components[2].replacingOccurrences(of: ".m3u8", with: "")
            guard let track = variantTracks[variantID] else {
                return HTTPResponsePayload(status: "404 Not Found", contentType: "text/plain", body: Data())
            }
            let requestedMSN = request.queryItems["_HLS_msn"].flatMap(Int.init)
            let requestedPart = request.queryItems["_HLS_part"].flatMap(Int.init)
            do {
                let text = try await track.playlistResponse(
                    requestedMSN: requestedMSN,
                    requestedPart: requestedPart,
                    basePartPrefix: "\(origin)/part/\(variantID)",
                    baseSegmentPrefix: "\(origin)/seg/\(variantID)"
                )
                return HTTPResponsePayload(
                    status: "200 OK",
                    contentType: "application/vnd.apple.mpegurl",
                    body: Data(text.utf8)
                )
            } catch ChunkedHTTPClient.HTTPStreamError.badStatus(503) {
                return HTTPResponsePayload(status: "503 Service Unavailable", contentType: "text/plain", body: Data())
            } catch {
                return HTTPResponsePayload(status: "502 Bad Gateway", contentType: "text/plain", body: Data(), allowKeepAlive: false)
            }

        case "part":
            guard components.count == 5,
                  let track = variantTracks[components[2]],
                  let msn = Int(components[3]),
                  let partIndex = Int(components[4].replacingOccurrences(of: ".mp4", with: "")),
                  partIndex >= 0
            else {
                return HTTPResponsePayload(status: "400 Bad Request", contentType: "text/plain", body: Data())
            }
            guard let data = await track.partData(msn: msn, partIndex: partIndex) else {
                // RFC 8216bis §6.2.5.2: hinted part didn't materialize because
                // the segment ended early.
                return HTTPResponsePayload(status: "404 Not Found", contentType: "text/plain", body: Data())
            }
            return HTTPResponsePayload(
                status: "200 OK",
                contentType: "video/mp4",
                body: data
            )

        case "seg":
            guard components.count == 4,
                  let track = variantTracks[components[2]],
                  let msn = Int(components[3].replacingOccurrences(of: ".mp4", with: ""))
            else {
                return HTTPResponsePayload(status: "400 Bad Request", contentType: "text/plain", body: Data())
            }
            let resolved = await track.segmentResponse(msn: msn)
            if let data = resolved.data {
                return HTTPResponsePayload(status: "200 OK", contentType: "video/mp4", body: data)
            }
            if let redirectURL = resolved.redirectURL {
                return HTTPResponsePayload(
                    status: "302 Found",
                    contentType: "text/plain",
                    body: Data(),
                    extraHeaders: [("Location", redirectURL.absoluteString)]
                )
            }
            return HTTPResponsePayload(status: "404 Not Found", contentType: "text/plain", body: Data())

        default:
            return HTTPResponsePayload(status: "404 Not Found", contentType: "text/plain", body: Data())
        }
    }

    // MARK: - NWConnection Async Helpers

    private nonisolated func receiveChunk(from connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                if let error {
                    _ = error
                    continuation.resume(returning: nil)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private nonisolated func sendResponse(
        status: String,
        contentType: String,
        extraHeaders: [(String, String)] = [],
        body: Data,
        contentLengthOverride: Int? = nil,
        keepAlive: Bool,
        on connection: NWConnection
    ) async -> Bool {
        let length = contentLengthOverride ?? body.count
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(length)\r\n"
        header += "Cache-Control: no-cache, no-store\r\n"
        header += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        for (name, value) in extraHeaders {
            header += "\(name): \(value)\r\n"
        }
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(body)

        return await withCheckedContinuation { continuation in
            connection.send(content: payload, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}
#endif
