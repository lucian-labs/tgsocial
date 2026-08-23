// House Pour kit — HPPlayerRow (PRODUCT.md §2.11): the inline audio / voice player row.
// Play/pause circle 40pt, title + performer in body/mono, serif elapsed / total time,
// a hairline progress line (scrubber or waveform) with a gold played segment.

import SwiftUI

public struct HPPlayerRow<ProgressLine: View>: View {
    let title: String?
    let subtitle: String?
    let elapsed: String
    let total: String
    let state: HPPlayButton.PlayState
    let buttonLabel: String
    let onButton: () -> Void
    let progressLine: ProgressLine

    public init(title: String?, subtitle: String?, elapsed: String, total: String,
                state: HPPlayButton.PlayState, buttonLabel: String,
                onButton: @escaping () -> Void,
                @ViewBuilder progressLine: () -> ProgressLine) {
        self.title = title; self.subtitle = subtitle; self.elapsed = elapsed; self.total = total
        self.state = state; self.buttonLabel = buttonLabel; self.onButton = onButton
        self.progressLine = progressLine()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            HPPlayButton(state: state, label: buttonLabel, action: onButton)
            VStack(alignment: .leading, spacing: 0) {
                if title != nil || subtitle != nil {
                    if let title, !title.isEmpty {
                        Text(title).hpStyle(HPType.bodyStrong).lineLimit(1)
                    }
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).hpStyle(HPType.monoSmall, color: HPTokens.Colors.muted).lineLimit(1)
                    }
                }
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    Text(elapsed).hpStyle(HPType.totals)
                    progressLine
                    Text(total).hpStyle(HPType.totals, color: HPTokens.Colors.muted)
                }
            }
        }
        .padding(.vertical, HPTokens.Space.pillY)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
