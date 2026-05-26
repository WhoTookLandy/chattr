import SwiftUI
import AuthenticationServices
import TwitchKit
import DesignSystem
import Core
import os

private let logger = AppLogger.make("Accounts.SignInView")

/// First-launch screen: presents a "Sign in with Twitch" button that runs the OAuth flow.
///
/// On success, the new Account is persisted via `AccountStore.add(token:scopes:)` and the
/// caller observes the change via SwiftData's `@Query`.
public struct SignInView: View {
    private let accountStore: AccountStore
    private let clientId: String

    @State private var isSigningIn = false
    @State private var errorMessage: String?

    /// The viewer-facing scopes chattr needs.
    private static let scopes: [TwitchScope] = [
        .userReadEmail,
        .userReadChat,
        .userWriteChat,
        .userReadFollows,
    ]

    /// Custom URL scheme registered in Info.plist + Twitch dev portal.
    ///
    /// We use a custom URL scheme (RFC 8252 — "OAuth 2.0 for Native Apps") instead of
    /// TwitchKit's default `https://localhost` because `ASWebAuthenticationSession` only
    /// intercepts callbacks for *custom* URL schemes — passing `callbackURLScheme: "https"`
    /// silently fails because the system can't safely intercept arbitrary https traffic.
    /// The full callback URI is `chattr://oauth-callback?code=...&state=...`.
    private static let callbackScheme = "chattr"
    private static let callbackHost = "oauth-callback"
    private static var redirectURI: String { "\(callbackScheme)://\(callbackHost)" }

    public init(accountStore: AccountStore, clientId: String) {
        self.accountStore = accountStore
        self.clientId = clientId
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "bubble.left.and.bubble.right")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(Brand.accent)

            VStack(spacing: 8) {
                Text("chattr")
                    .font(.largeTitle)
                    .bold()
                Text("Twitch chat, multi-account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await signIn() }
            } label: {
                if isSigningIn {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    Text("Sign in with Twitch")
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn)
            .padding(.horizontal)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer().frame(height: 32)
        }
    }

    @MainActor
    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            // 1. Construct our own TwitchOAuthClient with the custom redirect URI.
            //    We bypass `TwitchClient`'s facade here because TwitchClient hard-codes
            //    TwitchOAuthClient's default `https://localhost` — we need our custom
            //    `chattr://oauth-callback` for the ASWebAuthenticationSession intercept.
            //    This OAuth client is used only for URL building + code exchange; once we
            //    have the token, `AccountStore.add(...)` constructs its own clients with
            //    Keychain-backed persistence.
            let oauthClient = TwitchOAuthClient(
                clientId: clientId,
                redirectUri: Self.redirectURI
            )
            let authURL = oauthClient.authorizationCodeURL(scopes: Self.scopes)

            // 2–4. iOS-only: present ASWebAuthenticationSession, exchange code, persist account.
#if canImport(UIKit)
            guard
                let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0 is UIWindowScene }) as? UIWindowScene,
                let anchor = scene.windows.first
            else {
                errorMessage = "Couldn't find a window to present sign-in from."
                return
            }

            let result = try await OAuthFlow.run(
                authURL: authURL,
                callbackScheme: Self.callbackScheme,
                callbackHost: Self.callbackHost,
                presentationAnchor: anchor
            )

            // 3. Exchange the code for tokens directly via the OAuth client.
            //    `exchangeAuthorizationCode` posts to /oauth2/token with our matching redirectUri.
            let token = try await oauthClient.exchangeAuthorizationCode(result.code)

            // 4. Hand off to AccountStore — it does the /users probe + persistence.
            _ = try await accountStore.add(token: token, scopes: Self.scopes)
            logger.info("Sign-in succeeded")
#else
            // Slice 1 is iOS-only; macOS host reaches this path only in unit tests.
            errorMessage = "Sign-in is not supported on this platform."
#endif
        } catch {
            logger.error("Sign-in failed: \(error.localizedDescription)")
            errorMessage = (error as? AppError)?.message ?? error.localizedDescription
        }
    }
}
