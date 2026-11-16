import SwiftUI

/// Twitch-style text tabs across the top of Home: "Live  Following  Chats",
/// the selected one bold with an underline. Chats carries a red count of
/// open chats with unseen @-mentions.
///
/// Reads `chatTabs.mentionedTabIds` here (not in `HomeScreen`) so a
/// background ping redraws the bar, not the whole Home body.
struct HomeSectionBar: View {
    @Binding var selection: HomeSection

    @Environment(\.chatTabs) private var chatTabs
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
        return HStack(spacing: 4) {
            Text(section.title)
                .font(.title3.weight(isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
            if section == .chats, mentionCount > 0 {
                Text("\(mentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.red, in: Capsule())
                    .accessibilityLabel("\(mentionCount) with mentions")
            }
        }
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

    private var mentionCount: Int {
        chatTabs?.mentionedTabIds.count ?? 0
    }
}
