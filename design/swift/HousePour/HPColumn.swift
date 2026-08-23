// House Pour kit — HPColumn (COMPONENTS.md).

import SwiftUI

/// The single column: max `columnMax`, side padding `columnSide`, bottom padding `bottomSafe`.
public struct HPColumn<Content: View>: View {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .frame(maxWidth: HPTokens.Space.columnMax)
            .padding(.horizontal, HPTokens.Space.columnSide)
            .padding(.bottom, HPTokens.Space.bottomSafe)
            .frame(maxWidth: .infinity)
    }
}
