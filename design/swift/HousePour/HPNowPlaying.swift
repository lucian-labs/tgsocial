// House Pour kit — HPNowPlaying (PRODUCT.md §2.11, §2.11.2): the slim row docked above the floating
// tab bar while audio plays. Play/pause, title, a mini waveform, serif elapsed. Same raised-pill
// language as the floating tabs: panel fill, hairline line, pill radius, the one card shadow.
//
// Two hit-target facts about this row (COMPONENTS.md rule 6). The play button and the waveform own
// their space and simply *are* `touchMin` tall; and the row itself is a control — tapping it
// anywhere but those two opens the post the audio came from (§2.11) — so the tap lives on the row's
// own shape, where the two children take their touches first.

import SwiftUI

public struct HPNowPlaying<Wave: View>: View {
    let title: String
    let elapsed: String
    let playing: Bool
    let onToggle: () -> Void
    /// Tapping the row anywhere but its controls opens the post the audio came from (§2.11).
    let onOpen: (() -> Void)?
    /// Reports the play button's rect under `hpMeasureTouchTargets`, so the assembled-dock test can
    /// prove the two controls tile instead of overlapping.
    let playRegion: String?
    let wave: Wave

    public init(title: String, elapsed: String, playing: Bool,
                onToggle: @escaping () -> Void, onOpen: (() -> Void)? = nil,
                playRegion: String? = nil,
                @ViewBuilder wave: () -> Wave) {
        self.title = title; self.elapsed = elapsed; self.playing = playing
        self.onToggle = onToggle; self.onOpen = onOpen; self.playRegion = playRegion
        self.wave = wave()
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            HPPlayButton(state: playing ? .playing : .idle,
                         label: playing ? "Pause" : "Play", action: onToggle)
                .modifier(HPOptionalTouchRegion(label: playRegion))
                .padding(.vertical, HPTokens.Space.tabsPad)
            Text(title)
                .hpStyle(HPType.bodyStrong)
                .lineLimit(1)
            // The waveform is the flexible member of the row: a long title truncates against the
            // waveform's own `touchMin` floor rather than squeezing it out of existence.
            wave
                .frame(maxWidth: .infinity)
            Text(elapsed)
                .hpStyle(HPType.totals, color: HPTokens.Colors.muted)
                .layoutPriority(1)
        }
        .padding(.leading, HPTokens.Space.tabsPad)
        .padding(.trailing, HPTokens.Space.rowPad)
        .background(shape.fill(HPTokens.Colors.panel))
        .hpBorder(shape)
        .hpCardShadow(shape: shape, fill: HPTokens.Colors.panel)
        .contentShape(shape)
        .modifier(HPRowOpen(onOpen: onOpen, title: title))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing: \(title)")
    }
}

public extension HPNowPlaying where Wave == EmptyView {
    /// The dock without a waveform — a clip whose envelope is not known yet still docks.
    init(title: String, elapsed: String, playing: Bool,
         onToggle: @escaping () -> Void, onOpen: (() -> Void)? = nil,
         playRegion: String? = nil) {
        self.init(title: title, elapsed: elapsed, playing: playing,
                  onToggle: onToggle, onOpen: onOpen, playRegion: playRegion) { EmptyView() }
    }
}

/// Attaches the row's own tap only when a caller wants one, so a dock with nowhere to go is not a
/// button that does nothing.
private struct HPRowOpen: ViewModifier {
    let onOpen: (() -> Void)?
    let title: String
    func body(content: Content) -> some View {
        if let onOpen {
            content
                .onTapGesture { onOpen() }
                .accessibilityAction(named: "Open post") { onOpen() }
        } else {
            content
        }
    }
}
