// House Pour kit — HPCard (COMPONENTS.md).

import SwiftUI

/// The only raised surface: panel fill, hairline border, card radius, contact + cast shadow.
public struct HPCard<Content: View>: View {
    let padded: Bool
    let content: Content
    public init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.padded = padded; self.content = content()
    }
    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: HPTokens.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padded ? HPTokens.Space.cardPad : 0)
            .background(shape.fill(HPTokens.Colors.panel))
            .hpBorder(shape)
            .hpCardShadow(shape: shape, fill: HPTokens.Colors.panel)
            .padding(.bottom, HPTokens.Space.cardGap)
    }
}
