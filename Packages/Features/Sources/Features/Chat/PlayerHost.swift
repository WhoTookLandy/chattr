#if os(iOS)
import SwiftUI
import UIKit

/// A slot the engine's video can be shown in. Several can exist at once
/// (the chat header and the mini player during a pop); only the active one
/// (`PlaybackCenter.activeHostID`) holds the view.
struct PlayerHost: View {
    let center: PlaybackCenter
    @State private var id = UUID()

    var body: some View {
        PlayerHostRepresentable(
            center: center,
            isActive: center.activeHostID == id,
            revision: center.hostRevision
        )
        .onAppear { center.claim(id) }
        .onDisappear { center.release(id) }
    }
}

private struct PlayerHostRepresentable: UIViewRepresentable {
    let center: PlaybackCenter
    let isActive: Bool
    let revision: Int

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard isActive, let engineView = center.engine?.view else { return }
        if engineView.superview !== container {
            engineView.removeFromSuperview()
            engineView.frame = container.bounds
            engineView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(engineView)
        }
    }
}
#endif
