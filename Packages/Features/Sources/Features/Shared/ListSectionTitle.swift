import SwiftUI

/// A section title rendered as an ordinary list row ("Live", "Offline").
/// Plain-style `List` section headers pin to the top as a translucent bar
/// for as long as their section is on screen; a row just scrolls away.
struct ListSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityAddTraits(.isHeader)
    }
}
