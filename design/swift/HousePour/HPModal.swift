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
                let card = VStack(alignment: .leading, spacing: 0) { modal }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HPTokens.Space.cardPad)
                // The card is bounded by the space it is given and scrolls inside when its content
                // is taller than that — the same bound the other two kits carry (`HPModal.kt`'s
                // `verticalScroll`, `.modal-card`'s `max-height` + `overflow-y`). Without it a modal
                // taller than the phone puts its own buttons off-window: the report confirm
                // (PRODUCT §2.15) is 755pt at default Dynamic Type and there is no other route to
                // report anything, so `Send Report` and `Cancel` have to be reachable on a 375×667
                // phone (PRODUCT §5: "iPhone and iPad") and at every type size above it.
                //
                // `ViewThatFits` keeps the natural, content-sized card whenever it fits, so the
                // short confirms are centred and unscrollable exactly as before; only one that
                // would run off the screen becomes a scroller.
                ViewThatFits(in: .vertical) {
                    card
                    ScrollView(.vertical) { card }
                }
                .background(shape.fill(HPTokens.Colors.panel))
                .hpBorder(shape)
                .hpCardShadow(shape: shape, fill: HPTokens.Colors.panel, castMultiplier: HPAlpha.modalCast)
                .frame(maxWidth: HPTokens.Space.columnMax - HPTokens.Space.columnSide * 2)
                .padding(.horizontal, HPTokens.Space.columnSide)
                // The same `columnSide` inset the sides already had, so a full-height card stops
                // short of the safe area rather than running into it.
                .padding(.vertical, HPTokens.Space.columnSide)
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
