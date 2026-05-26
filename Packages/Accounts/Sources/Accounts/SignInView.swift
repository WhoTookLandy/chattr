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

    /// Universal Link components for the OAuth callback.
    ///
    /// We host a tiny Vercel project at this domain (`~/Dev/chattr-auth/`) that
    /// serves an Apple App Site Association file declaring chattr handles
    /// `/oauth/callback*` URLs as Universal Links. Twitch's dev portal accepts the
    /// HTTPS URL (custom URL schemes are rejected); iOS silently intercepts the
    /// navigation when it sees the Universal Link.
    private static let callbackHost = "chattr-auth.vercel.app"
    private static let callbackPath = "/oauth/callback"
    private static var redirectURI: String { "https://\(callbackHost)\(callbackPath)" }

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

    /// Run the full sign-in flow: build OAuth URL → present ASWebAuthenticationSession with
    /// Universal Link callback → exchange code for tokens → persist account via AccountStore.
    @MainActor
    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            // 1. Construct our own TwitchOAuthClient so we can specify the custom redirect URI.
            //    TwitchClient's facade init hardcodes the default `https://localhost`, which
            //    we no longer want.
            let oauthClient = TwitchOAuthClient(
                clientId: clientId,
                redirectUri: Self.redirectURI
            )
            let authURL = oauthClient.authorizationCodeURL(scopes: Self.scopes)

#if canImport(UIKit)
            // 2. Find the active window to anchor the ASWebAuthenticationSession sheet.
            guard
                let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0 is UIWindowScene }) as? UIWindowScene,
                let anchor = scene.windows.first
            else {
                errorMessage = "Couldn't find a window to present sign-in from."
                return
            }

            // 3. Present the sheet, await the Universal Link callback.
            let result = try await OAuthFlow.run(
                authURL: authURL,
                callbackHost: Self.callbackHost,
                callbackPath: Self.callbackPath,
                presentationAnchor: anchor
            )

            // 4. Exchange the code for tokens — same `oauthClient` is reused so the
            //    redirect_uri parameter matches (Twitch validates it).
            let token = try await oauthClient.exchangeAuthorizationCode(result.code)

            // 5. Hand off to AccountStore — it does the /users probe + persistence.
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
