// Components — text entities → styled Text (COMPONENTS.md "Text entity rendering").

import SwiftUI

struct RichTextView: View {
    let text: RichText
    @HPScaledFactor private var scale

    var body: some View {
        Text(attributed)
            .lineSpacing(HPType.body.lineSpacing * scale)
            .fixedSize(horizontal: false, vertical: true)
            .tint(HPTokens.Colors.accent)
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        let body = HPType.body
        for span in text.spans {
            var piece = AttributedString(span.text)
            switch span.kind {
            case .plain:
                piece.font = HPFont.font(body, scale: scale)
                piece.foregroundColor = HPTokens.Colors.ink
            case .bold:
                piece.font = HPFont.font(HPType.bodyStrong, scale: scale)
                piece.foregroundColor = HPTokens.Colors.ink
            case .italic:
                piece.font = HPFont.font(body, scale: scale).italic()
                piece.foregroundColor = HPTokens.Colors.ink
            case .code:
                piece.font = HPFont.font(HPType.mono, scale: scale)
                piece.foregroundColor = HPTokens.Colors.muted
            case .link, .mention:
                piece.font = HPFont.font(body, scale: scale)
                piece.foregroundColor = HPTokens.Colors.accent
                piece.underlineStyle = .single
                if let url = span.url.flatMap(DeepLink.url) { piece.link = url }
            }
            out += piece
        }
        return out
    }
}
