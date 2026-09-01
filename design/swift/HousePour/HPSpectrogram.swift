// House Pour kit — HPSpectrogramStrip (PRODUCT.md §2.11.1): the audio scrubber, which is not a
// hairline but a spectrogram of the whole clip with its amplitude envelope drawn over it.
//
// Three pieces, in the order they compose:
//
//   HPRamp            the `--ramp-*` token set turned into a colour — the ONE gradient in the
//                     look that carries data. Stop interpolation only; the stops themselves are
//                     generated (HPTokens.Ramp) so all three platforms share them exactly.
//   HPMirrorWave      the connected-line-through-peaks silhouette, mirrored about the strip's
//                     centre and filled, with played/unplayed runs keyed so the split is an Int
//                     compare rather than a Color compare per point.
//   HPSpectrogramStrip the assembled control: bg2 at `Radius.media`, the spectrum bitmap, the
//                     silhouette, a 1pt accent playhead, and tap/drag to seek anywhere on it.
//
// The strip is DRAWN from a bitmap, never from a per-column path. A path re-emitted every frame
// is O(columns × rows) rect ops (a full-width strip is ~1400 columns); a texture is one image
// draw. Building that texture is the analyser's job (the app side), not the kit's — the kit only
// knows how to paint one.

import CoreGraphics
import SwiftUI

// MARK: - The ramp

/// Interpolates `HPTokens.Ramp.stops` — transparent → `line2` → `muted` → `accent`, topping out
/// at `accent2` (PRODUCT §2.11.1). Both ends clamp, so a value outside 0…1 paints the end stop
/// rather than wrapping or extrapolating off the palette.
public enum HPRamp {
    /// Straight (non-premultiplied) sRGB channels plus alpha for a magnitude `v` in 0…1.
    public static func rgba(_ v: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        let stops = HPTokens.Ramp.stops
        guard let first = stops.first, let last = stops.last else { return (0, 0, 0, 0) }
        let x = Swift.min(Swift.max(v, 0), 1)
        if x <= Double(first.at) { return (first.r, first.g, first.b, first.a) }
        for i in 1..<stops.count where x <= Double(stops[i].at) {
            let lo = stops[i - 1], hi = stops[i]
            let span = Double(hi.at - lo.at)
            let t = span > 0 ? (x - Double(lo.at)) / span : 0
            return (lo.r + (hi.r - lo.r) * t,
                    lo.g + (hi.g - lo.g) * t,
                    lo.b + (hi.b - lo.b) * t,
                    lo.a + (hi.a - lo.a) * t)
        }
        return (last.r, last.g, last.b, last.a)
    }

    public static func color(_ v: Double) -> Color {
        let c = rgba(v)
        return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// One pixel of the strip's texture: **premultiplied** BGRA packed little-endian, which is what
    /// `CGImageAlphaInfo.premultipliedFirst | .byteOrder32Little` reads. Premultiplied because the
    /// ramp's low end is transparent by design — the strip is ink on `bg2`, not a second dark
    /// surface — and an unpremultiplied buffer handed to that bitmapInfo paints the fringe wrong.
    public static func packedBGRA(_ v: Double) -> UInt32 {
        let c = rgba(v)
        let a = Swift.min(Swift.max(c.a, 0), 1)
        @inline(__always) func channel(_ x: Double) -> UInt32 {
            UInt32(Swift.min(Swift.max(x * a, 0), 1) * 255)
        }
        return (UInt32(a * 255) << 24) | (channel(c.r) << 16) | (channel(c.g) << 8) | channel(c.b)
    }

    /// `packedBGRA` at 256 steps, resolved once.
    ///
    /// Colourising a full-width strip is ~190,000 pixels, and walking five stops of Double
    /// arithmetic for each one is most of the time the analysis takes. The texture is 8 bits per
    /// channel, so 256 steps is every colour the ramp can actually produce — the table is not an
    /// approximation of the ramp, it *is* the ramp.
    public static let packedTable: [UInt32] = (0..<256).map { packedBGRA(Double($0) / 255) }

    /// The table lookup. Non-finite input paints the low end rather than trapping on the cast:
    /// a NaN magnitude is a bug upstream, not a reason to crash a feed.
    public static func packed(_ v: Double) -> UInt32 {
        guard v.isFinite else { return packedTable[0] }
        return packedTable[Int(Swift.min(Swift.max(v, 0), 1) * 255)]
    }
}

// MARK: - The silhouette

/// The envelope's drawing style: a CONNECTED LINE through the column peaks, mirrored about the
/// centre line and solid-filled between the two — not a bar per column. The point is a smooth
/// silhouette that reads as the shape of the take (PRODUCT §2.11.1).
///
/// Runs of one colour are filled as separate closed regions sharing their boundary column, so the
/// silhouette stays continuous across the played/unplayed split. `key` returns a cheap `Int` per
/// column and `colorForKey` a colour per key: run detection then compares integers instead of
/// constructing and comparing a `Color` for every one of a thousand-odd columns.
public enum HPMirrorWave {
    public static func draw(_ ctx: GraphicsContext, size: CGSize, peaks: [Double],
                            key: (Int) -> Int, colorForKey: (Int) -> Color,
                            fillOpacity: Double = HPAlpha.stripFill,
                            line: Bool = true) {
        let n = peaks.count
        guard n > 1, size.width > 0, size.height > 0 else { return }
        let stepX = size.width / CGFloat(n - 1)
        let midY = size.height / 2
        let half = midY * HPMetric.stripEnvelopeScale

        @inline(__always) func top(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) * stepX, y: midY - CGFloat(Swift.min(Swift.max(peaks[i], 0), 1)) * half)
        }
        @inline(__always) func bottom(_ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(i) * stepX, y: midY + CGFloat(Swift.min(Swift.max(peaks[i], 0), 1)) * half)
        }

        var runStart = 0
        var runKey = key(0)

        func flush(_ end: Int, _ k: Int) {
            guard end > runStart else { return }
            let color = colorForKey(k)
            var body = Path()
            body.move(to: top(runStart))
            for i in (runStart + 1)...end { body.addLine(to: top(i)) }
            body.addLine(to: bottom(end))
            for i in stride(from: end - 1, through: runStart, by: -1) { body.addLine(to: bottom(i)) }
            body.closeSubpath()
            ctx.fill(body, with: .color(color.opacity(fillOpacity)))
            guard line else { return }
            var ridge = Path()
            ridge.move(to: top(runStart))
            for i in (runStart + 1)...end { ridge.addLine(to: top(i)) }
            ridge.move(to: bottom(runStart))
            for i in (runStart + 1)...end { ridge.addLine(to: bottom(i)) }
            ctx.stroke(ridge, with: .color(color), lineWidth: HPTokens.borderWidth)
        }

        for i in 1..<n {
            let k = key(i)
            if k != runKey {
                flush(i, runKey)
                runStart = i
                runKey = k
            }
        }
        flush(n - 1, runKey)
    }
}

