// House Pour kit — HPToggle (COMPONENTS.md "Controls").
// No system switch: a pill track, a panel knob, colour animating over Motion.color.

import SwiftUI

public struct HPToggle: View {
    @Binding var isOn: Bool
    let label: String
    let isEnabled: Bool

    public init(isOn: Binding<Bool>, label: String, enabled: Bool = true) {
        _isOn = isOn; self.label = label; self.isEnabled = enabled
    }

    public var body: some View {
        let track = Capsule(style: .continuous)
        Button {
            withAnimation(HPMotion.color) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                track.fill(isOn ? HPTokens.Colors.accentSoft : HPTokens.Colors.bg2)
                    .overlay(track.strokeBorder(isOn ? HPTokens.Colors.accent : HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth))
                Circle()
                    .fill(HPTokens.Colors.panel)
                    .frame(width: HPMetric.toggleKnob, height: HPMetric.toggleKnob)
                    .shadow(color: HPTokens.Shadow.contact.color, radius: HPTokens.Shadow.contact.blur / 2,
                            x: HPTokens.Shadow.contact.x, y: HPTokens.Shadow.contact.y)
                    .overlay(Circle().strokeBorder(HPTokens.Colors.line, lineWidth: HPTokens.borderWidth))
                    .padding((HPMetric.toggleHeight - HPMetric.toggleKnob) / 2)
            }
            .frame(width: HPMetric.toggleWidth, height: HPMetric.toggleHeight)
            .hpTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .compositingGroup()
        .opacity(isEnabled ? 1 : HPAlpha.disabled)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
