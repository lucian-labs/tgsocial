// House Pour kit — HPNowPlaying (PRODUCT.md §2.11): the slim row docked above the floating
// tab bar while audio plays. Title, play/pause, serif elapsed. Same raised-pill language as
// the floating tabs: panel fill, hairline line, pill radius, the one card shadow.

import SwiftUI

public struct HPNowPlaying: View {
    let title: String
    let elapsed: String
    let playing: Bool
    let onToggle: () -> Void

    public init(title: String, elapsed: String, playing: Bool, onToggle: @escaping () -> Void) {
        self.title = title; self.elapsed = elapsed; self.playing = playing; self.onToggle = onToggle
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            HPPlayButton(state: playing ? .playing : .idle,
                         label: playing ? "Pause" : "Play", action: onToggle)
                .padding(.vertical, HPTokens.Space.tabsPad)
            Text(title)
                .hpStyle(HPType.bodyStrong)
                .lineLimit(1)
            Text(elapsed)
                .hpStyle(HPType.totals, color: HPTokens.Colors.muted)
        }
        .padding(.leading, HPTokens.Space.tabsPad)
        .padding(.trailing, HPTokens.Space.rowPad)
        .background(shape.fill(HPTokens.Colors.panel))
        .hpBorder(shape)
        .hpCardShadow(shape: shape, fill: HPTokens.Colors.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(title)")
    }
}
