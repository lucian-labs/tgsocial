// House Pour kit — HPStepper (upstream `.stepper`; kept in the kit, unused by tgsocial v1).

import SwiftUI

public struct HPStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: String

    public init(value: Binding<Int>, in range: ClosedRange<Int>, label: String) {
        _value = value; self.range = range; self.label = label
    }

    public var body: some View {
        HStack(spacing: HPTokens.Space.rowGap) {
            stepButton("\u{2212}", enabled: value > range.lowerBound) { value -= 1 }
            Text(String(value)).hpStyle(HPType.totals)
                .frame(minWidth: HPTokens.Space.touchMin)
            stepButton("+", enabled: value < range.upperBound) { value += 1 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(String(value))
    }

    private func stepButton(_ glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .hpStyle(HPType.totals)
                .frame(width: HPTokens.Space.touchMin, height: HPTokens.Space.touchMin)
                .background(Circle().fill(HPTokens.Colors.panel))
                .overlay(Circle().strokeBorder(HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth))
                .contentShape(Circle())
        }
        .buttonStyle(HPPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : HPAlpha.disabled)
        .accessibilityLabel(glyph == "+" ? "Increase" : "Decrease")
    }
}
