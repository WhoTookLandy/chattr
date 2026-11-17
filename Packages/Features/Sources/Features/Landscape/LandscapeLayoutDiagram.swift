import SwiftUI
import DesignSystem

/// A tiny landscape phone showing where the video and chat go — the preview
/// in the layout picker. Purely decorative (hidden from VoiceOver; the
/// option's label says it in words).
struct LandscapeLayoutDiagram: View {
    let mode: LandscapeLayoutMode
    let side: LandscapeChatSide
    var isSelected = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let chatWidth = (size.width * 0.34).rounded()
            ZStack(alignment: side.alignment) {
                // Video: the whole screen when chat floats over it,
                // otherwise everything but the chat column.
                ZStack {
                    Rectangle().fill(Color.black.opacity(0.85))
                    Image(systemName: "play.fill")
                        .font(.system(size: size.height * 0.22))
                        .foregroundStyle(.white.opacity(0.9))
                        .offset(x: videoGlyphOffset(chatWidth: chatWidth))
                }
                .padding(side.edge, mode == .beside ? chatWidth : 0)

                chatColumn(width: chatWidth, height: size.height)
            }
        }
        .aspectRatio(2.1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                              lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityHidden(true)
    }

    /// Over video: nudge the play glyph to the uncovered side, as the
    /// stage does with the picture.
    private func videoGlyphOffset(chatWidth: CGFloat) -> CGFloat {
        guard mode == .overlay else { return 0 }
        return side == .right ? -chatWidth / 2 : chatWidth / 2
    }

    private static let lineFractions: [CGFloat] = [0.7, 0.5, 0.8, 0.6]

    private func chatColumn(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: height * 0.07) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(mode == .overlay ? 0.85 : 0.45))
                    .frame(width: width * Self.lineFractions[index], height: max(2, height * 0.06))
            }
            Spacer(minLength: 0)
            Capsule()
                .fill(Color.primary.opacity(0.3))
                .frame(height: max(3, height * 0.1))
        }
        .padding(width * 0.1)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(mode == .overlay ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.chatSurface))
        .overlay(alignment: side == .right ? .leading : .trailing) {
            if mode == .beside {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 1)
            }
        }
    }
}
