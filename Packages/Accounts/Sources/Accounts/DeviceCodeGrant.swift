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

/// Per-device-code polling state that must outlive any one polling run.
///
/// RFC 8628 §3.5: the client must wait at least `interval` seconds between
/// token requests, and a `slow_down` raises the interval by 5 s "for this
/// and all subsequent requests". A polling run is cancelled whenever the
/// sign-in sheet hides or the app backgrounds, so if the interval lived in
/// the loop each resume would forget earlier slow-downs and could poll
/// straight away. This object is created once per device code and handed
/// to every `waitForApproval` run for that code: it remembers the
/// effective interval and the earliest moment the next poll is allowed.
///
/// Lock-protected so it is `Sendable`; polling runs are serialized by the
/// caller, so the lock only guards against torn reads, never contention.
public final class DeviceCodePollSchedule: Sendable {
    private struct State: Sendable {
        var interval: Int
        var nextPollAt: Date
    }

    /// The device code this schedule belongs to.
    public let deviceCode: String
    private let state: OSAllocatedUnfairLock<State>

    /// `issuedAt` is when the device response arrived; the first poll is
    /// allowed one `interval` later.
    public init(prompt: DeviceCodePrompt, issuedAt: Date = Date()) {
        let interval = max(1, prompt.interval)
        self.deviceCode = prompt.deviceCode
        self.state = OSAllocatedUnfairLock(initialState: State(
            interval: interval,
            nextPollAt: issuedAt.addingTimeInterval(TimeInterval(interval))
        ))
    }

    /// Effective seconds between polls, including every slow-down so far.
    public var interval: Int { state.withLock { $0.interval } }

    /// Earliest moment the next token request is allowed.
    public var nextPollAt: Date { state.withLock { $0.nextPollAt } }

    /// Seconds still to wait before polling is allowed at `now` (0 if due).
    ///
    /// Never more than one `interval`. `nextPollAt` is wall-clock time, so if
    /// the device clock is set back the raw gap could be hours and polling
    /// would stall until the code expired; the deadline is re-anchored to
    /// one interval from `now` instead, so pacing stays correct. A
    /// clock moved forward can at worst allow one early poll, which Twitch
    /// answers with `slow_down` — handled, and it only makes pacing stricter.
    func delay(at now: Date) -> TimeInterval {
        state.withLock { state in
            let interval = TimeInterval(state.interval)
            // The clock went back: re-anchor the deadline one interval from
            // the new "now" so every later check agrees with it, instead of
            // waiting out the hour the clock was moved.
            if state.nextPollAt.timeIntervalSince(now) > interval {
                state.nextPollAt = now.addingTimeInterval(interval)
            }
            return max(0, state.nextPollAt.timeIntervalSince(now))
        }
    }

    /// A token request is going out at `now`. Recorded *before* the request
    /// so a run cancelled mid-request still counts it: the server may have
    /// seen it, so the next run must still wait a full interval.
    func recordPoll(at now: Date) {
        state.withLock { $0.nextPollAt = now.addingTimeInterval(TimeInterval($0.interval)) }
    }

    /// Twitch answered `slow_down` (or 429) at `now`: +5 s, permanently.
    /// Returns the new interval.
    @discardableResult
    func slowDown(at now: Date) -> Int {
        state.withLock {
            $0.interval = DeviceCodeGrant.slowedInterval($0.interval)
            $0.nextPollAt = now.addingTimeInterval(TimeInterval($0.interval))
            return $0.interval
        }
    }
}

