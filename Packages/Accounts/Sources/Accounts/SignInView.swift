import SwiftUI
import AuthenticationServices
import TwitchKit
import DesignSystem
import Core
import os

private let logger = AppLogger.make("Accounts.SignInView")

/// First-launch screen: presents a "Sign in with Twitch" button that runs the OAuth flow
/// via the Vercel bridge.
///
/// The bridge exchanges the auth code for tokens server-side (so the client_secret stays
/// off-device), then 302-redirects to `chattr://oauth-complete?access_token=...&...`.
/// ASWebAuthenticationSession privileged-intercepts that custom scheme inside the auth
/// sheet, and we extract the tokens directly. No `TwitchOAuthClient.exchangeAuthorizationCode`
/// call is needed here — Vercel did the exchange already.
///
/// On success, the new Account is persisted via `AccountStore.add(token:scopes:)`. RootView's
/// `@Query` observes the new SwiftData row and re-renders to ChannelListScreen automatically.
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

    /// The redirect URI we instruct Twitch to send the auth code to. Must match the URL
    /// registered at the Twitch dev portal and the URL the Vercel bridge expects at
    /// `/oauth/callback`.
    private static let redirectURI = "https://chattr-auth.vercel.app/oauth/callback"

    /// Custom URL scheme the bridge 302-redirects to after exchanging the code for tokens.
    /// Must be registered in the app's `Info.plist` under `CFBundleURLTypes`.
    /// `ASWebAuthenticationSession.callbackURLScheme` accepts this and intercepts the
    /// `chattr://` navigation before iOS would show "Open in chattr?".
    private static let callbackScheme = "chattr"

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
            // Build the OAuth URL. We only use TwitchOAuthClient for URL construction —
            // the actual code-for-token exchange happens server-side on the Vercel bridge,
            // so we never pass (or store) a client_secret here.
            let oauthClient = TwitchOAuthClient(
                clientId: clientId,
                redirectUri: Self.redirectURI
            )
            let authURL = oauthClient.authorizationCodeURL(scopes: Self.scopes)

#if canImport(UIKit)
            // Find an active window to anchor the ASWebAuthenticationSession sheet.
            guard
                let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0 is UIWindowScene }) as? UIWindowScene,
                let anchor = scene.windows.first
            else {
                errorMessage = "Couldn't find a window to present sign-in from."
                return
            }

            // Present the sheet, await the chattr:// callback carrying the exchanged tokens.
            let token = try await OAuthFlow.run(
                authURL: authURL,
                callbackScheme: Self.callbackScheme,
                presentationAnchor: anchor
            )

            // Hand off to AccountStore — it does the /users probe + Keychain persistence
            // + SwiftData insert. RootView's @Query will observe the new Account row
            // and transition away from this view automatically.
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
