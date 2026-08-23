// House Pour kit — HPListItem (COMPONENTS.md).

import SwiftUI

/// A row inside a card: rowPad vertical, hairline below except on the last row.
public struct HPListItem<Leading: View, Trailing: View>: View {
    let isLast: Bool
    let leading: Leading
    let trailing: Trailing
    public init(isLast: Bool = false, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.isLast = isLast; self.leading = leading(); self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            leading
            Spacer(minLength: HPTokens.Space.rowGap)
            trailing
        }
        .padding(.vertical, HPTokens.Space.rowPad)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(HPTokens.Colors.line).frame(height: HPTokens.borderWidth) }
        }
    }
}

public extension HPListItem where Trailing == EmptyView {
    init(isLast: Bool = false, @ViewBuilder leading: () -> Leading) {
        self.init(isLast: isLast, leading: leading, trailing: { EmptyView() })
    }
}

/// Rows stacked inside a card, with the first row's top padding and last row's bottom padding trimmed
/// so the card pad is the outer edge.
public struct HPListCard<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        HPCard(padded: false) {
            VStack(spacing: 0) { content }
                .padding(.horizontal, HPTokens.Space.cardPad)
                .padding(.vertical, HPTokens.Space.cardPad - HPTokens.Space.rowPad)
        }
    }
}
