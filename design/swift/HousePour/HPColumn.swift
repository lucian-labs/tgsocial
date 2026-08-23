// House Pour kit — HPColumn (COMPONENTS.md).

import SwiftUI

/// The single column: max `columnMax`, side padding `columnSide`, bottom padding `bottomSafe`.
/// `bottomPadded: false` drops the bottomSafe pad for scroll views whose bottom inset is
/// already provided by the floating tab bar (PRODUCT §1).
public struct HPColumn<Content: View>: View {
    let bottomPadded: Bool
    let content: Content
    public init(bottomPadded: Bool = true, @ViewBuilder content: () -> Content) {
        self.bottomPadded = bottomPadded; self.content = content()
    }
    public var body: some View {
        content
            .frame(maxWidth: HPTokens.Space.columnMax)
            .padding(.horizontal, HPTokens.Space.columnSide)
            .padding(.bottom, bottomPadded ? HPTokens.Space.bottomSafe : HPTokens.Space.cardGap)
            .frame(maxWidth: .infinity)
    }
}
