// House Pour kit — HPTabs, the segmented control (COMPONENTS.md "Controls").
// This is the only segmented control in the look; never a system one.

import SwiftUI

public struct HPTabs<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selected: Item

    public init(items: [Item], selected: Binding<Item>, label: @escaping (Item) -> String) {
        self.items = items; _selected = selected; self.label = label
    }

    public var body: some View {
        let track = Capsule(style: .continuous)
        HStack(spacing: HPTokens.Space.tabsGap) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selected
                Button {
                    withAnimation(HPMotion.color) { selected = item }
                } label: {
                    // The track's vertical inset lives inside the button so the tappable segment spans
                    // the full track height (≥ touchMin); the selected pill stays inset by tabsPad.
                    Text(label(item))
                        .hpStyle(HPType.tab, color: isSelected ? HPTokens.Colors.ink : HPTokens.Colors.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(HPMetric.tabLabelMinScale)
                        .padding(.vertical, HPTokens.Space.tabY)
                        .padding(.horizontal, HPTokens.Space.tabX)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? HPTokens.Colors.panel : Color.clear)
                                .shadow(color: HPTokens.Colors.ink.opacity(isSelected ? HPAlpha.tabShadow : 0),
                                        radius: HPTokens.borderWidth, x: 0, y: HPTokens.borderWidth)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(isSelected ? HPTokens.Colors.line : Color.clear, lineWidth: HPTokens.borderWidth)
                        )
                        .padding(.vertical, HPTokens.Space.tabsPad)
                        .frame(minHeight: HPTokens.Space.touchMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(item))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.horizontal, HPTokens.Space.tabsPad)
        .background(track.fill(HPTokens.Colors.bg2))
        .hpBorder(track)
        .padding(.bottom, HPTokens.Space.tabsBottom)
    }
}

public extension HPTabs where Item == String {
    init(items: [String], selected: Binding<String>) {
        self.init(items: items, selected: selected) { $0 }
    }
}
