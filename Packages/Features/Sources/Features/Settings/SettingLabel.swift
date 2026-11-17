import SwiftUI

/// Standard label for a settings row: icon, title, and an optional one-line
/// subtitle underneath.
///
/// ## Conventions (apply on every settings screen)
///
/// - Give a toggle a `subtitle` when its effect isn't obvious from the title
///   ("Experimental: picture-in-picture and quality control"). Obvious ones
///   ("Timestamps") don't need one.
/// - A setting that depends on another is `.disabled(...)` and its subtitle
///   says why — pass `disabledReason:`, which replaces the subtitle while
///   the row is disabled ("Needs Native Video Player on").
/// - Section footers explain *consequences* (what changes, when it applies,
///   what it costs), not what the row title already says.
/// - Don't repeat the section header in row titles.
struct SettingLabel: View {
    let title: String
    let systemImage: String
    var subtitle: String? = nil
    /// Shown instead of `subtitle` when non-nil. Pair with `.disabled(...)`
    /// on the control so the reason and the state never disagree.
    var disabledReason: String? = nil

    init(_ title: String, systemImage: String, subtitle: String? = nil, disabledReason: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.disabledReason = disabledReason
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail = disabledReason ?? subtitle {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
