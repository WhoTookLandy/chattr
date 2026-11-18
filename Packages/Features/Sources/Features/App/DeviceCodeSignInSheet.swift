import SwiftUI
import UIKit
import Accounts

/// Device Code Grant sign-in: shows the Twitch user code, sends the user to
/// Twitch (the Twitch app claims the link when installed) and waits for them
/// to approve. "Use browser instead" falls back to the
/// `ASWebAuthenticationSession` flow.
///
/// Presented by `TwitchSignIn.run(accountStore:clientId:)`
/// (`TwitchSignIn+Presentation.swift`), so every existing sign-in entry
/// point gets it without changes of its own.
///
/// Polling only runs while this sheet is on screen and the app is in the
/// foreground: appear / foreground → `activate`, disappear / background →
/// `deactivate` (see `DeviceCodeSignInModel`).
struct DeviceCodeSignInSheet<Signed>: View {
    let model: DeviceCodeFlowModel<Signed>
    var text: DeviceCodeSheetText = .chattrSignIn

    @Environment(\.openURL) private var openURL
    /// Bumped on every copy: drives the haptic and the "Copied" flash.
    @State private var copyCount = 0
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Text(text.instructions)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    codeCard

                    statusLine

                    actions
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(text.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { model.dismissed() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyCount)
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            showCopied = true
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { showCopied = false }
        }
        .onAppear { model.activate() }
        .onDisappear { model.dismissed() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            model.deactivate()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Resumes on the device code's own schedule: polls at once if
            // the interval already passed while backgrounded, never sooner.
            model.activate()
        }
    }

    // MARK: - Code

    private var codeCard: some View {
        let code = model.prompt?.userCode
        return Button(action: copyCode) {
            VStack(spacing: 10) {
                Text(code ?? "XXXXXXXX")
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .redacted(reason: code == nil ? .placeholder : [])

                Label(showCopied ? "Copied" : "Tap to copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(showCopied ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy, value: showCopied)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(code == nil || isTerminal)
        .opacity(isTerminal ? 0.4 : 1)
        .accessibilityLabel(code.map { "Code " + $0.map(String.init).joined(separator: " ") } ?? "Loading code")
        .accessibilityHint("Copies the code")
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .requestingCode:
            pending("Getting a code…")
        case .waiting:
            VStack(spacing: 4) {
                pending("Waiting for you to approve…")
                if let expiresAt = model.prompt?.expiresAt {
                    let now = Date.now
                    if expiresAt > now {
                        HStack(spacing: 4) {
                            Text("Code expires in")
                            Text(timerInterval: now...expiresAt, countsDown: true)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        case .signingIn:
            pending("Signing you in…")
        case .done:
            status(symbol: "checkmark.circle.fill", tint: .green, "Signed in")
        case .expired:
            status(symbol: "clock.badge.exclamationmark", tint: .orange, "Code expired")
        case .denied:
            status(symbol: "hand.raised.fill", tint: .orange, "Sign-in was declined on Twitch")
        case .failed(let message):
            status(symbol: "exclamationmark.triangle.fill", tint: .red, message)
        case .browserRequired(let message):
            status(symbol: "safari.fill", tint: .orange, message)
        }
    }

    private func pending(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func status(symbol: String, tint: Color, _ text: String) -> some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .multilineTextAlignment(.center)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .expired, .denied:
                primaryButton("Get a new code", systemImage: "arrow.clockwise") { model.requestNewCode() }
            case .failed:
                primaryButton("Try again", systemImage: "arrow.clockwise") { model.retry() }
            case .browserRequired:
                // The device flow can't work for this client, so the
                // browser flow becomes the primary action.
                primaryButton(text.fallbackRequired, systemImage: "safari") { model.useBrowserInstead() }
            case .requestingCode, .waiting, .signingIn, .done:
                primaryButton("Approve on Twitch", systemImage: "arrow.up.forward.app") { approveOnTwitch() }
                    .disabled(model.phase != .waiting || model.prompt == nil)
            }

            if !isBrowserRequired {
                Button(text.fallback) { model.useBrowserInstead() }
                    .font(.callout)
                    .disabled(model.phase == .signingIn || model.phase == .done)
            }
        }
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private var isTerminal: Bool {
        switch model.phase {
        case .expired, .denied, .browserRequired: true
        default: false
        }
    }

    private var isBrowserRequired: Bool {
        if case .browserRequired = model.phase { return true }
        return false
    }

    private func copyCode() {
        guard let code = model.prompt?.userCode else { return }
        UIPasteboard.general.string = code
        copyCount += 1
    }

    /// Copies the code (so it's ready to paste if Twitch asks) and opens the
    /// verification URL. Twitch pre-fills the code in that URL, and the
    /// Twitch app handles it as a universal link when installed.
    private func approveOnTwitch() {
        guard let prompt = model.prompt else { return }
        copyCode()
        openURL(prompt.verificationURL)
    }
}

/// The words that differ between the sheet's uses.
struct DeviceCodeSheetText {
    var title: String
    var instructions: String
    /// The secondary "do it another way" button.
    var fallback: String
    /// The same, as the primary action once the code flow can't work.
    var fallbackRequired: String

    static let chattrSignIn = DeviceCodeSheetText(
        title: "Sign in with Twitch",
        instructions: "Approve chattr on Twitch with this code.",
        fallback: "Use browser instead",
        fallbackRequired: "Continue in browser"
    )
}
