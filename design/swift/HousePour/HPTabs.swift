// House Pour kit — HPTabs, the segmented control (COMPONENTS.md "Controls").
// This is the only segmented control in the look; never a system one.
// `hugging` sizes the control to its content (every segment as wide as the widest label)
// for the floating bottom bar; the default fills its container.

import SwiftUI

public struct HPTabs<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selected: Item
    let hugging: Bool
    let trackFill: Color
    let bottomPadded: Bool

    public init(items: [Item], selected: Binding<Item>, hugging: Bool = false,
                trackFill: Color = HPTokens.Colors.bg2, bottomPadded: Bool = true,
                label: @escaping (Item) -> String) {
        self.items = items; _selected = selected; self.hugging = hugging
        self.trackFill = trackFill; self.bottomPadded = bottomPadded; self.label = label
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
                    segmentLabel(item)
                        .padding(.vertical, HPTokens.Space.tabY)
                        .padding(.horizontal, HPTokens.Space.tabX)
                        .frame(maxWidth: hugging ? nil : .infinity)
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
        .background(track.fill(trackFill))
        .hpBorder(track)
        .padding(.bottom, bottomPadded ? HPTokens.Space.tabsBottom : 0)
    }

    /// In hugging mode every segment sizes to the widest label so widths stay equal
    /// while the control as a whole hugs its content.
    @ViewBuilder private func segmentLabel(_ item: Item) -> some View {
        let isSelected = item == selected
        let text = Text(label(item))
            .hpStyle(HPType.tab, color: isSelected ? HPTokens.Colors.ink : HPTokens.Colors.muted)
            .lineLimit(1)
            .minimumScaleFactor(HPMetric.tabLabelMinScale)
        if hugging {
            ZStack {
                ForEach(items, id: \.self) { other in
                    Text(label(other))
                        .hpStyle(HPType.tab, color: HPTokens.Colors.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(HPMetric.tabLabelMinScale)
                        .hidden()
                }
                text
            }
        } else {
            text
        }
    }
}

public extension HPTabs where Item == String {
    init(items: [String], selected: Binding<String>) {
        self.init(items: items, selected: selected) { $0 }
    }
}

/// The floating bottom tab bar (PRODUCT.md §1): the same segmented control, hugging its
/// content, `panel` fill, hairline line, pill radius, and the one card shadow so it reads
/// as a raised pill over scrolling content. The caller places it `cardGap` above the
/// safe-area bottom and hides it on Sign in, Setup, and inside full-screen viewers.
public struct HPFloatingTabs<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selected: Item

    public init(items: [Item], selected: Binding<Item>, label: @escaping (Item) -> String) {
        self.items = items; _selected = selected; self.label = label
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        HPTabs(items: items, selected: $selected, hugging: true,
               trackFill: HPTokens.Colors.panel, bottomPadded: false, label: label)
            .hpCardShadow(shape: shape, fill: HPTokens.Colors.panel)
    }
}
