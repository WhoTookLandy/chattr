import Foundation
import TwitchKit
import Core
import os

private let logger = AppLogger.make("Accounts.DeviceCodeGrant")

/// What the user needs to see to approve a device-code sign-in: the short
/// code to enter (or confirm) and where to enter it.
///
/// Named `DeviceCodePrompt` rather than `DeviceCodeAuthorization` so it
/// doesn't collide with TwitchKit's type of that name in files that import
/// both modules.
public struct DeviceCodePrompt: Sendable, Equatable {
    /// Opaque code we poll the token endpoint with. Never shown.
    public let deviceCode: String
    /// The short code the user confirms on Twitch (e.g. `ABCDEFGH`).
    public let userCode: String
    /// Where the user approves. Twitch pre-fills the code in this URL, and
    /// the Twitch app claims it as a universal link when installed.
    public let verificationURL: URL
    /// Minimum seconds between polls, per Twitch.
    public let interval: Int
    /// Wall-clock moment the device code stops working.
    public let expiresAt: Date

    public init(deviceCode: String, userCode: String, verificationURL: URL, interval: Int, expiresAt: Date) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.interval = interval
        self.expiresAt = expiresAt
    }
}

/// Twitch's OAuth Device Code Grant, spoken directly to `id.twitch.tv`.
///
/// ## Why it works with chattr's confidential client
///
/// chattr's Twitch app is a *confidential* client: the client_secret lives
/// only on the chattr-auth bridge, which is why the browser flow routes the
/// code exchange there and why every refresh goes through
/// `BridgeTokenRefresh`. The device-code grant never needs the secret — the
/// device request and the token poll take only `client_id` — so this runs
/// on-device. The refresh_token Twitch issues is bound to the same
/// client_id, so the existing bridge refresh (which adds the secret
/// server-side) renews it exactly like a browser-flow token. No new refresh
/// path; `AccountStore.add` treats the token like any other.
///
/// ## Shape
///
/// Like `BridgeTokenRefresh`, deliberately side-effect free: no Keychain, no
/// account state. `start()` and `exchange(deviceCode:)` are single HTTP
/// round-trips; `waitForApproval` is the polling loop on top, with the clock
/// and sleep injectable so the loop is unit-testable without waiting.
public struct DeviceCodeGrant: Sendable {

    /// Result of a single token poll.
    public enum PollOutcome: Sendable, Equatable {
        /// User approved — here are the tokens.
        case authorized(OAuthToken)
        /// User hasn't acted yet; poll again after `interval`.
        case pending
        /// Polling too fast; add 5 s to the interval (RFC 8628 §3.5).
        case slowDown
        /// The device code is no longer valid. Terminal.
        case expired
        /// The user declined. Terminal.
        case denied
    }

    /// Terminal device-code failures (as opposed to transport errors, which
    /// propagate as-is and are retryable).
    public enum Failure: Error, Equatable, Sendable {
        case expired
        case denied
        /// Twitch rejected the request for another reason (bad client_id,
        /// invalid scope, …). Carries Twitch's message.
        case rejected(String)
    }

    let clientId: String
    let rawScopes: [String]
    let deviceEndpoint: URL
    let tokenEndpoint: URL
    let session: URLSession

    public init(clientId: String, scopes: [TwitchScope], session: URLSession = .shared) {
        self.init(clientId: clientId, rawScopes: scopes.map(\.rawValue), session: session)
    }

    init(
        clientId: String,
        rawScopes: [String],
        deviceEndpoint: URL = Endpoints.TwitchID.device,
        tokenEndpoint: URL = Endpoints.TwitchID.token,
        session: URLSession = .shared
    ) {
        self.clientId = clientId
        self.rawScopes = rawScopes
        self.deviceEndpoint = deviceEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.session = session
    }

    // MARK: - Device request

    /// Asks Twitch for a fresh device code + user code.
    ///
    /// - Throws: `Failure.rejected` on a 4xx, `AppError.network` on a 5xx,
    ///   transport / decoding errors as-is.
    public func start(now: Date = Date()) async throws -> DeviceCodePrompt {
        let (data, status) = try await post(deviceEndpoint, fields: [
            "client_id": clientId,
            "scopes": rawScopes.joined(separator: " "),
        ])
        guard status == 200 else {
            let reason = Self.errorReason(in: data) ?? "HTTP \(status)"
            logger.error("Device code request failed (HTTP \(status)): \(reason, privacy: .public)")
            if status >= 500 { throw AppError.network(.badServerResponse) }
            throw Failure.rejected(reason)
        }
        return try Self.parsePrompt(data, now: now)
    }

    // MARK: - Token poll

