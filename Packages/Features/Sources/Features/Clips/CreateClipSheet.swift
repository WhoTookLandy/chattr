import SwiftUI
import Accounts
import TwitchKit
import Core
#if os(iOS)
import UIKit
#endif

private let logger = AppLogger.make("Features.CreateClipSheet")

/// "Create Clip" from the chat's More menu: captures a clip of the live
/// stream (`POST /clips`, scope `clips:edit`) the moment the sheet opens,
/// then shows the clip's edit URL — where Twitch lets you trim and title it
/// — with Share / Copy.
///
/// Accounts signed in before `clips:edit` joined the scope list get a 401
/// (after `withTokenRefresh`'s retry, since a refreshed token keeps the old
/// scopes) and see a "sign in again" explanation instead of a raw error —
/// the same treatment as `ViewerListSheet`.
struct CreateClipSheet: View {
    let channel: ChannelDescriptor
    let account: Account
    let accountStore: AccountStore

    private enum Phase: Equatable {
        case creating
        case created(id: String, editURL: URL)
        case missingScope
        case notAllowed(String)
        case failed(String)
    }

    @State private var phase: Phase = .creating
    /// Drives `.task(id:)` so dismissing cancels both the initial request and
    /// any retry, while bumping it cleanly restarts creation.
    @State private var attempt = 0
    @State private var copiedEditURL = false
    @State private var copiedClipLink = false
    @Environment(\.dismiss) private var dismiss

    /// System browser opener — overrides the chat's `ClipLinkRouter` so
    /// "Open Clip Editor" always opens in Safari rather than re-entering the
    /// in-app clip player.
    private static let systemOpenURL = OpenURLAction { _ in .systemAction }

    var body: some View {
        NavigationStack {
            content
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .navigationTitle("Create Clip")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .appSensoryFeedback(.success, trigger: phase) { _, new in
            if case .created = new { return true }
            return false
        }
        .environment(\.openURL, Self.systemOpenURL)
        .task(id: attempt) {
            await createClip()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .creating:
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Clipping \(channel.channelDisplayName)…")
                    .font(.headline)
                Text("Twitch captures the last moments of the stream.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
        case let .created(id, editURL):
            created(id: id, editURL: editURL)
        case .missingScope:
            unavailable(
                "Sign in again to create clips",
                systemImage: "key",
                message: "chattr needs one more Twitch permission to make clips. Remove and re-add your account in You → Accounts to grant it."
            )
        case .notAllowed(let message):
            unavailable("Can't clip this stream", systemImage: "scissors", message: message)
        case .failed(let message):
            VStack(spacing: 16) {
                unavailable("Couldn't create clip", systemImage: "exclamationmark.triangle", message: message)
                Button("Try Again") {
                    phase = .creating
                    attempt += 1
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func created(id: String, editURL: URL) -> some View {
        let clipURL = Endpoints.TwitchClips.page(slug: id)
        return VStack(alignment: .leading, spacing: 16) {
            Label("Clip created", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Twitch is processing it — open the editor to trim and title it. It's saved to your clips either way.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Edit URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(editURL.absoluteString)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                ShareLink(item: editURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    copy(editURL)
                    copiedEditURL = true
                } label: {
                    Label(copiedEditURL ? "Copied" : "Copy", systemImage: copiedEditURL ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            Link(destination: editURL) {
                Label("Open Clip Editor", systemImage: "scissors")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if let clipURL {
                Button {
                    copy(clipURL)
                    copiedClipLink = true
                } label: {
                    Label(copiedClipLink ? "Clip link copied" : "Copy Clip Link", systemImage: "link")
                }
                .font(.subheadline)
            }
        }
    }

    private func unavailable(_ title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }

    private func copy(_ url: URL) {
        #if os(iOS)
        UIPasteboard.general.url = url
        #endif
    }

    // MARK: - Request

    private func createClip() async {
        // Guard against SwiftUI re-running `.task(id:)` on re-appearance
        // (e.g. after dismissing a ShareLink sheet) once a clip was already
        // created or settled; "Try Again" resets `phase = .creating` before
        // bumping `attempt`.
        guard phase == .creating else { return }
        let client = accountStore.client(for: account)
        let broadcasterID = channel.channelId
        do {
            let clip = try await accountStore.withTokenRefresh(for: account) {
                try await client.api.createClip(broadcasterID: broadcasterID)
            }
            guard let editURL = URL(string: clip.editUrl) else {
                phase = .failed("Twitch returned an unreadable clip link.")
                return
            }
            logger.notice("Created clip \(clip.id, privacy: .public) on #\(channel.channelLoginName, privacy: .public)")
            phase = .created(id: clip.id, editURL: editURL)
        } catch is CancellationError {
            // Sheet dismissed mid-request — nothing to show.
        } catch let error as HelixError {
            logger.error("Create clip failed on #\(channel.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            switch error {
            case .unauthorized:
                // A token without `clips:edit` — refreshing keeps the old scopes.
                phase = .missingScope
            case .forbidden(let apiError):
                phase = .notAllowed(apiError.message.isEmpty
                    ? "This channel doesn't allow you to make clips."
                    : apiError.message)
            case .notFound:
                phase = .notAllowed("\(channel.channelDisplayName) isn't live right now.")
            case .rateLimited:
                phase = .failed("Too many clips at once. Wait a moment and try again.")
            default:
                phase = .failed(error.localizedDescription)
            }
        } catch {
            logger.error("Create clip failed on #\(channel.channelLoginName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }
}
