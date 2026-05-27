import SwiftUI

/// Horizontal pill strip showing one cell per open chat channel. Active cell
/// is filled with the accent color; inactive cells use a subtle tertiary
/// background. Each cell carries an X close button; the strip ends with a
/// + button that triggers `onAddTab` (AppShell wires this to "switch to
/// Follows tab").
///
/// The strip is hidden by ChatTabsScreen when no tabs are open — empty state
/// is the more informative UI in that case.
struct ChatTabStrip: View {
    @Bindable var model: ChatTabsModel
    let onAddTab: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.openChannels) { channel in
                    TabCell(
                        channel: channel,
                        isActive: model.activeChannelId == channel.channelId,
                        onTap: { model.activeChannelId = channel.channelId },
                        onClose: { model.close(channelId: channel.channelId) }
                    )
                }

                AddTabButton(action: onAddTab)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)  // matches navigation/toolbar material on iOS 26
    }
}

/// One pill in the tab strip. Tapping the body activates the tab; tapping
/// the X removes it. The X is rendered as a Button so VoiceOver can target
/// it independently of the cell tap.
private struct TabCell: View {
    let channel: OpenChannelDescriptor
    let isActive: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let url = channel.profileImageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(Circle())
            }

            Text("#\(channel.channelLoginName)")
                .font(.callout.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close \(channel.channelDisplayName)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            (isActive ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)),
            in: Capsule()
        )
        // Tap anywhere on the cell (except the X) to activate. The X is a
        // separate Button so its tap consumes the gesture and doesn't bubble.
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(channel.channelDisplayName), \(isActive ? "active" : "inactive")")
    }
}

/// Circular "+" button at the end of the strip. Visually distinct from
/// channel pills so it reads as "action," not "current tab."
private struct AddTabButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.callout.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add channel")
    }
}
