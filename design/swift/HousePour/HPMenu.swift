// House Pour kit — HPMenu, HPKebabButton (PRODUCT.md §2.6).
//
// A kebab button and the menu it opens: a panel card at the card radius carrying the one card
// shadow. Wider than `columnMax` it is anchored under the button (flipping above it when there
// is no room below); at `columnMax` or narrower — every phone — it is a bottom sheet instead.
// Never SwiftUI's `Menu` — that paints system chrome. The presentation itself is
// animation-free; only the surface fades, per COMPONENTS.md rule 4.

import SwiftUI

/// One action row in an HPMenu.
public struct HPMenuItem: Identifiable {
    public let id = UUID()
    public let label: String
    public let action: () -> Void
    public init(_ label: String, action: @escaping () -> Void) {
        self.label = label; self.action = action
    }
}

/// A vertical three-dot button: ghost, `faint` dots drawn from tokens (ink while pressed), 40pt hit target.
public struct HPKebabButton: View {
    let label: String
    let action: () -> Void
    public init(label: String = "More", action: @escaping () -> Void) {
        self.label = label; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            VStack(spacing: HPMetric.kebabDotGap) {
                ForEach(0..<HPMetric.kebabDots, id: \.self) { _ in
                    // No fill: the dots take the style's foreground so they can step up on press.
                    Circle().frame(width: HPMetric.kebabDot, height: HPMetric.kebabDot)
                }
            }
            .hpTouchTarget()
        }
        .buttonStyle(HPKebabStyle())
        .accessibilityLabel(label)
    }
}

/// The ghost press: dots step `faint` → ink over `Motion.color`, plus the kit's 1pt press translate.
private struct HPKebabStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? HPTokens.Colors.ink : HPTokens.Colors.faint)
            .animation(HPMotion.color, value: configuration.isPressed)
            .offset(y: configuration.isPressed ? HPTokens.Motion.pressTranslateY : 0)
            .animation(HPMotion.press, value: configuration.isPressed)
    }
}

/// The kebab button plus its menu. The button measures its own frame at tap time, so the surface
/// can hang under it without a preference round-trip.
public struct HPMenu: View {
    let label: String
    let items: [HPMenuItem]
    @State private var anchor: CGRect = .zero
    @State private var isPresented = false

    public init(label: String = "More", items: [HPMenuItem]) {
        self.label = label; self.items = items
    }

    public var body: some View {
        GeometryReader { geo in
            HPKebabButton(label: label) {
                anchor = geo.frame(in: .global)
                // The surface fades itself in; the presentation must not slide.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { isPresented = true }
            }
        }
        .frame(width: HPTokens.Space.touchMin, height: HPTokens.Space.touchMin)
        .fullScreenCover(isPresented: $isPresented) {
            HPMenuSurface(anchor: anchor, items: items, isPresented: $isPresented)
                .presentationBackground(.clear)
        }
    }
}

/// The card's measured height, so the anchored menu knows whether it fits under the button.
private struct HPMenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The scrim and the card. Dismisses on a tap outside or a swipe down on the sheet.
struct HPMenuSurface: View {
    let anchor: CGRect
    let items: [HPMenuItem]
    @Binding var isPresented: Bool
    @State private var shown = false
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            // COMPONENTS.md: the anchored/sheet split is the column width, not the size class.
            let isSheet = geo.size.width <= HPTokens.Space.columnMax
            ZStack(alignment: .topLeading) {
                HPTokens.Colors.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                    .accessibilityLabel("Dismiss")
                    .accessibilityAddTraits(.isButton)
                if isSheet {
                    card
                        .gesture(DragGesture(minimumDistance: HPMetric.menuDismissDrag)
                            .onEnded { if $0.translation.height > HPMetric.menuDismissDrag { close() } })
                        .frame(maxWidth: HPTokens.Space.columnMax)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.horizontal, HPTokens.Space.columnSide)
                } else {
                    card
                        .frame(width: HPMetric.menuWidth)
                        .background(GeometryReader { inner in
                            Color.clear.preference(key: HPMenuHeightKey.self, value: inner.size.height)
                        })
                        .offset(x: anchoredX(in: geo.size.width, originX: origin.x),
                                y: anchoredY(in: geo.size.height, originY: origin.y))
                }
            }
            .onPreferenceChange(HPMenuHeightKey.self) { cardHeight = $0 }
        }
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(HPMotion.toast) { shown = true } }
    }

    /// Trailing-aligned with the button, kept a column side inside both screen edges.
    private func anchoredX(in width: CGFloat, originX: CGFloat) -> CGFloat {
        let trailing = anchor.maxX - originX - HPMetric.menuWidth
        let maxX = width - HPMetric.menuWidth - HPTokens.Space.columnSide
        return min(max(HPTokens.Space.columnSide, trailing), max(HPTokens.Space.columnSide, maxX))
    }

    /// Under the button, a `rowGap` below it — above it instead when the card would run off the bottom.
    private func anchoredY(in height: CGFloat, originY: CGFloat) -> CGFloat {
        let below = anchor.maxY - originY + HPTokens.Space.rowGap
        guard cardHeight > 0, below + cardHeight > height else { return below }
        return max(HPTokens.Space.columnSide, anchor.minY - originY - HPTokens.Space.rowGap - cardHeight)
    }

    private var card: some View {
        HPListCard {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    item.action()
                    close()
                } label: {
                    HPListItem(isLast: index == items.count - 1) {
                        HPBody(item.label)
                    }
                    .frame(minHeight: HPTokens.Space.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HPPressStyle())
                .accessibilityLabel(item.label)
            }
        }
    }

    /// Fades out over the toast duration, then tears the presentation down without an animation.
    private func close() {
        guard shown else { return }
        withAnimation(HPMotion.toast) { shown = false }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(HPTokens.Motion.toast))
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { isPresented = false }
        }
    }
}
