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
            // 1. Build the OAuth URL.
            let temporaryClient = TwitchClient(clientId: clientId, tokenStore: InMemoryTokenStore())
            let authURL = temporaryClient.auth.authorizationCodeURL(scopes: Self.scopes)

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
                callbackScheme: "https",
                callbackHost: "localhost",
                presentationAnchor: anchor
            )

            // 3. Exchange the code for tokens (use the same temporary client; it has the OAuthClient configured).
            try await temporaryClient.auth.authenticate(withAuthorizationCode: result.code)
            let token = try await temporaryClient.auth.tokenProvider.token()

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