/// Attaches `hpTouchRegion` only when a caller named one. An unnamed probe would report an empty
/// label into `HPTouchTargetKey` and show up in every screen's region count as a nameless rect.
/// Shared with `HPMiniWave`, which reports its region the same way.
struct HPOptionalTouchRegion: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label { content.hpTouchRegion(label) } else { content }
    }
}

// MARK: - The strip

/// The spectrogram scrubber (PRODUCT §2.11.1). Shows the WHOLE clip end to end — time is the x
/// axis — so the strip doubles as the scrubber: you can see where the loud part is before you drag
/// to it. It does not scroll; it is computed once per clip and cached.
///
/// It degrades in one direction: with no bitmap it is the amplitude-only silhouette (a voice
/// note's TDLib waveform bytes, drawn immediately), and with neither it is an empty data surface
/// that still seeks. Nothing here blocks on analysis.
public struct HPSpectrogramStrip: View {
    /// What the strip has to paint right now. Both halves are optional and arrive independently:
    /// the silhouette can be on screen before the spectrum exists behind it.
    public struct Content: Equatable {
        public let image: CGImage?
        /// One peak per column, 0…1 — the one-pole envelope, or a voice note's waveform bytes.
        public let envelope: [Double]

        public init(image: CGImage? = nil, envelope: [Double] = []) {
            self.image = image
            self.envelope = envelope
        }

        public static let empty = Content()

        /// Hand-written because `CGImage` is a CF class with no `Equatable` conformance — and
        /// identity is the right comparison anyway: a strip is computed once and handed round, so
        /// two contents holding the same texture are the same texture.
        public static func == (a: Content, b: Content) -> Bool {
            a.image === b.image && a.envelope == b.envelope
        }
    }

    let content: Content
    let progress: Double
    let onSeek: ((Double) -> Void)?
    let label: String
    let regionLabel: String?
    @State private var scrub: Double?

    /// `progress` 0…1. `onSeek` receives the fraction while dragging and on release; nil makes the
    /// strip display-only. `regionLabel`, when set, reports the strip's rect under
    /// `hpMeasureTouchTargets` so a test can assert its hit region on the assembled screen.
    public init(content: Content, progress: Double, label: String = "Progress",
                regionLabel: String? = nil, onSeek: ((Double) -> Void)? = nil) {
        self.content = content
        self.progress = progress
        self.label = label
        self.regionLabel = regionLabel
        self.onSeek = onSeek
    }

    private var height: CGFloat { max(HPTokens.Space.stripHeight, HPTokens.Space.touchMin) }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let p = min(max(scrub ?? progress, 0), 1)
            let shape = RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous)
            ZStack(alignment: .topLeading) {
                shape.fill(HPTokens.Colors.bg2)
                if let image = content.image {
                    // `decorative` because the strip's meaning is in its accessibility label, not in
                    // a second description of the same pixels. `.none` interpolation: one column is
                    // one pixel of data, and smoothing it invents magnitudes between them.
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.none)
                        .antialiased(false)
                }
                Canvas { ctx, size in
                    let playedX = size.width * CGFloat(p)
                    let n = content.envelope.count
                    if n > 1 {
                        let stepX = size.width / CGFloat(n - 1)
                        let played = HPTokens.Colors.accent
                        let ahead = HPTokens.Colors.ink.opacity(HPAlpha.stripAhead)
                        HPMirrorWave.draw(ctx, size: size, peaks: content.envelope,
                                          key: { CGFloat($0) * stepX <= playedX ? 0 : 1 },
                                          colorForKey: { $0 == 0 ? played : ahead })
                    }
                    guard p > 0 else { return }
                    var head = Path()
                    head.move(to: CGPoint(x: playedX, y: 0))
                    head.addLine(to: CGPoint(x: playedX, y: size.height))
                    ctx.stroke(head, with: .color(HPTokens.Colors.accent), lineWidth: HPTokens.borderWidth)
                }
            }
            .frame(width: geo.size.width, height: height)
            .clipShape(shape)
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
        // The strip is 44pt tall, so — rule 6 — the painted shape simply IS the hit target: it is
        // taller than `touchMin` already and needs no overlay reaching into a neighbour's space.
        .frame(height: height)
        .modifier(HPOptionalTouchRegion(label: regionLabel))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}
