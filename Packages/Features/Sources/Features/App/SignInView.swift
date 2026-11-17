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

    // Scopes, redirect URI, and callback scheme now live in the shared
    // `TwitchSignIn` flow — used by both this view and the in-app account
    // switcher's "Add Account" — so there's one source of truth for what
    // "sign in to chattr" means.

    init(accountStore: AccountStore, clientId: String) {
        self.accountStore = accountStore
        self.clientId = clientId
    }

    /// "Just looking" — a channel to peek at without an account.
    @State private var guestLogin = ""
    @State private var guestChannel: GuestTarget?
    @FocusState private var guestFieldFocused: Bool

    struct GuestTarget: Identifiable {
        let login: String
        var id: String { login }
    }

    private var trimmedGuestLogin: String {
        guestLogin.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#@"))
            .lowercased()
    }

    /// Twitch logins: 3–25 letters, digits or underscores.
    private var guestLoginIsValid: Bool {
        let login = trimmedGuestLogin
        return (3...25).contains(login.count)
            && login.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                features
                if let sessionExpiredLogin {
                    sessionExpiredBanner(sessionExpiredLogin)
                }
                actions
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .background { backdrop }
        #if os(iOS)
        .fullScreenCover(item: $guestChannel) { target in
            GuestChannelView(login: target.login) {
                Task { await signIn() }
            }
        }
        #endif
        // One-shot read of the session-expired flag (then cleared, so the
        // banner doesn't reappear on later visits to this screen).
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

    // MARK: - Pieces

    /// Soft Twitch-purple glow behind the hero, fading into the system
    /// background. Works in light and dark.
    private var backdrop: some View {
        ZStack {
            #if os(iOS)
            Color(.systemBackground)
            #else
            Color(.windowBackgroundColor)
            #endif
            RadialGradient(
                colors: [Color.twitchPurple.opacity(0.35), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(
                    LinearGradient(
                        colors: [Color.twitchPurple, Color.twitchPurple.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .shadow(color: Color.twitchPurple.opacity(0.45), radius: 18, y: 8)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("chattr")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Twitch chat, built for watching.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            featureRow("play.rectangle.fill",
                       title: "Watch while you chat",
                       detail: "The stream sits right above chat, or floats in picture in picture.")
            featureRow("bubble.left.and.bubble.right.fill",
                       title: "All your chats in one place",
                       detail: "Swipe between channels; mentions light up the Chats tab.")
            featureRow("person.2.fill",
                       title: "More than one account",
                       detail: "Switch accounts without signing out.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(_ systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.twitchPurple)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sessionExpiredBanner(_ login: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your session for @\(login) expired")
                    .font(.callout.weight(.medium))
                Text("Sign in again to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var actions: some View {
        VStack(spacing: 16) {
            Button {
                Task { await signIn() }
            } label: {
                Group {
                    if isSigningIn {
                        ProgressView().tint(.white)
                    } else {
                        Text("Sign in with Twitch")
                            .font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(Color.twitchPurple, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isSigningIn)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            // Guest mode is iOS-only (its player is UIKit-hosted).
            #if os(iOS)
            HStack(spacing: 10) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("or just look around")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(.quaternary).frame(height: 1)
            }

            guestField
            #endif

            Text("You sign in on Twitch; chattr never sees your password.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    /// Channel name → read-only stream + chat, no account needed.
    private var guestField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Channel name", text: $guestLogin)
                .focused($guestFieldFocused)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(openGuest)
            Button("Watch", action: openGuest)
                .font(.subheadline.weight(.semibold))
                .disabled(!guestLoginIsValid)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func openGuest() {
        guard guestLoginIsValid else { return }
        guestFieldFocused = false
        guestChannel = GuestTarget(login: trimmedGuestLogin)
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
            _ = try await TwitchSignIn.run(accountStore: accountStore, clientId: clientId)
        } catch {
            logger.error("Sign-in failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = (error as? AppError)?.message ?? error.localizedDescription
        }
    }
}
