import SwiftUI

/// Ambient accent-tinted gradient drawn behind the top of a screen — a
/// colored "sky" under the navigation title instead of flat system
/// background. Shared by Home and the Following browse screen so pushing
/// between them doesn't jump between two different background worlds.
///
/// Derived from `accentColor` (not a hardcoded blue) so retinting the app
/// in the asset catalog retints every wash for free.
///
/// Usage, on a `List`/`ScrollView` whose rows are transparent
/// (`.scrollContentBackground(.hidden)` + `.listRowBackground(Color.clear)`):
///
///     .background(alignment: .top) { AccentTopWash() }
struct AccentTopWash: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 280)
        .ignoresSafeArea(edges: .top)
    }
}
