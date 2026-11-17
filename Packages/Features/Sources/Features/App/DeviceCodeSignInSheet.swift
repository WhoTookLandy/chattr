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
struct DeviceCodeSignInSheet: View {
    let model: DeviceCodeSignInModel

    @Environment(\.openURL) private var openURL
    /// Bumped on every copy: drives the haptic and the "Copied" flash.
    @State private var copyCount = 0
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Text("Approve chattr on Twitch with this code.")
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
            .navigationTitle("Sign in with Twitch")
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
            model.activate(pollImmediately: true)
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
            case .requestingCode, .waiting, .signingIn, .done:
                primaryButton("Approve on Twitch", systemImage: "arrow.up.forward.app") { approveOnTwitch() }
                    .disabled(model.phase != .waiting || model.prompt == nil)
            }

            Button("Use browser instead") { model.useBrowserInstead() }
                .font(.callout)
                .disabled(model.phase == .signingIn || model.phase == .done)
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
        case .expired, .denied: true
        default: false
        }
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
