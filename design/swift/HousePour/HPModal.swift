// House Pour kit — HPModal (COMPONENTS.md).

import SwiftUI

/// A card centred over the scrim, cast shadow deepened. Fades in; never dark.
public struct HPModal<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let modal: ModalContent
    public init(isPresented: Binding<Bool>, @ViewBuilder content: () -> ModalContent) {
        _isPresented = isPresented; modal = content()
    }
    public func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                HPTokens.Colors.scrim
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }
                    .accessibilityLabel("Dismiss")
                    .accessibilityAddTraits(.isButton)
                let shape = RoundedRectangle(cornerRadius: HPTokens.Radius.card, style: .continuous)
                VStack(alignment: .leading, spacing: 0) { modal }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HPTokens.Space.cardPad)
                    .background(shape.fill(HPTokens.Colors.panel))
                    .hpBorder(shape)
                    .hpCardShadow(shape: shape, fill: HPTokens.Colors.panel, castMultiplier: HPAlpha.modalCast)
                    .frame(maxWidth: HPTokens.Space.columnMax - HPTokens.Space.columnSide * 2)
                    .padding(.horizontal, HPTokens.Space.columnSide)
                    .transition(.opacity)
            }
        }
        .animation(HPMotion.toast, value: isPresented)
    }
}

public extension View {
    func hpModal<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: () -> C) -> some View {
        modifier(HPModal(isPresented: isPresented, content: content))
    }
}
