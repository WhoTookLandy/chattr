import SwiftUI

/// A Settings-root row for one category: tinted icon tile, title, and the
/// category's one-line summary of what's inside.
struct SettingsCategoryRow: View {
    let category: SettingsCategory

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemImage: category.systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                Text(category.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The rounded, accent-filled icon square used by category rows and search
/// results — the app's purple accent, white glyph.
struct SettingsIconTile: View {
    let systemImage: String
    var side: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: side * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: side * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One search hit: the setting's title and where it lives
/// ("Chat › Filters").
struct SettingsSearchResultRow: View {
    let entry: SettingsEntry

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemImage: entry.category.systemImage, side: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                Text(entry.breadcrumb)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
