// House Pour kit — HPBackdrop (COMPONENTS.md).

import SwiftUI

/// The page background: three-stop ivory gradient at 165° with the gold and violet washes. Fixed; does not scroll.
public struct HPBackdrop: View {
    public init() {}
    public var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: HPTokens.Colors.backdropTop, location: 0),
                        .init(color: HPTokens.Colors.backdropMid, location: 0.55),
                        .init(color: HPTokens.Colors.backdropBottom, location: 1),
                    ],
                    startPoint: Self.point(angleDegrees: 165, start: true),
                    endPoint: Self.point(angleDegrees: 165, start: false)
                )
                RadialGradient(
                    colors: [HPTokens.Colors.washGold, .clear],
                    center: UnitPoint(x: 0.2, y: -0.1),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.45
                )
                RadialGradient(
                    colors: [HPTokens.Colors.washViolet, .clear],
                    center: UnitPoint(x: 0.9, y: 0.08),
                    startRadius: 0,
                    endRadius: geo.size.width * 0.35
                )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// CSS linear-gradient angle → SwiftUI unit points (0° = up, clockwise).
    static func point(angleDegrees: Double, start: Bool) -> UnitPoint {
        let r = angleDegrees * .pi / 180
        let dx = sin(r) / 2, dy = -cos(r) / 2
        return start ? UnitPoint(x: 0.5 - dx, y: 0.5 - dy) : UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
    }
}
