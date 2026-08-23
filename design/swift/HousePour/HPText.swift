// House Pour kit — type components (COMPONENTS.md "Type").
// Each is one HPTokens.Type style + one colour.

import SwiftUI

public struct HPWordmark: View {
    let text: String
    let topbar: Bool
    public init(_ text: String, topbar: Bool = false) { self.text = text; self.topbar = topbar }
    public var body: some View {
        Text(text).hpStyle(topbar ? HPType.brand : HPType.wordmark)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct HPH1: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).hpStyle(HPType.h1).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct HPH2: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).hpStyle(HPType.h2).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

public struct HPFieldLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).hpStyle(HPType.fieldLabel, color: HPTokens.Colors.muted)
            .padding(.bottom, HPTokens.Space.labelBottom)
    }
}

public struct HPBody: View {
    let text: String
    let strong: Bool
    public init(_ text: String, strong: Bool = false) { self.text = text; self.strong = strong }
    public var body: some View {
        Text(text).hpStyle(strong ? HPType.bodyStrong : HPType.body)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct HPMuted: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).hpStyle(HPType.body, color: HPTokens.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct HPSmall: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = HPTokens.Colors.muted) { self.text = text; self.color = color }
    public var body: some View {
        Text(text).hpStyle(HPType.small, color: color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct HPMono: View {
    let text: String
    let small: Bool
    let color: Color
    public init(_ text: String, small: Bool = false, color: Color = HPTokens.Colors.muted) {
        self.text = text; self.small = small; self.color = color
    }
    public var body: some View {
        Text(text).hpStyle(small ? HPType.monoSmall : HPType.mono, color: color)
    }
}

public struct HPMonoSmall: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = HPTokens.Colors.muted) { self.text = text; self.color = color }
    public var body: some View { HPMono(text, small: true, color: color) }
}

public struct HPFigure: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).hpStyle(HPType.figure)
    }
}

/// Section mark: uppercase label, optional serif count, trailing hairline fading to clear.
public struct HPSectionMark: View {
    let text: String
    let count: Int?
    public init(_ text: String, count: Int? = nil) { self.text = text; self.count = count }
    public var body: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            Text(text).hpStyle(HPType.sectionMark, color: HPTokens.Colors.muted)
            if let count {
                Text("\u{00B7}").hpStyle(HPType.sectionMark, color: HPTokens.Colors.muted)
                Text(String(count)).hpStyle(HPType.totals)
            }
            LinearGradient(colors: [HPTokens.Colors.line2, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(height: HPTokens.borderWidth)
        }
        .padding(.bottom, HPTokens.Space.rowPad)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
