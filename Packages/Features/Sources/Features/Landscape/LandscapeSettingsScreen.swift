import SwiftUI

/// Settings → Video & Device → Landscape Layout: how chat and the stream share the screen
/// when the phone is turned sideways.
///
/// Rows read/write `LandscapeSettings` keys via `@AppStorage`. Reached as
/// `SettingsDestination.landscape`; each row has a `SettingsRegistry` entry
/// (`to: .landscape`) — keep titles in step.
struct LandscapeSettingsScreen: View {
    @AppStorage(LandscapeSettings.layoutKey) private var layoutMode: LandscapeLayoutMode = .beside
    @AppStorage(LandscapeSettings.chatSideKey) private var chatSide: LandscapeChatSide = .right
    @AppStorage(LandscapeSettings.overlayOpacityKey) private var overlayOpacity = LandscapeSettings.defaultOverlayOpacity
    @AppStorage(LandscapeSettings.chatWidthKey) private var chatWidth = LandscapeSettings.defaultChatWidth

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(LandscapeLayoutMode.allCases) { mode in
                        layoutOption(mode)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Layout")
            } footer: {
                Text("Turn your phone sideways while a stream is playing to watch it with chat. Drag the divider between them to resize the chat.")
            }

            Section {
                Picker("Chat Side", selection: $chatSide) {
                    ForEach(LandscapeChatSide.allCases) { side in
                        Text(side.label).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                if layoutMode == .overlay {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Chat Background")
                            Spacer()
                            Text(overlayOpacity, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $overlayOpacity, in: LandscapeSettings.overlayOpacityRange) {
                            Text("Chat Background Opacity")
                        } minimumValueLabel: {
                            Image(systemName: "circle.dotted")
                        } maximumValueLabel: {
                            Image(systemName: "circle.fill")
                        }
                    }
                }

                Button("Reset Chat Width") {
                    chatWidth = LandscapeSettings.defaultChatWidth
                }
                .disabled(chatWidth == LandscapeSettings.defaultChatWidth)
            } header: {
                Text("Chat")
            } footer: {
                if layoutMode == .overlay {
                    Text("Lower opacity shows more of the stream behind chat.")
                }
            }
        }
        .navigationTitle("Landscape Layout")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .animation(.snappy(duration: 0.2), value: layoutMode)
    }

    /// One selectable layout: its diagram above its name.
    private func layoutOption(_ mode: LandscapeLayoutMode) -> some View {
        let selected = layoutMode == mode
        return Button {
            layoutMode = mode
        } label: {
            VStack(spacing: 8) {
                LandscapeLayoutDiagram(mode: mode, side: chatSide, isSelected: selected)
                HStack(spacing: 4) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(mode.label)
                        .font(.footnote.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
