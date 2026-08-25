// House Pour kit — SwiftUI foundation (hand-written against HousePourTokens.swift).
// Fonts, text style application, Dynamic Type clamp, shadow and border helpers.
// Every value here is a token; nothing is typed by hand.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    /// 40pt minimum hit target (COMPONENTS.md rule 6) as a *box*: the layout grows to the target.
    /// Right for chrome that owns its space (a kebab, a toggle); wrong for a line of text — see
    /// `hpTouchOverlay`.
    func hpTouchTarget() -> some View {
        frame(minWidth: HPTokens.Space.touchMin, minHeight: HPTokens.Space.touchMin)
            .contentShape(Rectangle())
    }

    /// 40pt minimum hit target as an **overlay, not a box** (PRODUCT §2.3 "Header metrics"). The
    /// tappable area extends past the painted bounds; the laid-out size is untouched, so a 13pt
    /// subheading stays 13pt tall and still answers to a 40pt touch.
    ///
    /// `anchor` pins the overlay to one edge of the label so stacked controls grow *away* from each
    /// other: `.bottomLeading` grows the target upwards, `.topLeading` downwards. Two controls one
    /// line apart can then each claim `touchMin` without either covering the other's glyphs.
    ///
    /// **A region only exists where its container leaves the space clear.** An overlay that reaches
    /// past its own view's bounds lands on whatever else is laid out there, and between siblings the
    /// one laid out *later* takes the touch — so an overlay grown into a neighbour's tap surface buys
    /// the control nothing at all. The container owes the overhang: see `hpHitBandBelow` for the
    /// band it holds clear, and assert the result with `hpMeasureTouchTargets` rather than trusting
    /// the overlay's own reported size, which is the same 40pt whether or not anything reaches it.
    func hpTouchOverlay(_ anchor: Alignment = .center, label: String = "") -> some View {
        contentShape(Rectangle())
            .overlay(alignment: anchor) { HPTouchOverlay(label: label) }
    }

    /// Reports this view's own rect through `HPTouchTargetKey` under `hpMeasureTouchTargets`, so a
    /// test can prove a neighbouring control's region does not reach into this one's tap surface.
    /// Never affects hit testing or layout; off in the app.
    func hpTouchRegion(_ label: String) -> some View {
        background { HPTouchProbe(label: label) }
    }
}

public extension HPTextStyle {
    /// The line box one line of this style actually paints into, at scale 1.
    ///
    /// SwiftUI takes a single line's height from the face's own metrics — the ramp's `lineHeight`
    /// only spaces lines *apart* (`lineSpacing`) — so this asks the font rather than multiplying the
    /// token the way Compose can (there the ramp sets an explicit line height and gets
    /// `size × lineHeight`). A layout that has to reserve room around a line needs the height the
    /// text will really occupy, not the one the ramp names.
    var hpLineBox: CGFloat {
        #if canImport(UIKit)
        if let font = UIFont(name: HPFont.name(face: face, weight: weight), size: size) {
            return font.lineHeight
        }
        #endif
        return size * lineHeight
    }
}

/// COMPONENTS.md rule 6, the **tiling** half — the band a `touchMin` region anchored to the top of
/// `contentHeight` needs *below* it: everything of `min` the line box does not already provide.
///
/// An overlay is only as big as what will actually reach it. Between siblings the later-placed one
/// takes every point the two share, so a sibling whose tap surface starts inside this band wins it
/// and the control ships smaller than `min` however big the overlay measured — 40pt in a layout
/// assertion, 14pt under a finger, with the missing 26pt firing the neighbour's action. Hold the
/// band clear of anything tappable and the boundary between the two is a line, not an overlap.
public func hpHitBandBelow(_ contentHeight: CGFloat, min: CGFloat = HPTokens.Space.touchMin) -> CGFloat {
    Swift.max(0, min - contentHeight)
}

