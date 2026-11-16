import SwiftUI

/// Stand-in for an inline chat emote while its image loads or after it
/// fails, drawn inside the emote's fixed box (`EmoteDisplayMetrics`).
///
/// It used to be the emote's name as free-width text, which made a row
/// reflow twice: once to the text's width, then again to the image's when
/// it landed. Now the box is final from the first layout pass:
/// - loading → a faint rounded tile (no text to re-measure);
/// - failed  → the name, shrunk to fit the box so it still hints at the
///   emote without changing the row's layout.
struct EmotePlaceholder: View {
    let name: String
    let failed: Bool

    var body: some View {
        if failed {
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .foregroundStyle(.secondary)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
        }
    }
}
