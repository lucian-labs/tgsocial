// House Pour kit — HPButton, HPButtonRow (COMPONENTS.md "Controls").

import SwiftUI

public enum HPButtonStyle: Equatable { case primary, accent, neutral, ghost, danger }
public enum HPButtonSize: Equatable { case regular, small }

/// Pill button. Full width by default; `.small` hugs content. One `primary` per screen.
public struct HPButton: View {
    let label: String
    let style: HPButtonStyle
    let size: HPButtonSize
    let isEnabled: Bool
    let action: () -> Void

    public init(_ label: String, style: HPButtonStyle = .neutral, size: HPButtonSize = .regular,
                enabled: Bool = true, action: @escaping () -> Void) {
        self.label = label; self.style = style; self.size = size; self.isEnabled = enabled; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            // The visible pill keeps the kit padding; only the hit area is padded out to the 40pt minimum.
            Text(label)
                .hpStyle(size == .small ? HPType.buttonSm : HPType.button, color: textColor)
                .lineLimit(1)
                .padding(.vertical, size == .small ? HPTokens.Space.buttonSmY : HPTokens.Space.buttonY)
                .padding(.horizontal, size == .small ? HPTokens.Space.buttonSmX : HPTokens.Space.buttonX)
                .frame(maxWidth: size == .small ? nil : .infinity)
                .background(background)
                .overlay(border)
                .frame(minHeight: HPTokens.Space.touchMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(HPPressStyle())
        .disabled(!isEnabled)
        .compositingGroup()
        .opacity(isEnabled ? 1 : HPAlpha.disabled)
        .accessibilityLabel(label)
    }

    private var textColor: Color {
        switch style {
        case .primary: return HPTokens.Colors.primaryText
        case .accent: return HPTokens.Colors.charcoalText
        case .neutral: return HPTokens.Colors.ink
        case .ghost: return HPTokens.Colors.muted
        case .danger: return HPTokens.Colors.bad
        }
    }

    @ViewBuilder private var background: some View {
        let shape = Capsule(style: .continuous)
        switch style {
        case .primary:
            shape.fill(LinearGradient(colors: [HPTokens.Colors.primaryGradientStart, HPTokens.Colors.primaryGradientEnd],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .hpShadow(HPTokens.Shadow.primaryButton, shape: shape, fill: HPTokens.Colors.primaryGradientEnd)
        case .accent:
            shape.fill(LinearGradient(colors: [HPTokens.Colors.charcoalGradientStart, HPTokens.Colors.charcoalGradientEnd],
                                      startPoint: HPBackdrop.point(angleDegrees: 150, start: true),
                                      endPoint: HPBackdrop.point(angleDegrees: 150, start: false)))
                .hpShadow(HPTokens.Shadow.charcoalButton, shape: shape, fill: HPTokens.Colors.charcoalGradientEnd)
        case .danger:
            shape.fill(HPTokens.Colors.bad.opacity(HPAlpha.dangerFill))
        case .neutral, .ghost:
            shape.fill(Color.clear)
        }
    }

    @ViewBuilder private var border: some View {
        let shape = Capsule(style: .continuous)
        switch style {
        case .neutral: shape.strokeBorder(HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth)
        case .danger: shape.strokeBorder(HPTokens.Colors.bad.opacity(HPAlpha.dangerLine), lineWidth: HPTokens.borderWidth)
        default: EmptyView()
        }
    }
}

/// Pressed: translate down 1pt over the press duration. The one transform in the look.
public struct HPPressStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? HPTokens.Motion.pressTranslateY : 0)
            .animation(HPMotion.press, value: configuration.isPressed)
    }
}

/// Two buttons side by side, equal widths. The only side-by-side layout in the look.
public struct HPButtonRow<A: View, B: View>: View {
    let a: A
    let b: B
    public init(@ViewBuilder a: () -> A, @ViewBuilder b: () -> B) { self.a = a(); self.b = b() }
    public var body: some View {
        HStack(spacing: HPTokens.Space.btnRowGap) {
            a.frame(maxWidth: .infinity)
            b.frame(maxWidth: .infinity)
        }
    }
}