/// The clear `touchMin` × `touchMin` region `hpTouchOverlay` lays over a control.
public struct HPTouchOverlay: View {
    let label: String
    public init(label: String = "") { self.label = label }
    public var body: some View {
        Color.clear
            .frame(minWidth: HPTokens.Space.touchMin, minHeight: HPTokens.Space.touchMin)
            .contentShape(Rectangle())
            .hpTouchRegion(label)
    }
}

/// Measures the rect of whatever it is attached to, in `HPTouch.space`, and reports it through
/// `HPTouchTargetKey` when `hpMeasureTouchTargets` is on — so a test can assert the real hit area of
/// a shipped screen *in the place it ships*, neighbours included. A hit target that only exists in a
/// comment is a hit target nobody can check, and a target measured with no neighbours around it is a
/// target nobody has hit-tested. The report is off in the app: it costs a preference per control and
/// buys the app nothing. The geometry is identical either way.
public struct HPTouchProbe: View {
    @Environment(\.hpMeasureTouchTargets) private var measure
    let label: String
    public init(label: String) { self.label = label }
    public var body: some View {
        if measure {
            GeometryReader { geo in
                Color.clear.preference(key: HPTouchTargetKey.self,
                                       value: [HPTouchRegion(label: label, rect: geo.frame(in: .named(HPTouch.space)))])
            }
            .allowsHitTesting(false)
        }
    }
}

/// One measured region: which control, and the rect it covers in `HPTouch.space`.
public struct HPTouchRegion: Equatable, Sendable {
    public let label: String
    public let rect: CGRect
    public init(label: String, rect: CGRect) { self.label = label; self.rect = rect }
}

public enum HPTouch {
    /// The coordinate space measured regions are reported in. A test harness marks its root with
    /// `hpTouchSpace()`; rects from different controls are then directly comparable.
    public static let space = "hpTouchTargets"
}

public extension View {
    /// Roots the coordinate space `HPTouchProbe` reports in. Test harnesses only.
    func hpTouchSpace() -> some View { coordinateSpace(name: HPTouch.space) }
}

/// Every hit region measured under `hpMeasureTouchTargets`, in tree order.
public struct HPTouchTargetKey: PreferenceKey {
    public static var defaultValue: [HPTouchRegion] = []
    public static func reduce(value: inout [HPTouchRegion], nextValue: () -> [HPTouchRegion]) { value += nextValue() }
}

private struct HPMeasureTouchTargetsKey: EnvironmentKey { static let defaultValue = false }

public extension EnvironmentValues {
    /// Test seam (see `HPTouchProbe`). Never set by the app.
    var hpMeasureTouchTargets: Bool {
        get { self[HPMeasureTouchTargetsKey.self] }
        set { self[HPMeasureTouchTargetsKey.self] = newValue }
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
    /// HPScrubber knob (PRODUCT §2.11: "a 12pt panel knob with the contact shadow").
    public static let scrubberKnob: CGFloat = 12
    /// HPWaveform bar geometry and the idle bar height when no samples are known.
    public static let waveformHeight: CGFloat = 28
    public static let waveformBar: CGFloat = 2
    public static let waveformGap: CGFloat = 1
    public static let waveformIdle: Double = 0.12
    /// HPPlayGlyph default size inside the 40pt circle.
    public static let playGlyph: CGFloat = 14
    /// HPProgressRing: gold ring inset from the circle edge and the stop glyph inside it.
    public static let ringInset: CGFloat = 3
    public static let stopGlyph: CGFloat = 10
    /// HPMedia blur-up radius while the minithumbnail stands in.
    public static let mediaBlur: CGFloat = 12
    /// HPKebabButton (PRODUCT §2.6): three faint dots stacked inside the 40pt target.
    public static let kebabDots: Int = 3
    public static let kebabDot: CGFloat = 4
    public static let kebabDotGap: CGFloat = 3
    /// HPMenu: the anchored card's width, and the swipe-down distance that dismisses the sheet.
    public static let menuWidth: CGFloat = 240
    public static let menuDismissDrag: CGFloat = 40
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
    /// Full-screen viewer backdrop (`ink` at 96%, PRODUCT §2.11).
    public static let viewerBackdrop: Double = 0.96
}
