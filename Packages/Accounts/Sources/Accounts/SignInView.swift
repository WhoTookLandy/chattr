import SwiftUI
import AuthenticationServices
import TwitchKit
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

    /// The login of the account whose session just expired, if the previous
    /// app session was forced out by the auth layer. Read once on appear (and
    /// cleared) so the banner shows on the *first* render after expiry and
    /// not again afterwards.
    ///
    /// UserDefaults (rather than `@SceneStorage`) so the flag survives true
    /// cold-start — a session can expire while the app is killed in the
    /// background, and the user may not relaunch until much later.
    @State private var sessionExpiredLogin: String?

    /// The viewer-facing scopes chattr needs.
    ///
    /// `moderatorManageChatMessages` is required for the mod-only
    /// delete affordance — non-mod users will never exercise it, but
    /// requesting it up-front avoids forcing a re-auth flow the first
    /// time a moderator tries to delete a message. Twitch's consent
    /// screen lists every scope; mods see it and approve it, non-mods
    /// see it and approve it harmlessly (the token can request the
    /// delete endpoint but it'll fail with `unauthorized` from Twitch
    /// if the user isn't actually a mod in the target channel).
    ///
    /// `userReadEmotes` powers the launch-time emote-image prefetch:
    /// `EmoteImagePrefetcher` calls `GET /chat/emotes/user` to enumerate
    /// every emote the user has access to (subscribed channels, Prime,
    /// Turbo) and warms Nuke's disk cache so the images are ready when
    /// the user opens chat. Without the scope, that fetch returns
    /// `unauthorized` and we silently skip — the app degrades to
    /// "fetch on first display" without breaking.
    private static let scopes: [TwitchScope] = [
        .userReadEmail,
        .userReadChat,
        .userWriteChat,
        .userReadFollows,
        .userReadEmotes,
        .moderatorManageChatMessages,
    ]

    /// The redirect URI we instruct Twitch to send the auth code to. Must match the URL
    /// registered at the Twitch dev portal and the URL the Vercel bridge expects at
    /// `/oauth/callback`. Centralized in `Core.Endpoints` alongside the refresh URL
    /// that `AccountStore.refreshTokens(...)` uses — both live on the same bridge.
    private static let redirectURI = Endpoints.ChattrAuth.callback.absoluteString

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
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("chattr")
                    .font(.largeTitle)
                    .bold()
                Text("Twitch chat, multi-account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Soft "session expired" banner — only renders if the previous
            // app session was force-signed-out (refresh_token revoked,
            // expired, or wiped by TwitchKit's defensive cleanup). Frames
            // the sign-in CTA with context so the user understands WHY
            // they're back here.
            //
            // Tone: orange + clock symbol, not red + warning — this is a
            // routine session timeout, not a security incident.
            if let sessionExpiredLogin {
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.orange)
                    Text("Your session for @\(sessionExpiredLogin) expired")
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                    Text("Sign in again to continue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity)
                // Stays on `.regularMaterial` deliberately. The iOS 26
                // equivalent for content-container glass —
                // `.glassBackgroundEffect()` — is visionOS-only despite
                // showing up in cross-platform docs. On iOS we have:
                //   - `.glassEffect()` for controls / navigation chrome
                //   - `.regularMaterial` (or `.thickMaterial`) for content
                //     cards
                // This banner is a content-layer callout (a small floating
                // card inside SignInView's VStack — not navigation chrome).
                // The skill says glass goes on the navigation layer; for
                // content cards, `.regularMaterial` IS the right iOS 26
                // material. It adapts to Reduce Transparency and Increase
                // Contrast automatically.
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                // Smooth fade-in on first render — feels less abrupt than
                // appearing instantly with the rest of the layout.
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
            .tint(.accentColor)
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
        // One-shot read of the session-expired flag. Done in `.onAppear`
        // (not at view-init time) so the value is stored in @State and
        // SwiftUI's `if let sessionExpiredLogin` re-renders when the
        // flag transitions from nil → value. Cleared immediately so the
        // banner doesn't reappear on subsequent navigations back to
        // SignInView (e.g. user signs in successfully, signs out manually,
        // returns to SignInView — no stale banner).
        .onAppear {
            if let login = UserDefaults.standard.string(forKey: AccountStore.lastSessionExpiredLoginKey) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    sessionExpiredLogin = login
                }
                UserDefaults.standard.removeObject(forKey: AccountStore.lastSessionExpiredLoginKey)
                logger.info("SignInView: showing session-expired banner for @\(login)")
            }
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
