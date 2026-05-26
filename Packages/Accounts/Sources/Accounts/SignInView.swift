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

    /// The redirect URI we instruct Twitch to send the auth code to.
    ///
    /// Twitch's dev portal requires HTTPS — custom URL schemes like `chattr://...`
    /// are rejected. We use `https://localhost`, which no actual server serves;
    /// instead our `TwitchAuthView`'s `WKNavigationDelegate` intercepts the navigation
    /// attempt before WebKit tries to load it, extracts the `code` query parameter,
    /// and cancels the navigation. This is the same pattern Streamly uses.
    private static let redirectURI = "https://localhost"

    @State private var pendingAuth: PendingAuth?

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
                startSignIn()
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
#if canImport(UIKit)
        .sheet(item: $pendingAuth) { auth in
            TwitchAuthSheet(
                authURL: auth.authURL,
                onCode: { code in
                    pendingAuth = nil
                    Task { await exchangeAndPersist(code: code, oauthClient: auth.oauthClient) }
                },
                onError: { message in
                    pendingAuth = nil
                    isSigningIn = false
                    errorMessage = message
                    logger.error("OAuth WebView reported error: \(message)")
                },
                onCancel: {
                    pendingAuth = nil
                    isSigningIn = false
                }
            )
        }
#endif
    }

    /// Builds the OAuth URL and presents the sign-in sheet.
    /// The sheet itself drives the rest of the flow via its callbacks.
    @MainActor
    private func startSignIn() {
#if canImport(UIKit)
        isSigningIn = true
        errorMessage = nil

        let oauthClient = TwitchOAuthClient(
            clientId: clientId,
            redirectUri: Self.redirectURI
        )
        let authURL = oauthClient.authorizationCodeURL(scopes: Self.scopes)
        pendingAuth = PendingAuth(authURL: authURL, oauthClient: oauthClient)
#else
        errorMessage = "Sign-in is not supported on this platform."
#endif
    }

    /// Once the WebView intercepts the code, exchange it for tokens and persist the account.
    @MainActor
    private func exchangeAndPersist(code: String, oauthClient: TwitchOAuthClient) async {
        defer { isSigningIn = false }
        do {
            let token = try await oauthClient.exchangeAuthorizationCode(code)
            _ = try await accountStore.add(token: token, scopes: Self.scopes)
            logger.info("Sign-in succeeded")
        } catch {
            logger.error("Token exchange or account-add failed: \(error.localizedDescription)")
            errorMessage = (error as? AppError)?.message ?? error.localizedDescription
        }
    }
}

/// Holds the per-attempt OAuth state. `Identifiable` so it can drive `.sheet(item:)`.
private struct PendingAuth: Identifiable {
    let id = UUID()
    let authURL: URL
    let oauthClient: TwitchOAuthClient
}
