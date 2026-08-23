// House Pour kit — SwiftUI foundation (hand-written against HousePourTokens.swift).
// Fonts, text style application, Dynamic Type clamp, shadow and border helpers.
// Every value here is a token; nothing is typed by hand.

import SwiftUI

/// `HPTokens.Type` is the generated type ramp. Swift cannot spell a nested type named `Type` without
/// backticks, so the kit refers to it through this alias everywhere.
public typealias HPType = HPTokens.`Type`

// MARK: - Dynamic Type scale (clamped at 1.4x, COMPONENTS.md rule 7)

public enum HPScale {
    public static let max: CGFloat = 1.4
    public static func clamp(_ raw: CGFloat) -> CGFloat { min(Swift.max(raw, 0.0), max) }
}

/// Reads the system content-size scale via ScaledMetric and clamps it.
@propertyWrapper
public struct HPScaledFactor: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var raw: CGFloat = 1
    public init() {}
    public var wrappedValue: CGFloat { HPScale.clamp(raw) }
}

// MARK: - Fonts

public enum HPFont {
    /// PostScript name for a face + numeric weight, resolved against the bundled/system names in the tokens.
    public static func name(face: HPFace, weight: Int, italic: Bool = false) -> String {
        switch face {
        case .brand:
            return HPTokens.FontName.brand
        case .display:
            if italic { return HPTokens.FontName.displayMediumItalic }
            if weight >= 700 { return HPTokens.FontName.displayBold }
            if weight >= 600 { return HPTokens.FontName.displaySemiBold }
            return HPTokens.FontName.displayMedium
        case .mono:
            return weight >= 600 ? HPTokens.FontName.monoSemiBold : HPTokens.FontName.monoRegular
        case .body:
            if weight >= 700 { return HPTokens.FontName.bodyBold }
            if weight >= 600 { return HPTokens.FontName.bodyDemiBold }
            if weight >= 500 { return HPTokens.FontName.bodyMedium }
            return HPTokens.FontName.bodyRegular
        }
    }

    public static func font(_ style: HPTextStyle, scale: CGFloat, italic: Bool = false, weight: Int? = nil) -> Font {
        Font.custom(name(face: style.face, weight: weight ?? style.weight, italic: italic), fixedSize: style.size * scale)
    }
}

// MARK: - Text style modifier

public struct HPTextStyleModifier: ViewModifier {
    let style: HPTextStyle
    let color: Color
    @HPScaledFactor private var scale

    public func body(content: Content) -> some View {
        content
            .font(HPFont.font(style, scale: scale))
            .tracking(style.trackingPoints * scale)
            .lineSpacing(style.lineSpacing * scale)
            .textCase(style.uppercase ? .uppercase : nil)
            .foregroundStyle(color)
    }
}

public extension View {
    func hpStyle(_ style: HPTextStyle, color: Color = HPTokens.Colors.ink) -> some View {
        modifier(HPTextStyleModifier(style: style, color: color))
    }
}

// MARK: - Shadows (CSS box-shadow → SwiftUI)

public extension View {
    /// Draws `shape` behind the view carrying one token shadow. CSS blur ≈ 2× SwiftUI radius; negative spread insets the casting shape.
    func hpShadow<S: Shape>(_ shadow: HPShadow, shape: S, fill: Color) -> some View {
        background(
            shape
                .fill(fill)
                .padding(-shadow.spread)
                .shadow(color: shadow.color, radius: shadow.blur / 2, x: shadow.x, y: shadow.y)
        )
    }

    /// The one raised-surface shadow: contact line + long soft cast.
    func hpCardShadow<S: Shape>(shape: S, fill: Color, castMultiplier: Double = 1) -> some View {
        let cast = HPTokens.Shadow.cast
        let deepened = HPShadow(color: cast.color.opacity(castMultiplier), x: cast.x, y: cast.y, blur: cast.blur, spread: cast.spread)
        return self
            .hpShadow(HPTokens.Shadow.contact, shape: shape, fill: fill)
            .hpShadow(deepened, shape: shape, fill: fill)
    }

    /// 1pt hairline border in the given colour following `shape`.
    func hpBorder<S: InsettableShape>(_ shape: S, color: Color = HPTokens.Colors.line) -> some View {
        overlay(shape.strokeBorder(color, lineWidth: HPTokens.borderWidth))
    }

    /// 40pt minimum hit target (COMPONENTS.md rule 6).
    func hpTouchTarget() -> some View {
        frame(minWidth: HPTokens.Space.touchMin, minHeight: HPTokens.Space.touchMin)
            .contentShape(Rectangle())
    }
}

// MARK: - Motion

public enum HPMotion {
    public static var color: Animation { .easeInOut(duration: HPTokens.Motion.color) }
    public static var press: Animation { .easeOut(duration: HPTokens.Motion.press) }
    public static var toast: Animation { .easeInOut(duration: HPTokens.Motion.toast) }
}

// MARK: - Kit metrics spelled out in COMPONENTS.md / PRODUCT.md that are not in the token file

public enum HPMetric {
    /// Focus ring width on inputs (the one ring in the look).
    public static let focusRing: CGFloat = 3
    /// HPToggle track and knob.
    public static let toggleWidth: CGFloat = 44
    public static let toggleHeight: CGFloat = 26
    public static let toggleKnob: CGFloat = 22
    /// Graph dots (PRODUCT §2.7): you / follows / +1.
    public static let graphDotYou: CGFloat = 10
    public static let graphDotFollow: CGFloat = 8
    public static let graphDotPlusOne: CGFloat = 6
    /// Textarea rows in Compose (PRODUCT §2.9).
    public static let composeRows: Int = 6
    /// Sign-in code length (PRODUCT §2.1).
    public static let codeLength: Int = 5
    /// HPTabs label minimum scale before truncation (keeps four segments on one line at 1.4x Dynamic Type).
    public static let tabLabelMinScale: CGFloat = 0.8
}

// MARK: - Opacity steps used by the kit (documented in COMPONENTS.md)

public enum HPAlpha {
    /// Disabled controls.
    public static let disabled: Double = 0.45
    /// Danger button fill (`bad` @ 5%).
    public static let dangerFill: Double = 0.05
    /// Danger button border (`bad` @ 40%).
    public static let dangerLine: Double = 0.40
    /// Gold pill border (accent @ 35%).
    public static let goldPillLine: Double = 0.35
    /// Bad pill fill / border (bad @ 6% / 45%).
    public static let badPillFill: Double = 0.06
    public static let badPillLine: Double = 0.45
    /// Selected tab contact shadow (12%).
    public static let tabShadow: Double = 0.12
    /// Modal cast deepening (×1.5).
    public static let modalCast: Double = 1.5
    /// Toast tone lines.
    public static let toastTone: Double = 0.6
}
