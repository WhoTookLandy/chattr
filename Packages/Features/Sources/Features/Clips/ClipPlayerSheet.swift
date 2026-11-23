import SwiftUI
import Core
#if os(iOS)
import UIKit
import WebKit
#endif

/// In-app player for a Twitch clip tapped in chat (see `ClipLinkRouter`).
///
/// Plays Twitch's own embeddable clip player (`clips.twitch.tv/embed`) in a
/// `WKWebView`, loaded top-level like the live player — the ToS-sanctioned
/// way to show Twitch video in a third-party app. The live stream, if one
/// is playing, pauses while the clip plays and resumes when the sheet goes.
struct ClipPlayerSheet: View {
    let clip: ClipLinkTarget

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.playback) private var playback
    /// Set when this sheet paused the live stream (so it resumes it).
    @State private var liveStreamHold: PlaybackHold?
    #endif

    private static let systemOpenURL = OpenURLAction { _ in .systemAction }

    private var pageURL: URL {
        Endpoints.TwitchClips.page(slug: clip.slug) ?? clip.sourceURL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                player
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 10) {
                    ShareLink(item: pageURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.url = pageURL
                        #endif
                    } label: {
                        Label("Copy Link", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)

                Link(destination: clip.sourceURL) {
                    Label("Open in Twitch", systemImage: "arrow.up.forward.app")
                }
                .font(.subheadline)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Clip")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // The chat's `ClipLinkRouter` is inherited here; without this the
        // "Open in Twitch" link (itself a clip URL) would be routed straight
        // back to this sheet instead of out to Twitch.
        .environment(\.openURL, Self.systemOpenURL)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #if os(iOS)
        .onAppear(perform: pauseLiveStream)
        .onDisappear(perform: resumeLiveStream)
        #endif
    }

    @ViewBuilder
    private var player: some View {
        #if os(iOS)
        if let embed = Endpoints.TwitchClips.embed(slug: clip.slug) {
            ClipWebPlayer(url: embed)
        } else {
            Color.black
        }
        #else
        Color.black
        #endif
    }

    #if os(iOS)
    /// An explicit hold, not `togglePlay()`: if the live stream is still
    /// loading (no `AVPlayer` yet) a toggle does nothing and the stream
    /// would start behind the clip; a hold keeps it from starting.
    private func pauseLiveStream() {
        guard liveStreamHold == nil else { return }
        liveStreamHold = playback?.holdPlayback(.clip)
    }

    /// Resumes only what this sheet paused, and only if it's still the
    /// same stream (see `PlaybackCenter.holdPlayback`).
    private func resumeLiveStream() {
        guard let hold = liveStreamHold else { return }
        liveStreamHold = nil
        playback?.releaseHold(hold)
    }
    #endif
}

#if os(iOS)
/// The clip embed page. Navigation away from it (the embed's "watch on
/// Twitch" links) opens outside the app.
private struct ClipWebPlayer: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url, context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Stop audio and close any active PiP/fullscreen presentation before
        // `ClipPlayerSheet.onDisappear` resumes the live stream underneath.
        webView.pauseAllMediaPlayback(completionHandler: nil)
        webView.closeAllMediaPresentations(completionHandler: nil)
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v=>v.pause())")
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.targetFrame?.isMainFrame ?? true,
                  navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else { return .allow }
            _ = await UIApplication.shared.open(url)
            return .cancel
        }
    }
}
#endif
