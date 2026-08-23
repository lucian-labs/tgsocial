// House Pour kit — HPPill (COMPONENTS.md "Controls").

import SwiftUI

public enum HPPillTone: Equatable { case neutral, gold, bad }

public struct HPPill: View {
    let text: String
    let tone: HPPillTone
    public init(_ text: String, tone: HPPillTone = .neutral) { self.text = text; self.tone = tone }

    private var fill: Color {
        switch tone {
        case .neutral: return HPTokens.Colors.bg2
        case .gold: return HPTokens.Colors.accentSoft
        case .bad: return HPTokens.Colors.bad.opacity(HPAlpha.badPillFill)
        }
    }
    private var line: Color {
        switch tone {
        case .neutral: return HPTokens.Colors.line2
        case .gold: return HPTokens.Colors.accent.opacity(HPAlpha.goldPillLine)
        case .bad: return HPTokens.Colors.bad.opacity(HPAlpha.badPillLine)
        }
    }
    private var color: Color {
        switch tone {
        case .neutral: return HPTokens.Colors.muted
        case .gold: return HPTokens.Colors.accent
        case .bad: return HPTokens.Colors.bad
        }
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        Text(text)
            .hpStyle(HPType.pill, color: color)
            .lineLimit(1)
            .padding(.vertical, HPTokens.Space.pillY)
            .padding(.horizontal, HPTokens.Space.pillX)
            .background(shape.fill(fill))
            .hpBorder(shape, color: line)
            .animation(HPMotion.color, value: tone)
    }
}
