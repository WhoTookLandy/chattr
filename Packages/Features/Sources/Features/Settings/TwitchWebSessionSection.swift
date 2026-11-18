#if os(iOS)
import SwiftUI
import WebKit
import Accounts

/// Settings → Video & Device → Ad-Free Playback: the Twitch sign-in the
/// native player starts video as, so the viewer's subscriptions and Turbo
/// skip ads (`TwitchHLS.currentAuth`).
///
/// The main path is a code approved at twitch.tv/activate
/// (`TwitchPlaybackSession`): it happens in a real browser or the Twitch
/// app, so passkeys and password managers work. The fallback is twitch.tv's
/// own login page in an in-app web view (`TwitchWebSession`), for when the
/// code flow doesn't.
struct TwitchWebSessionSection: View {
    private enum Session: Equatable {
        case code(login: String?)
        case website(login: String?)

        var login: String? {
            switch self {
            case .code(let login), .website(let login): login
            }
        }
    }

    private enum ActiveSheet: Identifiable {
        case code(DeviceCodeFlowModel<TwitchPlaybackCredential>)
        case website

        var id: String {
            switch self {
            case .code: "code"
            case .website: "website"
            }
        }
    }

    @State private var session: Session?
    @State private var sheet: ActiveSheet?
    @State private var isConfirmingSignOut = false

    var body: some View {
        Section {
            if let session {
                LabeledContent {
                    Text(session.login ?? "Signed In")
                } label: {
                    SettingLabel(
                        "Twitch.tv Session",
                        systemImage: "checkmark.seal",
                        subtitle: "Your subs and Turbo apply to video"
                    )
                }
                Button("Sign Out", role: .destructive) {
                    isConfirmingSignOut = true
                }
            } else {
                Button {
                    sheet = .code(makeCodeModel())
                } label: {
                    SettingLabel(
                        "Twitch.tv Session",
                        systemImage: "person.badge.key",
                        subtitle: "Sign in so subs and Turbo skip ads"
                    )
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Ad-Free Playback")
        } footer: {
            Text("Twitch skips ads for channels you subscribe to, or everywhere with Turbo, only when it knows who's watching. chattr's own sign-in can't tell it that, so this is a separate sign-in, used only to start video in the native player. Twitch will list it as its TV app; that's expected.")
        }
        .task { await reload() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .code(let model):
                DeviceCodeSignInSheet(model: model, text: .adFreePlayback)
            case .website:
                TwitchWebSignInSheet {
                    self.sheet = nil
                    Task { await reload() }
                }
            }
        }
        .confirmationDialog(
            "Sign out of ad-free playback?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await Task.detached { TwitchPlaybackSession.signOut() }.value
                    await TwitchWebSession.signOut()
                    await reload()
                }
            }
        } message: {
            Text("Streams will play logged out, with ads. Your chattr accounts stay signed in.")
        }
    }

    private func reload() async {
        let code = await Task.detached { TwitchPlaybackSession.current() }.value
        if let code {
            session = .code(login: code.login)
        } else if let website = await TwitchWebSession.current() {
            session = .website(login: website.login)
        } else {
            session = nil
        }
    }

    private func makeCodeModel() -> DeviceCodeFlowModel<TwitchPlaybackCredential> {
        let grant = TwitchPlaybackSession.deviceCodeGrant()
        return DeviceCodeFlowModel<TwitchPlaybackCredential>(
            dependencies: .init(
                requestCode: { try await grant.start() },
                waitForApproval: { prompt, schedule in
                    try await grant.waitForApproval(prompt, schedule: schedule)
                },
                addAccount: { token in
                    try await TwitchPlaybackSession.signIn(with: token)
                }
            ),
            onFinish: { outcome in
                switch outcome {
                case .signedIn(let credential):
                    session = .code(login: credential.login)
                    sheet = nil
                case .useBrowser:
                    // Swaps sheets: SwiftUI closes the code sheet first.
                    sheet = .website
                case .cancelled:
                    sheet = nil
                }
            }
        )
    }
}

extension DeviceCodeSheetText {
    static let adFreePlayback = DeviceCodeSheetText(
        title: "Ad-Free Playback",
        instructions: "Approve this code on Twitch so video plays as you. Twitch will name it as its TV app.",
        fallback: "Use the twitch.tv login page instead",
        fallbackRequired: "Use the twitch.tv login page"
    )
}

/// twitch.tv's own login page: the fallback when the code flow can't sign
/// in. Passkeys don't work here (iOS keeps them to apps a site trusts), so
/// it takes a password. Closes itself once the site has set its session
/// cookie.
private struct TwitchWebSignInSheet: View {
    let onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TwitchWebSignInView()
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign In to Twitch.tv")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        // Twitch's login is a single-page app: signing in sets the cookie
        // without a navigation to hang a check on, so look for it instead.
        .task {
            while !Task.isCancelled {
                if await TwitchWebSession.current() != nil {
                    onSignedIn()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct TwitchWebSignInView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The store the players read, so the session reaches them.
        config.websiteDataStore = .default()
        // Read as Safari: twitch.tv turns away browsers it doesn't know.
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: TwitchWebSession.signInURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif
