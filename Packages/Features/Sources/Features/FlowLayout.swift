import SwiftUI

/// A SwiftUI Layout that arranges children left-to-right, wrapping to the next
/// line when horizontal space is exhausted. Used by ChatRow to mix Text and
/// emote image subviews in a single natural-reading flow.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var alignment: VerticalAlignment

    init(spacing: CGFloat = 4, alignment: VerticalAlignment = .firstTextBaseline) {
        self.spacing = spacing
        self.alignment = alignment
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
            if currentX + size.width > containerWidth, currentX > 0 {
                // Wrap to next line
                totalHeight += currentRowHeight + spacing
                currentX = 0
                currentRowHeight = 0
            }
            currentX += size.width + spacing
            currentRowHeight = max(currentRowHeight, size.height)
        }
        totalHeight += currentRowHeight
        return CGSize(width: containerWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let containerWidth = bounds.width
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var rowSubviews: [(subview: LayoutSubview, size: CGSize)] = []

        func flushRow() {
            guard !rowSubviews.isEmpty else { return }
            let rowHeight = rowSubviews.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for (subview, size) in rowSubviews {
                // Align within row based on vertical alignment
                let yOffset: CGFloat
                switch alignment {
                case .firstTextBaseline:
                    // Approximate baseline alignment: bottom-align short items (emote images)
                    // with text. Since we can't query baseline from LayoutSubview directly,
                    // we bottom-align all items within the row height.
                    yOffset = rowHeight - size.height
                case .center:
                    yOffset = (rowHeight - size.height) / 2
                case .bottom:
                    yOffset = rowHeight - size.height
                default:
                    yOffset = 0
                }
                subview.place(
                    at: CGPoint(x: x, y: currentY + yOffset),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            currentY += rowHeight + spacing
            rowSubviews.removeAll()
        }

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: containerWidth, height: nil))
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                flushRow()
                currentX = bounds.minX
            }
            rowSubviews.append((subview, size))
            currentX += size.width + spacing
        }
        flushRow()
    }
}