/// Twitch's OAuth Device Code Grant, spoken directly to `id.twitch.tv`.
///
/// ## Client authentication
///
/// chattr's Twitch app is a *confidential* client: the client_secret lives
/// only on the chattr-auth bridge, which is why the browser flow routes the
/// code exchange there and why every refresh goes through
/// `BridgeTokenRefresh`. Twitch documents the device flow for confidential
/// clients with a token request that carries only `client_id`, so the
/// device request and the token poll run on-device without the secret.
/// RFC 8628 §3.4, however, says a client that has credentials must
/// authenticate its token requests — so if Twitch enforces that, the poll
/// fails with an `invalid_client`-style error. That surfaces as
/// `Failure.clientAuthenticationFailed`, which the sign-in sheet turns into
/// a "continue in the browser" fallback instead of a dead end.
///
/// The refresh_token Twitch issues is bound to the same client_id, so the
/// existing bridge refresh (which adds the secret server-side) is expected
/// to renew it like a browser-flow token, and `AccountStore.add` treats the
/// token like any other. Both points need a live check on a device before
/// release (see the PR description).
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
        /// Twitch rejected the client itself (`invalid_client`,
        /// `unauthorized_client`, a 401, a missing client secret): the
        /// device flow can't work for this app as configured, so the caller
        /// should fall back to the browser flow. Carries Twitch's message.
        case clientAuthenticationFailed(String)
        /// Twitch rejected the request for another reason (invalid scope,
        /// …). Carries Twitch's message.
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

    /// Raw scope strings, for a client whose scopes `TwitchScope` doesn't
    /// name (`TwitchPlaybackSession`).
    public init(
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
    /// - Throws: `Failure.clientAuthenticationFailed` / `.rejected` on a
    ///   4xx, `AppError.network` on a 5xx,
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
            throw Self.rejection(status: status, reason: reason)
        }
        return try Self.parsePrompt(data, now: now)
    }

    // MARK: - Token poll

    /// One poll of the token endpoint.
    ///
    /// - Throws: `Failure.clientAuthenticationFailed` when Twitch rejects
    ///   the client, `Failure.rejected` for another unrecognised 4xx,
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
    /// cancelled.
    ///
    /// Pacing comes entirely from `schedule`, which outlives this call: a
    /// run never polls before `schedule.nextPollAt`, and slow-downs stick.
    /// Cancelling and re-running (sheet hidden, app backgrounded, "Try
    /// again") therefore resumes at the same pace instead of resetting it:
    /// a resume after a long pause polls straight away because the wait is
    /// already over, and a quick bounce waits out the rest of the interval.
    ///
    /// Cancellation-safe: the only suspension points are `sleep` and the
    /// HTTP call, both of which throw `CancellationError` / `URLError
    /// .cancelled` when the surrounding task is cancelled. Nothing is
    /// retained after it returns — no timers. Callers must not run two of
    /// these for one schedule at the same time.
    ///
    /// - Throws: `Failure.expired` / `.denied` (terminal),
    ///   `Failure.clientAuthenticationFailed` / `.rejected`,
    ///   `CancellationError`, or the transport error that interrupted it.
    public func waitForApproval(
        _ prompt: DeviceCodePrompt,
        schedule: DeviceCodePollSchedule,
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> OAuthToken {
        precondition(schedule.deviceCode == prompt.deviceCode, "Poll schedule belongs to a different device code")
        while true {
            let wait = schedule.delay(at: now())
            if wait > 0 {
                try await sleep(.seconds(wait))
            }
            try Task.checkCancellation()
            let pollTime = now()
            guard pollTime < prompt.expiresAt else { throw Failure.expired }
            // A sleep that woke a hair early: wait out the remainder.
            guard schedule.delay(at: pollTime) <= 0 else { continue }

            schedule.recordPoll(at: pollTime)
            switch try await exchange(deviceCode: prompt.deviceCode) {
            case .authorized(let token):
                logger.notice("Device code approved")
                return token
            case .pending:
                continue
            case .slowDown:
                let slowed = schedule.slowDown(at: now())
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
        throw rejection(status: status, reason: reason)
    }

    /// Classifies a terminal 4xx. Client-authentication failures get their
    /// own case so the UI can steer the user to the browser flow (RFC 6749
    /// §5.2 `invalid_client` / `unauthorized_client`; Twitch phrases these
    /// as messages like "invalid client" or "missing client secret").
    static func rejection(status: Int, reason: String) -> Failure {
        let message = reason.isEmpty ? "HTTP \(status)" : reason
        let normalized = reason.lowercased()
        let clientMarkers = [
            "invalid_client", "unauthorized_client", "invalid client",
            "unauthorized client", "client secret", "client_secret",
        ]
        if status == 401 || clientMarkers.contains(where: { normalized.contains($0) }) {
            return .clientAuthenticationFailed(message)
        }
        return .rejected(message)
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