    /// One poll of the token endpoint.
    ///
    /// - Throws: `Failure.rejected` for an unrecognised 4xx,
    ///   `AppError.network` on a 5xx, transport / decoding errors as-is.
    public func exchange(deviceCode: String) async throws -> PollOutcome {
        let (data, status) = try await post(tokenEndpoint, fields: [
            "client_id": clientId,
            // Twitch documents `scopes` (plural) for this grant.
            "scopes": rawScopes.joined(separator: " "),
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        return try Self.parseTokenResponse(data, status: status)
    }

    /// Polls until the user approves, the code expires, or the task is
    /// cancelled. Sleeps *before* each poll unless `pollImmediately` (used
    /// when resuming from the background, where the user has likely just
    /// approved in the Twitch app).
    ///
    /// Cancellation-safe: the only suspension points are `sleep` and the
    /// HTTP call, both of which throw `CancellationError` / `URLError
    /// .cancelled` when the surrounding task is cancelled. Nothing is
    /// retained after it returns — no timers.
    ///
    /// - Throws: `Failure.expired` / `.denied` (terminal),
    ///   `CancellationError`, or the transport error that interrupted it.
    public func waitForApproval(
        _ prompt: DeviceCodePrompt,
        pollImmediately: Bool = false,
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> OAuthToken {
        var interval = max(1, prompt.interval)
        var skipSleep = pollImmediately
        while true {
            if !skipSleep {
                try await sleep(.seconds(interval))
            }
            skipSleep = false
            try Task.checkCancellation()
            guard now() < prompt.expiresAt else { throw Failure.expired }

            switch try await exchange(deviceCode: prompt.deviceCode) {
            case .authorized(let token):
                logger.notice("Device code approved")
                return token
            case .pending:
                continue
            case .slowDown:
                let slowed = Self.slowedInterval(interval)
                interval = slowed
                logger.info("Twitch asked to slow down; polling every \(slowed) s")
            case .expired:
                throw Failure.expired
            case .denied:
                throw Failure.denied
            }
        }
    }

    /// RFC 8628 §3.5: on `slow_down`, increase the interval by 5 seconds for
    /// this and all subsequent requests.
    static func slowedInterval(_ interval: Int) -> Int { interval + 5 }

    // MARK: - Parsing (static so tests can hit every branch directly)

    static func parsePrompt(_ data: Data, now: Date) throws -> DeviceCodePrompt {
        let body = try snakeCaseDecoder().decode(DeviceResponse.self, from: data)
        guard let url = URL(string: body.verificationUri), !body.userCode.isEmpty, !body.deviceCode.isEmpty else {
            throw AppError.decoding(reason: "Device code response missing user_code or verification_uri")
        }
        return DeviceCodePrompt(
            deviceCode: body.deviceCode,
            userCode: body.userCode,
            verificationURL: url,
            interval: max(1, body.interval ?? 5),
            expiresAt: now.addingTimeInterval(TimeInterval(body.expiresIn))
        )
    }

    static func parseTokenResponse(_ data: Data, status: Int) throws -> PollOutcome {
        if status == 200 {
            let body = try snakeCaseDecoder().decode(TokenResponse.self, from: data)
            return .authorized(OAuthToken(
                accessToken: body.accessToken,
                refreshToken: body.refreshToken,
                expiresIn: body.expiresIn,
                scope: body.scope,
                tokenType: body.tokenType
            ))
        }

        let reason = errorReason(in: data) ?? ""
        let normalized = reason.lowercased()
        // Twitch reports device-code states as `{"status":400,"message":"…"}`;
        // RFC 8628 uses `{"error":"…"}`. `errorReason` reads either.
        if normalized.contains("authorization_pending") { return .pending }
        if normalized.contains("slow_down") || status == 429 { return .slowDown }
        if normalized.contains("expired_token") || normalized.contains("invalid device code") { return .expired }
        // `access_denied` (RFC) / "authorization declined" style messages.
        if normalized.contains("denied") || normalized.contains("declined") { return .denied }
        if status >= 500 { throw AppError.network(.badServerResponse) }
        logger.error("Device code poll rejected (HTTP \(status)): \(reason, privacy: .public)")
        throw Failure.rejected(reason.isEmpty ? "HTTP \(status)" : reason)
    }

    /// Twitch's error text: `message` (Twitch style) or `error` (RFC style).
    static func errorReason(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(ErrorResponse.self, from: data) else { return nil }
        return body.message ?? body.error
    }

    // MARK: - Transport

    private func post(_ url: URL, fields: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError(message: "Device code: no HTTP response")
        }
        return (data, http.statusCode)
    }

    static func formEncoded(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?/"))
        return Data(
            fields
                .sorted { $0.key < $1.key }
                .map { key, value in
                    let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                    let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                    return "\(k)=\(v)"
                }
                .joined(separator: "&")
                .utf8
        )
    }

    private static func snakeCaseDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

// MARK: - Wire format

private struct DeviceResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int?
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let scope: [String]?
    let tokenType: String?
}

private struct ErrorResponse: Decodable {
    let status: Int?
    let message: String?
    let error: String?
}
