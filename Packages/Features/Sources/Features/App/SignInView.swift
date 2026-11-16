import SwiftUI
import Accounts
import Core
import os

private let logger = AppLogger.make("Features.SignInView")

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
/// `@Query` observes the new SwiftData row and re-renders to the app shell automatically.
///
/// Lives in `Features` (all SwiftUI does); the UI-free flow it drives is
/// `Accounts.TwitchSignIn`.
struct SignInView: View {
    @Environment(\.accountStore) private var accountStore

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

    // Scopes, redirect URI, and callback scheme now live in the shared
    // `TwitchSignIn` flow — used by both this view and the in-app account
    // switcher's "Add Account" — so there's one source of truth for what
    // "sign in to chattr" means.

    var body: some View {
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
                logger.info("SignInView: showing session-expired banner for @\(login, privacy: .public)")
            }
        }
    }

    @MainActor
    private func signIn() async {
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }

        do {
            // Delegate to the shared flow. It builds the OAuth URL,
            // presents the auth sheet (exchange happens server-side so
            // the client_secret stays off-device), and hands the token
            // to AccountStore.add. RootView's @Query observes the new
            // row and transitions away from this view automatically.
            _ = try await TwitchSignIn.run(accountStore: accountStore)
        } catch {
            logger.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = (error as? AppError)?.message ?? error.localizedDescription
        }
    }
}
