// House Pour kit — HPTopbar (COMPONENTS.md).

import SwiftUI

/// Sticky translucent bar: leading (wordmark or back), trailing (status pill), hairline below.
/// Translucency is the `topbarBg` token alone (85% alpha). Upstream adds `backdrop-filter: blur(14px)`;
/// SwiftUI has no blur-behind primitive with a settable radius, so nothing stands in for it.
public struct HPTopbar<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing
    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading(); self.trailing = trailing()
    }
    public var body: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            leading
            Spacer(minLength: HPTokens.Space.rowGap)
            trailing
        }
        .frame(maxWidth: HPTokens.Space.columnMax)
        .padding(.vertical, HPTokens.Space.topbarY)
        .padding(.horizontal, HPTokens.Space.topbarX)
        .frame(maxWidth: .infinity)
        .background(HPTokens.Colors.topbarBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(HPTokens.Colors.line).frame(height: HPTokens.borderWidth)
        }
    }
}
