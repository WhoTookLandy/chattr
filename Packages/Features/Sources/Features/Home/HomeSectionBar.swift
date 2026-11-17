import SwiftUI

/// Twitch-style text tabs across the top of Home: "Live  Following", the
/// selected one bold with an underline. The sections also page with a
/// horizontal swipe (`HomeScreen`); the underline follows either way.
struct HomeSectionBar: View {
    @Binding var selection: HomeSection

    @Namespace private var underline

    var body: some View {
        HStack(spacing: 22) {
            ForEach(HomeSection.allCases, id: \.self) { section in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = section }
                } label: {
                    label(for: section)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func label(for section: HomeSection) -> some View {
        let isSelected = selection == section
        return Text(section.title)
            .font(.title3.weight(isSelected ? .bold : .semibold))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.bottom, 9)
            // Underline as an overlay so it's exactly the label's width; the
            // matched geometry slides it between sections on selection.
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(.primary)
                        .frame(height: 3)
                        .matchedGeometryEffect(id: "underline", in: underline)
                }
            }
            .contentShape(Rectangle())
    }
}
