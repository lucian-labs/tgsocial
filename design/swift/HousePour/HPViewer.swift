// House Pour kit — HPViewer (PRODUCT.md §2.11): the full-screen media viewer chrome.
// Ink at 96% — with the toast, the only dark surfaces in the look. Close and one action
// as ghost buttons in charcoalText, an optional serif counter for albums, the caption
// below in charcoalText. Content (the swipeable pages) is the caller's.

import SwiftUI

public struct HPViewer<Content: View>: View {
    let counter: String?
    let caption: String
    let actionLabel: String?
    let onAction: (() -> Void)?
    let onClose: () -> Void
    let content: Content

    public init(counter: String? = nil, caption: String = "",
                actionLabel: String? = nil, onAction: (() -> Void)? = nil,
                onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.counter = counter; self.caption = caption
        self.actionLabel = actionLabel; self.onAction = onAction
        self.onClose = onClose; self.content = content()
    }

    public var body: some View {
        ZStack {
            HPTokens.Colors.ink.opacity(HPAlpha.viewerBackdrop)
                .ignoresSafeArea()
            content
            VStack(spacing: 0) {
                ZStack {
                    if let counter {
                        Text(counter)
                            .hpStyle(HPType.totals, color: HPTokens.Colors.charcoalText)
                            .accessibilityLabel("Item \(counter)")
                    }
                    HStack {
                        HPButton("Close", style: .ghostOnInk, size: .small, action: onClose)
                        Spacer(minLength: HPTokens.Space.rowGap)
                        if let actionLabel, let onAction {
                            HPButton(actionLabel, style: .ghostOnInk, size: .small, action: onAction)
                        }
                    }
                }
                .padding(.horizontal, HPTokens.Space.columnSide)
                .padding(.top, HPTokens.Space.pillY)
                Spacer(minLength: 0)
                if !caption.isEmpty {
                    Text(caption)
                        .hpStyle(HPType.body, color: HPTokens.Colors.charcoalText)
                        .lineLimit(4)
                        .frame(maxWidth: HPTokens.Space.columnMax, alignment: .leading)
                        .padding(.horizontal, HPTokens.Space.columnSide + HPTokens.Space.rowGap)
                        .padding(.bottom, HPTokens.Space.rowPad)
                }
            }
        }
    }
}
