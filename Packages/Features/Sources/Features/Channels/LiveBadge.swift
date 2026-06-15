import SwiftUI

/// Pulsing live-dot + compact viewer count ("🔴 6K"), shared by the
/// followed-channels list row and the live-stream thumbnail overlay.
///
/// The dot is an SF Symbol so it can pulse via `.symbolEffect(.pulse,
/// options: .repeating)` — "live, right now" reads more clearly than a static
/// circle, and the system attenuates the effect under Reduce Motion.
///
/// The two surfaces need different legibility treatments, captured by `Style`:
/// - `.listRow` sits over standard list rows, so it uses Regular Liquid Glass
///   (same visual family as the chat tab pills) for automatic legibility.
/// - `.overlay` sits over a busy 16:9 stream thumbnail, where Clear glass's
///   adaptive transparency can dip below the WCAG 4.5:1 contrast threshold
///   against bright video frames — so it uses a solid 65% black backdrop and
///   white text to guarantee legibility across all stream content.
struct LiveBadge: View {
    enum Style { case listRow, overlay }

    let viewerCount: Int
    let style: Style

    private var dotSize: CGFloat { style == .listRow ? 6 : 7 }
    private var countFont: Font { style == .listRow ? .caption2.weight(.semibold) : .caption.weight(.semibold) }
    private var countColor: Color { style == .listRow ? .primary : .white }
    private var hPadding: CGFloat { style == .listRow ? 6 : 7 }
    private var vPadding: CGFloat { style == .listRow ? 2 : 3 }

    var body: some View {
        let count = viewerCount.formatted(.number.notation(.compactName))

        let content = HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: dotSize))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            Text(count)
                .font(countFont)
                .foregroundStyle(countColor)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)

        return Group {
            switch style {
            case .listRow: content.glassEffect(in: Capsule())
            case .overlay: content.background(.black.opacity(0.65), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live, \(count) viewers")
    }
}
