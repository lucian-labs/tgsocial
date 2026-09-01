// House Pour kit — HPMiniWave (PRODUCT.md §2.11.2): the now-playing dock's waveform.
//
// The dock is not the place for a spectrogram. This is ONE polyline through the envelope's column
// peaks — a line drawing, not the strip's mirrored filled silhouette and not the spectrum. Hairline
// weight, `muted` ahead of the playhead, `accent` behind it, and no fill under the curve.
//
// Three consequences of that sentence, all of them visible in the code below:
//
//   · **The baseline is the centre, not the floor.** A peak displaces the line upward from the
//     middle of the band, so an envelope of zeros — the clip whose strip degraded to the hairline —
//     draws a FLAT LINE rather than nothing. A floor baseline would have to draw the same clip as a
//     line along the bottom edge, which reads as a rule, not as a waveform at rest.
//   · **The split is a break in one line, not two overlapping ones.** The played run ends on the
//     boundary column and the unplayed run starts on it, so the polyline stays continuous across
//     the colour change instead of showing a gap or a doubled vertex.
//   · **It paints thinner than it is touched.** The control's own frame is `touchMin` and the line
//     is drawn `miniWaveHeight` tall inside it (COMPONENTS.md rule 6: chrome that owns its space may
//     simply *be* 40pt — the dock row is already that tall, so nothing is inflated to get there).
//
// It draws peaks; it does not compute them. Resampling the strip's envelope to the dock's width is
// the app's job, because the envelope belongs to the analysis the strip already did — playing a
// clip must never trigger a second one.

import SwiftUI

public struct HPMiniWave: View {
    /// One peak per column, 0…1, already resampled to the width this will be drawn at. Empty draws
    /// the flat line.
    let peaks: [Double]
    let progress: Double
    let onSeek: ((Double) -> Void)?
    let label: String
    let regionLabel: String?
    @State private var scrub: Double?

    /// `progress` 0…1. `onSeek` receives the fraction while dragging and on release; nil makes the
    /// waveform display-only. `regionLabel`, when set, reports the control's rect under
    /// `hpMeasureTouchTargets` so a test can assert its hit region on the assembled screen.
    public init(peaks: [Double], progress: Double, label: String = "Progress",
                regionLabel: String? = nil, onSeek: ((Double) -> Void)? = nil) {
        self.peaks = peaks
        self.progress = progress
        self.label = label
        self.regionLabel = regionLabel
        self.onSeek = onSeek
    }

    /// Painted band. The frame is `touchMin`; this is the height the line is allowed to move in.
    private var band: CGFloat { HPTokens.Space.miniWaveHeight }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let p = min(max(scrub ?? progress, 0), 1)
            Canvas { ctx, size in
                HPMiniWave.draw(ctx, size: size, band: band, peaks: peaks, progress: p)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                onSeek == nil ? nil :
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in scrub = min(max(v.location.x / width, 0), 1) }
                        .onEnded { v in
                            let f = min(max(v.location.x / width, 0), 1)
                            scrub = nil
                            onSeek?(f)
                        }
            )
        }
        // Rule 6: the line paints `miniWaveHeight` tall and is touched over `touchMin`. The dock row is a
        // 40pt play button tall already, so the extra height is the row's own, not borrowed from a
        // neighbour — and the region is the drawn box, needing no overlay to reach past anything.
        // `miniWaveWidth` is the floor a long title truncates against, so the control cannot be
        // squeezed under a hit target's width either.
        .frame(minWidth: HPTokens.Space.miniWaveWidth, maxWidth: .infinity,
               minHeight: HPTokens.Space.touchMin, maxHeight: HPTokens.Space.touchMin)
        .modifier(HPOptionalTouchRegion(label: regionLabel))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }

    /// The drawing itself, pulled out so it is one function rather than a closure inside a body:
    /// a single polyline across the band, split once at the playhead.
    static func draw(_ ctx: GraphicsContext, size: CGSize, band: CGFloat,
                     peaks: [Double], progress: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let midY = size.height / 2
        let half = (band / 2) * HPMetric.stripEnvelopeScale
        let playedX = size.width * CGFloat(min(max(progress, 0), 1))

        // Fewer than two peaks is not a shape — it is the flat line, which is what a degraded clip
        // is entitled to (§2.11.2). Drawn in the same two colours, split at the same playhead.
        guard peaks.count > 1 else {
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: midY))
            flat.addLine(to: CGPoint(x: playedX, y: midY))
            ctx.stroke(flat, with: .color(HPTokens.Colors.accent), lineWidth: HPTokens.borderWidth)
            var ahead = Path()
            ahead.move(to: CGPoint(x: playedX, y: midY))
            ahead.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(ahead, with: .color(HPTokens.Colors.muted), lineWidth: HPTokens.borderWidth)
            return
        }

        let stepX = size.width / CGFloat(peaks.count - 1)
        @inline(__always) func point(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) * stepX,
                    y: midY - CGFloat(min(max(peaks[i], 0), 1)) * half)
        }

        // The last column at or before the playhead. The two runs share it, so the line is
        // continuous across the colour change.
        let boundary = min(max(Int((playedX / stepX).rounded(.down)), 0), peaks.count - 1)

        if boundary > 0 {
            var played = Path()
            played.move(to: point(0))
            for i in 1...boundary { played.addLine(to: point(i)) }
            ctx.stroke(played, with: .color(HPTokens.Colors.accent), lineWidth: HPTokens.borderWidth)
        }
        if boundary < peaks.count - 1 {
            var ahead = Path()
            ahead.move(to: point(boundary))
            for i in (boundary + 1)...(peaks.count - 1) { ahead.addLine(to: point(i)) }
            ctx.stroke(ahead, with: .color(HPTokens.Colors.muted), lineWidth: HPTokens.borderWidth)
        }
    }
}
