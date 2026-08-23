// House Pour kit — HPToast (COMPONENTS.md).

import SwiftUI

public enum HPToastTone: Equatable { case neutral, good, bad }

public struct HPToastMessage: Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let tone: HPToastTone
    public init(_ text: String, tone: HPToastTone = .neutral) { id = UUID(); self.text = text; self.tone = tone }
    public static let autoDismiss: Double = 2.8
}

/// Inverted ink pill, fixed bottom centre, 26pt up. Fades; never slides.
public struct HPToast: View {
    let message: HPToastMessage
    public init(_ message: HPToastMessage) { self.message = message }
    private var lineColor: Color {
        switch message.tone {
        case .neutral: return HPTokens.Colors.toastLine
        case .good: return HPTokens.Colors.good.opacity(HPAlpha.toastTone)
        case .bad: return HPTokens.Colors.bad.opacity(HPAlpha.toastTone)
        }
    }
    public var body: some View {
        let shape = Capsule(style: .continuous)
        Text(message.text)
            .hpStyle(HPType.toast, color: HPTokens.Colors.toastText)
            .multilineTextAlignment(.center)
            .padding(.vertical, HPTokens.Space.buttonY)
            .padding(.horizontal, HPTokens.Space.topbarX)
            .background(shape.fill(HPTokens.Colors.toastBg))
            .hpBorder(shape, color: lineColor)
            .hpShadow(HPTokens.Shadow.toast, shape: shape, fill: HPTokens.Colors.toastBg)
            .accessibilityAddTraits(.isStaticText)
    }
    /// Distance from the bottom edge (the upstream `bottom: 26px`).
    public static let bottomOffset: CGFloat = HPTokens.Space.rowPad + HPTokens.Space.inputBottom
}

/// Hosts the toast over content, fading it in and out.
public struct HPToastHost: ViewModifier {
    @Binding var message: HPToastMessage?
    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                HPToast(message)
                    .padding(.bottom, HPToast.bottomOffset)
                    .padding(.horizontal, HPTokens.Space.columnSide)
                    .transition(.opacity)
                    .id(message.id)
            }
        }
        .animation(HPMotion.toast, value: message)
    }
}

public extension View {
    func hpToastHost(_ message: Binding<HPToastMessage?>) -> some View { modifier(HPToastHost(message: message)) }
}
