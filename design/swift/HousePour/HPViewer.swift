// House Pour kit — HPViewer (PRODUCT.md §2.11, §2.12): the full-screen media viewer chrome.
// Ink at 96% — with the toast, the only dark surfaces in the look. Close and the viewer's actions
// as ghost buttons in charcoalText, an optional serif counter for albums, the caption below in
// charcoalText. Content (the swipeable pages, and the comment sheet when it is open) is the
// caller's.
//
// The trailing group is a LIST of actions rather than one, because §2.12 puts `Comments` beside
// `Save`. They are `HPButton .ghostOnInk .small`, so each simply *is* `touchMin` tall — rule 6 with
// no overlay needed.
//
// The chrome column spans the screen but is only hit-testable where it actually paints: a `VStack`
// and a `Spacer` have no shape of their own, so the caller's content keeps every touch that does
// not land on a button or the caption.

import SwiftUI

/// The viewer's own metrics.
public enum HPViewerChrome {
    /// The height the chrome row occupies at the top of the viewer: one hit target plus the gap
    /// above it. A caller that pins content under the chrome (the §2.12 mini view) insets by this.
    public static var height: CGFloat { HPTokens.Space.touchMin + HPTokens.Space.pillY }
}

/// One control in the viewer's trailing group.
public struct HPViewerAction: Identifiable {
    public let label: String
    public let action: () -> Void
    public var id: String { label }
    public init(_ label: String, action: @escaping () -> Void) {
        self.label = label; self.action = action
    }
}

public struct HPViewer<Content: View>: View {
    let counter: String?
    let caption: String
    let actions: [HPViewerAction]
    let onClose: () -> Void
    let content: Content

    public init(counter: String? = nil, caption: String = "",
                actions: [HPViewerAction] = [],
                onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.counter = counter; self.caption = caption
        self.actions = actions
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
                        ForEach(actions) { action in
                            HPButton(action.label, style: .ghostOnInk, size: .small, action: action.action)
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
