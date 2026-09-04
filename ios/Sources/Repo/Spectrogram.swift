// Repo — the spectrogram strip's analyser (PRODUCT.md §2.11.1). The audio scrubber is a
// spectrogram of the whole clip with its amplitude envelope over it; this file is everything
// behind that picture, and `HPSpectrogramStrip` (design/swift/HousePour) is the picture itself.
//
// The important difference from Wake, whose `LiveSpectrum` this is ported from: Wake visualises a
// LIVE microphone and scrolls, so its bitmap `memmove`s down one row per frame and colourises the
// newest. tgsocial plays a FINITE FILE. The strip shows the whole clip end to end — time is the x
// axis — and doubles as the scrubber, so it does not scroll: it is computed ONCE, cached against
// the file's own identity, and then only drawn. That is why there is no timer here.
//
// What survives from Wake unchanged, because it is the house spectrum primitive:
//   · `FFTAnalyzer` — Hann window, real-to-complex vDSP, N/2 magnitude bins (WakeFFTAnalyzer.swift).
//   · the log-spaced band collapse — here 20 Hz to the ANALYSIS NYQUIST, as in Wake, rather than
//     to a literal 20 kHz the decimation cannot reach — the pink-slope tilt, and the rolling AGC
//     with its floor and dynamic range (WakeFFT.swift `logBars`).
//   · the bitmap: one texture, not a path re-emitted per frame. A full-width strip is ~1400
//     columns × ~130 rows, and drawing that as rects is 180k ops per redraw.
//
// Everything here is pure or off the main actor. The pure halves — the one-pole follower, the log
// axis, the AGC, the plan — are separated out deliberately so they can be tested without an audio
// file, a screen, or a simulator's audio stack.

import AVFoundation
import Accelerate
import CoreGraphics
import Foundation

// MARK: - Constants

/// Every number the analyser runs on, in one place with its derivation. None of these is a magic
/// literal at a call site.
enum SpectrogramSpec {
    /// Analysis rate ceiling. PRODUCT §2.11.1: "8–16 kHz is plenty for a strip this size"; 16 kHz
    /// is the top of that band, so the decimated Nyquist (8 kHz) covers everything a compressed
    /// Telegram clip actually carries. The AXIS follows that Nyquist rather than outrunning it —
    /// see `fMax` and `axisMax(rate:)`.
    static let maxRate: Double = 16_000
    /// Analysis rate floor for long clips (see `rate(forDuration:)`).
    static let minRate: Double = 8_000
    /// The decoded buffer's ceiling in samples — 4.8 M Float32 ≈ 19 MB, transient and off the main
    /// actor. It is what makes the rate adaptive: a clip long enough to blow the ceiling is
    /// analysed at a lower rate instead of allocating without bound.
    ///
    /// The knee is `rateKnee` — `maxSamples / maxRate` = **300 s**, not the 600 s duration cap. A
    /// clip runs at `maxRate` up to five minutes, slides from there, and lands exactly on
    /// `minRate` at the cap. Both ends of that slide are honest now that the axis follows the
    /// rate; before it did, the slide was also a doubling of the strip's dead band.
    static let maxSamples = 4_800_000

    /// 2048 points at 16 kHz is a 128 ms window and 7.8 Hz bins — tighter in time than Wake's
    /// 8192 at 48 kHz (171 ms / 5.9 Hz) and slightly coarser in frequency, which is the right way
    /// round for a clip you are scrubbing rather than a room you are watching. Power of two, as
    /// vDSP's radix-2 FFT requires.
    static let fftSize = 2048

    /// The log axis, PRODUCT §2.11.1. `fMin` is the bottom; `fMax` is a CEILING on the top, not
    /// the top itself — `axisMax(rate:)` is what the analysis actually runs on.
    ///
    /// The axis has to stop at the decimated Nyquist, because there is nothing above it to draw.
    /// A literal 20 kHz top over an 8–16 kHz analysis rate reserves rows for a band the decimation
    /// filtered out before the FFT ever saw it: on a 132-row strip that is 17 rows (13%) at 16 kHz
    /// and 30 (23%) at 8 kHz — up to 10pt of a 44pt control that can never light, and a dead band
    /// whose height changes with the clip's LENGTH, since the rate does. Following Nyquist costs a
    /// fixed frequency scale between clips of very different lengths and buys back every row; for
    /// a 44pt scrubber with no axis labels on it, that is the better trade, and it is what Wake
    /// does.
    static let fMin: Double = 20
    static let fMax: Double = 20_000

    /// The top of the axis for an analysis at `rate`: the spec's ceiling, or the decimated Nyquist
    /// when that is lower — which, across §2.11.1's 8–16 kHz band, it always is (8 kHz and 4 kHz
    /// at the two ends). The `min` is what keeps `fMax` meaningful if the rate ceiling ever rises.
    static func axisMax(rate: Double) -> Double {
        guard rate > 0 else { return fMax }
        return min(fMax, rate / 2)
    }

    /// Display range below the rolling peak, in dB (Wake's number).
    static let dynRangeDb: Double = 48
    /// The AGC never opens past this, so true digital silence stays dark instead of blowing the
    /// noise floor up to full brightness.
    static let agcFloor: Double = 0.0004
    /// Per-column release. Wake releases per frame at 30 Hz; a strip's columns are its frames.
    static let agcRelease: Double = 0.994

    /// Spectral-tilt compensation. Natural sound has a ~1/f (pink) slope, so a raw magnitude
    /// spectrum always reads bass-heavy. +4.5 dB/oct about 1 kHz — the same lift pro analysers
    /// use — so the highs stop hiding under the bass.
    static let tiltDbPerOct: Double = 4.5
    static let tiltPivotHz: Double = 1000

    /// The one-pole envelope's time constants: fast attack so a transient is not smoothed away,
    /// slow release so the silhouette is the *shape of the take* and not a per-sample bar chart.
    /// Milliseconds, turned into per-sample coefficients against the decimated rate by
    /// `coefficient(ms:rate:)` — the coefficient itself is never written down anywhere.
    static let attackMs: Double = 4
    static let releaseMs: Double = 160

    /// PRODUCT §2.11.1's ceiling: "about 10 minutes". Past it the spectrum is skipped and the row
    /// keeps the amplitude-only silhouette.
    static let durationCap: Double = 600
    /// And past THIS there is no strip at all. An hour of audio is not a 44pt picture, and even
    /// the envelope pass would decode the whole file to draw 1400 numbers.
    static let envelopeCap: Double = 3_600
    /// The envelope-only fallback needs no frequency resolution, so it decodes far coarser — and
    /// coarse enough that `envelopeCap` seconds of it still fit inside `maxSamples`. That is the
    /// point, not an accident: if the decode hit the buffer ceiling the strip would draw the first
    /// forty minutes stretched across the whole width and quietly lie about the time axis.
    /// `SpectrogramPlanTests` pins the arithmetic.
    static let envelopeRate: Double = 1_000

    /// Work bounds. One column per strip pixel is the rule (§2.11.1 "no more"); these stop a
    /// pathological layout from asking for a texture nobody can afford.
    static let maxColumns = 2048
    static let maxRows = 256

    /// The per-sample coefficient of a one-pole whose time constant is `ms` at `rate`: after one
    /// time constant a step has covered 1 − 1/e of the distance, which is what the follower's
    /// tests assert.
    static func coefficient(ms: Double, rate: Double) -> Double {
        guard ms > 0, rate > 0 else { return 1 }
        return 1 - exp(-1.0 / ((ms / 1000) * rate))
    }

    /// Where the adaptive rate starts falling: `maxSamples / maxRate` = 300 s. Under it every clip
    /// is analysed at `maxRate` and the axis tops out at 8 kHz; over it both slide together, to
    /// `minRate` and a 4 kHz axis at `durationCap`.
    static var rateKnee: Double { Double(maxSamples) / maxRate }

    /// The analysis rate for a clip of `seconds`: `maxRate` until the decoded buffer would exceed
    /// `maxSamples` (i.e. up to `rateKnee`), then whatever keeps it inside, floored at `minRate`.
    static func rate(forDuration seconds: Double) -> Double {
        guard seconds > 0, seconds.isFinite else { return maxRate }
        return min(maxRate, max(minRate, Double(maxSamples) / seconds))
    }
}

// MARK: - The one-pole envelope

/// `y += (x > y ? attack : release) * (x - y)` — PRODUCT §2.11.1, verbatim. One pole, not a
/// peak-per-bin bar chart: the point is a smooth silhouette.
struct OnePoleFollower {
    let attack: Double
    let release: Double
    private(set) var value: Double

    init(attackMs: Double = SpectrogramSpec.attackMs,
         releaseMs: Double = SpectrogramSpec.releaseMs,
         rate: Double,
         start: Double = 0) {
        attack = SpectrogramSpec.coefficient(ms: attackMs, rate: rate)
        release = SpectrogramSpec.coefficient(ms: releaseMs, rate: rate)
        value = start
    }

    @discardableResult
    mutating func process(_ x: Double) -> Double {
        value += (x > value ? attack : release) * (x - value)
        return value
    }
}

// MARK: - The log frequency axis

/// Row 0 is the BOTTOM of the strip (`fMin`) and row `rows - 1` the top, because that is how the
/// axis reads. The bitmap writer flips it, since a bitmap's row 0 is its top edge.
enum LogFrequency {
    /// `fMax` carries NO default anywhere in here, deliberately. The axis top is the analysis's
    /// own Nyquist (`SpectrogramSpec.axisMax(rate:)`), not `SpectrogramSpec.fMax`, and a caller
    /// that silently took the ceiling would put every row on a frequency the FFT never measured —
    /// which is exactly the drift this axis already had once.

    /// The centre frequency of one row.
    static func frequency(row: Int, rows: Int,
                          fMin: Double = SpectrogramSpec.fMin,
                          fMax: Double) -> Double {
        guard rows > 0, fMin > 0, fMax > fMin else { return fMin }
        let t = (Double(row) + 0.5) / Double(rows)
        return fMin * pow(fMax / fMin, t)
    }

    /// The band one row collapses: `[lo, hi)` in Hz.
    static func band(row: Int, rows: Int,
                     fMin: Double = SpectrogramSpec.fMin,
                     fMax: Double) -> (lo: Double, hi: Double) {
        guard rows > 0, fMin > 0, fMax > fMin else { return (fMin, fMin) }
        let ratio = fMax / fMin
        return (fMin * pow(ratio, Double(row) / Double(rows)),
                fMin * pow(ratio, Double(row + 1) / Double(rows)))
    }

    /// The row a frequency lands on — the inverse of `frequency(row:rows:)`, clamped at both ends.
    static func row(frequency f: Double, rows: Int,
                    fMin: Double = SpectrogramSpec.fMin,
                    fMax: Double) -> Int {
        guard rows > 0, f > 0, fMin > 0, fMax > fMin else { return 0 }
        let t = log(f / fMin) / log(fMax / fMin)
        return min(max(Int((t * Double(rows)).rounded(.down)), 0), rows - 1)
    }
}

// MARK: - Rolling AGC

/// Wake's normalisation, applied left-to-right across the clip instead of forward in time: the
/// loudest recent column defines the top of the display and every band's floor sits `dynRangeDb`
/// under it, so a QUIET recording still fills the strip instead of reading as silence.
///
/// Seeded with the clip's own peak (a file, unlike a microphone, can be measured before it is
/// drawn), so the loudest column lands at exactly 1 whatever the absolute level was; the release
/// then opens the reference further through a quiet passage, which is what keeps a fade-out from
/// going black.
struct RollingAGC {
    private(set) var peak: Double
    let release: Double
    let floor: Double
    let dynRangeDb: Double

    init(seed: Double,
         release: Double = SpectrogramSpec.agcRelease,
         floor absoluteFloor: Double = SpectrogramSpec.agcFloor,
         dynRangeDb: Double = SpectrogramSpec.dynRangeDb) {
        // The floor is RELATIVE to the seed, and this is the difference between Wake's live AGC and
        // a file's. Wake has no future knowledge, so its floor is absolute: it stops the reference
        // opening past the point where a silent room's self-noise fills the display. Here the seed
        // IS the clip's measured peak — and clamping the reference *up* to an absolute floor is
        // exactly what would make a quiet recording read as silence, the one thing §2.11.1 says the
        // AGC exists to prevent (a −80 dBFS take normalised against a −68 dB floor tops out at
        // three quarters of the strip instead of filling it).
        //
        // So: the reference may open until the display range is exhausted below the clip's own
        // peak, but no further, and the absolute floor still binds for a normally-levelled clip.
        // A seed of zero — true digital silence — falls back to the absolute floor and stays dark.
        let relativeFloor = seed * pow(10, -dynRangeDb / 20)
        self.floor = seed > 0 ? Swift.min(absoluteFloor, relativeFloor) : absoluteFloor
        self.peak = max(seed, self.floor)
        self.release = release
        self.dynRangeDb = dynRangeDb
    }

    /// Normalises one column of magnitudes to 0…1 in place and rolls the reference: instant attack,
    /// slow release, floored. In place because it runs once per column and a fresh array per column
    /// is ~1400 allocations per strip.
    mutating func normalise(_ column: inout [Double]) {
        var frameMax = 0.0
        for v in column where v > frameMax { frameMax = v }
        peak = frameMax > peak ? frameMax : max(peak * release, floor)
        let reference = max(peak, floor)
        for i in column.indices {
            let db = 20 * log10(max(column[i] / reference, 1e-5))
            column[i] = min(max((db + dynRangeDb) / dynRangeDb, 0), 1)
        }
    }

    /// The value-returning form, for callers that are not in a hot loop (and for the tests).
    mutating func normalise(_ column: [Double]) -> [Double] {
        var out = column
        normalise(&out)
        return out
    }
}

// MARK: - FFT (ported from Wake's WakeFFTAnalyzer.swift)

/// Real-to-complex FFT (vDSP) — Hann window, N/2 magnitude bins. The WaveLoop-standard spectrum
/// primitive, carried across unchanged so both apps' spectrograms mean the same thing.
final class FFTAnalyzer {
    let fftSize: Int
    private let log2N: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]

    init?(fftSize: Int) {
        guard fftSize > 0, fftSize & (fftSize - 1) == 0 else { return nil }
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), Int32(kFFTRadix2)) else { return nil }
        self.fftSize = fftSize
        self.log2N = vDSP_Length(log2(Double(fftSize)))
        self.setup = setup
        var hann = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hann, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        window = hann
        windowed = .init(repeating: 0, count: fftSize)
        realPart = .init(repeating: 0, count: fftSize / 2)
        imagPart = .init(repeating: 0, count: fftSize / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// N/2 magnitude bins for the `count` samples at `samples`, into `mags` (which must hold
    /// `fftSize / 2` elements).
    ///
    /// A pointer and a caller-owned output rather than arrays and a return value, because this runs
    /// once per strip column — ~1400 times for one clip. A fresh magnitude array each time, and a
    /// copy of the window's worth of samples into a scratch buffer before it, is the difference
    /// between a strip that builds in milliseconds and one that takes over a second.
    func magnitudes(_ samples: UnsafePointer<Float>, count: Int, into mags: inout [Float]) {
        let len = min(count, fftSize)
        guard len > 0, mags.count == fftSize / 2 else { return }
        windowed.withUnsafeMutableBufferPointer { w in
            guard let base = w.baseAddress else { return }
            window.withUnsafeBufferPointer { win in
                vDSP_vmul(samples, 1, win.baseAddress!, 1, base, 1, vDSP_Length(len))
            }
            if len < fftSize {
                var zero: Float = 0
                vDSP_vfill(&zero, base + len, 1, vDSP_Length(fftSize - len))
            }
        }

        windowed.withUnsafeBufferPointer { winPtr in
            realPart.withUnsafeMutableBufferPointer { rePtr in
                imagPart.withUnsafeMutableBufferPointer { imPtr in
                    var split = DSPSplitComplex(realp: rePtr.baseAddress!, imagp: imPtr.baseAddress!)
                    winPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { cptr in
                        vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(fftSize / 2))
                    }
                }
            }
        }
        var scale: Float = 1.0 / Float(fftSize)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(fftSize / 2))
    }
}

// MARK: - Reusing one envelope at another width (PRODUCT §2.11.2)

/// The dock's mini waveform is "a view of the analysis the strip already did — the same envelope
/// array, resampled to the dock's width" (§2.11.2). This is that resample, and it is the ONLY thing
/// standing between the dock and a second decode.
///
/// It takes the **maximum** over each output column's span rather than a mean or a nearest sample.
/// The envelope is already a peak-per-column series, and the dock is narrower than the strip — so
/// every output column covers several input ones and a mean would quietly flatten exactly the
/// transients the follower's fast attack exists to keep. Widening (a dock wider than the analysed
/// strip) is linear interpolation between neighbours, because there is nothing between two peaks to
/// take a maximum of.
enum Envelope {
    static func resample(_ peaks: [Double], to columns: Int) -> [Double] {
        guard columns > 0 else { return [] }
        guard peaks.count > 1 else {
            // Nothing, or a single value: a flat line at whatever level is known.
            return [Double](repeating: peaks.first ?? 0, count: columns)
        }
        if peaks.count == columns { return peaks }
        if columns == 1 { return [peaks.max() ?? 0] }

        if columns < peaks.count {
            // Downsample: the peak of each span, so a transient survives the narrowing.
            let span = Double(peaks.count) / Double(columns)
            return (0..<columns).map { i in
                let lo = Int((Double(i) * span).rounded(.down))
                let hi = min(Int((Double(i + 1) * span).rounded(.up)), peaks.count)
                guard lo < hi else { return peaks[min(lo, peaks.count - 1)] }
                return peaks[lo..<hi].max() ?? 0
            }
        }
        // Upsample: linear between the two neighbours the output column falls between.
        let step = Double(peaks.count - 1) / Double(columns - 1)
        return (0..<columns).map { i in
            let x = Double(i) * step
            let lo = min(Int(x.rounded(.down)), peaks.count - 1)
            let hi = min(lo + 1, peaks.count - 1)
            let t = x - Double(lo)
            return peaks[lo] + (peaks[hi] - peaks[lo]) * t
        }
    }
}

// MARK: - The strip as data

/// One analysed clip: the texture and the silhouette, both sized to the strip's pixels.
struct SpectrogramStrip {
    let columns: Int
    let rows: Int
    /// Premultiplied BGRA, `columns` wide × `rows` tall, row 0 = TOP = the high end of the axis.
    /// Empty when only the envelope was computed.
    let pixels: [UInt32]
    /// One 0…1 peak per column — the one-pole follower's maximum inside that column's time span.
    let envelope: [Double]

    var byteCount: Int { pixels.count * MemoryLayout<UInt32>.size }

    /// The texture as a CGImage.
    ///
    /// The pixels are COPIED into the provider's own storage. Handing `CGImage` a pointer into a
    /// Swift array would be a use-after-free the moment the array is reallocated or goes out of
    /// scope under a retained image — the same trap Wake's `makeImage()` calls out.
    func makeImage() -> CGImage? {
        guard columns > 0, rows > 0, pixels.count == columns * rows else { return nil }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: columns, height: rows,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: columns * MemoryLayout<UInt32>.size,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

// MARK: - Building it

enum SpectrogramBuilder {
    /// The silhouette: the one-pole follower run over the sample magnitudes, reduced to the peak
    /// inside each column's time span, then normalised to the clip's own maximum so a quiet take
    /// still fills the strip.
    static func envelope(samples: [Float], rate: Double, columns requested: Int) -> [Double] {
        let columns = min(max(requested, 1), SpectrogramSpec.maxColumns)
        let n = samples.count
        guard n > 0 else { return [] }
        var follower = OnePoleFollower(rate: rate)
        var out = [Double](repeating: 0, count: columns)
        var peak = 0.0
        // A pointer walk: this is one iteration per DECODED SAMPLE — half a million for a 30 s
        // clip — and it is the one loop in the file that scales with duration rather than pixels.
        samples.withUnsafeBufferPointer { input in
            guard let head = input.baseAddress else { return }
            for i in 0..<n {
                let y = follower.process(Double(abs(head[i])))
                let c = min(i * columns / n, columns - 1)
                if y > out[c] { out[c] = y }
                if y > peak { peak = y }
            }
        }
        guard peak > 0 else { return out }
        for i in 0..<columns { out[i] = min(out[i] / peak, 1) }
        return out
    }

    /// The whole strip: short-time FFT across the clip, log-collapsed onto `rows`, tilted,
    /// AGC-normalised and colourised through the House Pour ramp, plus the envelope.
    ///
    /// **Hop.** One column per strip pixel is the display constraint (§2.11.1 "no more"), so a
    /// column's slice is `samples / columns` and the overlap is whatever that implies: at a phone's
    /// strip width that is 80%+ for anything under about a minute and a half. Past that a column
    /// spans more than one window and it takes SEVERAL — see `frames`.
    static func build(samples: [Float], rate: Double, columns requestedColumns: Int, rows requestedRows: Int) -> SpectrogramStrip {
        let g = grid(samples: samples, rate: rate, columns: requestedColumns, rows: requestedRows)
        let env = envelope(samples: samples, rate: rate, columns: g.columns)
        guard !g.values.isEmpty else {
            return SpectrogramStrip(columns: g.columns, rows: g.rows, pixels: [], envelope: env)
        }
        // Row 0 of the axis is the LOW end and row 0 of a bitmap is its TOP, so the write flips.
        var pixels = [UInt32](repeating: HPRamp.packed(0), count: g.columns * g.rows)
        for c in 0..<g.columns {
            for r in 0..<g.rows {
                pixels[(g.rows - 1 - r) * g.columns + c] = HPRamp.packed(g.values[c * g.rows + r])
            }
        }
        return SpectrogramStrip(columns: g.columns, rows: g.rows, pixels: pixels, envelope: env)
    }

    /// Where one column's FFT windows start, so that between them they COVER the column's slice.
    ///
    /// §2.11.1 asks for "a short-time FFT across the clip", and web states the invariant that makes
    /// that sentence true: `hop <= fftSize`, every sample inside at least one window
    /// (js/spectro.js `framePlan`). Web reaches it by GROWING the window when its frame budget runs
    /// out, because its frames are laid out over the whole clip; iOS lays them out per column, so
    /// the same invariant is reached from the other side — a column wide enough to hold more than
    /// one window simply takes more than one.
    ///
    /// One window per column, centred, is what this replaced, and it was a sampler past about
    /// ninety seconds — the point where a column's slice outgrows a window. Measured on the two
    /// lengths `SpectrogramBuilderTests` pins, at a 700-column strip: a 150 s clip is 3428 samples
    /// per column against a 2048 window, so 1380 of them (86 ms, 40% of the column) sat inside no
    /// frame at all; at the 600 s cap the column is 6857 samples and 4809 of them were blind —
    /// 601 ms, 70%. A short burst landing in that gap lit nothing, which is the one thing a
    /// scrubber you navigate by must not do.
    ///
    /// The cost is per COLUMN, because that is where these windows are laid out — `n / fftSize` is
    /// web's bound, for frames distributed over the whole clip, and it does NOT apply here. The
    /// total is `Σ ceil(span / fftSize)` over the columns, which the per-column rounding puts at
    /// `n / fftSize + columns` at worst: coverage, plus up to one spare window a column. So the
    /// strip's width is part of the bill, and the worst case over every width is 4096 FFTs — at
    /// `maxColumns`, where a column narrows to 2343 samples and still takes two windows. On a clip
    /// at the sample cap that is 2800 FFTs at a 700-column strip and 2700 at 900 (3–4× the
    /// single-window pass, which ran one per column), and exactly 2× at `maxColumns` — where it is
    /// also twice web's `MAX_FRAMES` (2048). A clip short enough that its columns fit inside one
    /// window is unchanged: `count == 1`, still sitting in the middle of its slice, which at 700
    /// columns is everything under about ninety seconds.
    struct ColumnFrames {
        /// How many windows this column takes. Always at least one.
        let count: Int
        private let base: Int
        private let reach: Int
        private let limit: Int

        init(count: Int, base: Int, reach: Int, limit: Int) {
            self.count = max(1, count)
            self.base = base
            self.reach = reach
            self.limit = limit
        }

        /// The sample index window `f` starts at.
        func offset(_ f: Int) -> Int {
            guard count > 1 else { return base }
            let j = min(max(f, 0), count - 1)
            return min(max(base + (j * reach) / (count - 1), 0), limit)
        }
    }

    static func frames(start: Int, end: Int, sampleCount n: Int, fftSize: Int) -> ColumnFrames {
        let span = max(1, end - start)
        // The furthest a full window can start; a clip shorter than one window zero-pads instead.
        let limit = max(0, n - fftSize)
        guard span > fftSize else {
            // The window is wider than the slice, so one of them centred already covers it.
            let mid = (start + end) / 2
            return ColumnFrames(count: 1, base: min(max(mid - fftSize / 2, 0), limit), reach: 0, limit: limit)
        }
        // ceil: `count - 1` gaps over `span - fftSize` samples is a hop of at most `fftSize`, which
        // is the invariant. The first window opens on the slice's head and the last closes on its
        // tail, so neighbouring columns abut rather than overlap.
        let count = (span + fftSize - 1) / fftSize
        return ColumnFrames(count: count, base: start, reach: span - fftSize, limit: limit)
    }

    /// The spectrum itself, before any colour: normalised 0…1 magnitudes indexed
    /// `[column * rows + row]`, row 0 = the LOW end of the axis.
    ///
    /// Separated from `build` so the analysis can be asserted as numbers — a tone lands on the row
    /// the log axis says it should — rather than by decoding pixels back into magnitudes.
    static func grid(samples: [Float], rate: Double, columns requestedColumns: Int, rows requestedRows: Int)
        -> (values: [Double], columns: Int, rows: Int) {
        let columns = min(max(requestedColumns, 1), SpectrogramSpec.maxColumns)
        let rows = min(max(requestedRows, 1), SpectrogramSpec.maxRows)
        let n = samples.count
        let fftSize = SpectrogramSpec.fftSize
        guard n > 1, rate > 0, let analyzer = FFTAnalyzer(fftSize: fftSize) else {
            return ([], columns, rows)
        }

        // Per-row bin ranges and tilt gains, computed once: they are a function of the axis and the
        // rate, not of the column, and recomputing them 1400 times is most of a millisecond.
        //
        // The axis top is the DECIMATED NYQUIST, not the spec's 20 kHz ceiling (`axisMax`). Every
        // row then has FFT bins under it, so the strip has no permanently dark band at the top and
        // no band whose height depends on how long the clip is.
        let axisMax = SpectrogramSpec.axisMax(rate: rate)
        let bins = fftSize / 2
        var bandLo = [Int](repeating: 0, count: rows)
        var bandHi = [Int](repeating: 0, count: rows)
        var tilt = [Double](repeating: 1, count: rows)
        for r in 0..<rows {
            let (lo, hi) = LogFrequency.band(row: r, rows: rows, fMax: axisMax)
            // ROUNDED, not truncated. A band is `[lo, hi)` in Hz and a bin is centred on its own
            // frequency, so flooring both edges biases every row half a bin LOW — and near the
            // bottom of the axis, where a band is only two 7.8 Hz bins wide, half a bin is enough
            // to push a tone onto the row above the one the axis says it belongs to. Rounding both
            // edges keeps the tiling exact (one row's `hi` IS the next row's `lo`, so they round to
            // the same integer) while bracketing each row's own centre frequency.
            let b0 = Int((lo * Double(fftSize) / rate).rounded())
            let b1 = Int((hi * Double(fftSize) / rate).rounded())
            // Clamped rather than special-cased: with the axis at Nyquist every `b0` already lands
            // inside the bin range, and this only stops a rounding edge on the top row from asking
            // vDSP to read one past the last bin.
            bandLo[r] = min(max(0, b0), bins - 1)
            bandHi[r] = min(bins, max(bandLo[r] + 1, b1))
            let fc = LogFrequency.frequency(row: r, rows: rows, fMax: axisMax)
            tilt[r] = pow(10, SpectrogramSpec.tiltDbPerOct * log2(fc / SpectrogramSpec.tiltPivotHz) / 20)
        }

        // Pass 1 — every column's tilted band peaks, and the clip's global maximum (which seeds the
        // AGC, so the loudest column lands at exactly the top of the range).
        var mags = [Float](repeating: 0, count: bins)
        var raw = [Float](repeating: 0, count: columns * rows)
        var globalPeak = 0.0
        samples.withUnsafeBufferPointer { input in
            guard let head = input.baseAddress else { return }
            for c in 0..<columns {
                let start = c * n / columns
                let end = max(start + 1, (c + 1) * n / columns)
                let plan = frames(start: start, end: end, sampleCount: n, fftSize: fftSize)
                // Peak-picked across the column's windows, which is how web collapses frames onto
                // columns too (js/spectro.js `analyse`): a column is "the loudest thing that
                // happened in this slice", so a transient inside it survives being one window of
                // several rather than being averaged into the quiet either side of it.
                for f in 0..<plan.count {
                    let offset = plan.offset(f)
                    analyzer.magnitudes(head + offset, count: min(fftSize, n - offset), into: &mags)
                    mags.withUnsafeBufferPointer { m in
                        guard let bin = m.baseAddress else { return }
                        for r in 0..<rows {
                            let lo = bandLo[r], hi = bandHi[r]
                            var peak: Float = 0
                            // vDSP rather than a Swift loop: summed over the rows this scans every
                            // bin of every column — 1.4 M comparisons for one strip.
                            if hi > lo { vDSP_maxv(bin + lo, 1, &peak, vDSP_Length(hi - lo)) }
                            let v = Double(peak) * tilt[r]
                            if f == 0 || Float(v) > raw[c * rows + r] { raw[c * rows + r] = Float(v) }
                            if v > globalPeak { globalPeak = v }
                        }
                    }
                }
            }
        }

        // Pass 2 — roll the AGC across the columns, left to right.
        var agc = RollingAGC(seed: globalPeak)
        var values = [Double](repeating: 0, count: columns * rows)
        var column = [Double](repeating: 0, count: rows)
        for c in 0..<columns {
            for r in 0..<rows { column[r] = Double(raw[c * rows + r]) }
            agc.normalise(&column)
            for r in 0..<rows { values[c * rows + r] = column[r] }
        }
        return (values, columns, rows)
    }
}

// MARK: - Decoding

enum AudioDecimator {
    /// Reads `url` into one mono channel at `rate`, off whatever thread calls it.
    ///
    /// nil on ANY decode failure — an unsupported codec, a truncated download, a converter the
    /// system declines to build. The caller degrades to the silhouette; nothing here is allowed to
    /// throw into a view.
    ///
    /// `truncated` says the sample ceiling was reached before the file ended, which the caller has
    /// to pass on: the strip maps whatever it is given across its whole width, so a truncated
    /// decode drawn as if it were the clip is a picture that lies about where in the take you are.
    static func monoDecimated(url: URL, rate: Double) -> (samples: [Float], truncated: Bool)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let input = file.processingFormat
        guard input.sampleRate > 0, file.length > 0, rate > 0 else { return nil }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }

        let inCapacity: AVAudioFrameCount = 16_384
        let ratio = rate / input.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inCapacity) * ratio) + 4096
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: inCapacity),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity)
        else { return nil }

        var out = [Float]()
        out.reserveCapacity(min(SpectrogramSpec.maxSamples, Int(Double(file.length) * ratio) + 4096))
        var drained = false
        while true {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if drained { outStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuffer, frameCount: inCapacity)
                } catch {
                    drained = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    drained = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error { return out.isEmpty ? nil : (out, true) }
            if let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
            }
            // The ceiling is a hard stop, not a hope: a file whose header lied about its length
            // does not get to allocate without bound.
            if out.count >= SpectrogramSpec.maxSamples {
                out.removeLast(out.count - SpectrogramSpec.maxSamples)
                return (out, true)
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }
        return out.isEmpty ? nil : (out, false)
    }

    /// The clip's duration in seconds, without decoding it. nil when the file will not open.
    static func duration(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

// MARK: - Bounded, and degrading rather than blocking

/// What the analyser is allowed to do for a clip of a given length (PRODUCT §2.11.1: "cost is
/// bounded, and it degrades rather than blocking").
enum SpectrogramPlan: Equatable {
    /// Decode, FFT, colourise: the full strip.
    case spectrum
    /// Past the duration ceiling — decode coarsely for the silhouette, skip the FFT and the bitmap.
    case envelopeOnly
    /// Nothing worth drawing: no duration, or so long that even the envelope pass is not honest.
    case none

    static func forDuration(_ seconds: Double,
                            cap: Double = SpectrogramSpec.durationCap,
                            hardCap: Double = SpectrogramSpec.envelopeCap) -> SpectrogramPlan {
        guard seconds > 0, seconds.isFinite else { return .none }
        if seconds <= cap { return .spectrum }
        return seconds <= hardCap ? .envelopeOnly : .none
    }
}

/// One analysed clip as the view wants it.
struct SpectrogramRender {
    let image: CGImage?
    let envelope: [Double]
    /// True when this is less than a full strip: the plan skipped the spectrum, or the decode
    /// failed and there is nothing but whatever the row already had.
    let degraded: Bool

    static let none = SpectrogramRender(image: nil, envelope: [], degraded: true)
}

enum SpectrogramAnalyzer {
    /// The whole pipeline for one file. Never throws, never blocks, never returns nil: the worst
    /// case is `.none`, which leaves the row drawing whatever silhouette it already had.
    static func analyse(path: String, plan: SpectrogramPlan, columns: Int, rows: Int) -> SpectrogramRender {
        guard plan != .none else { return .none }
        let url = URL(fileURLWithPath: path)
        switch plan {
        case .none:
            return .none
        case .envelopeOnly:
            guard let decoded = AudioDecimator.monoDecimated(url: url, rate: SpectrogramSpec.envelopeRate) else {
                return .none
            }
            return SpectrogramRender(image: nil,
                                     envelope: SpectrogramBuilder.envelope(samples: decoded.samples,
                                                                           rate: SpectrogramSpec.envelopeRate,
                                                                           columns: columns),
                                     degraded: true)
        case .spectrum:
            let seconds = AudioDecimator.duration(url: url) ?? 0
            let rate = SpectrogramSpec.rate(forDuration: seconds)
            guard let decoded = AudioDecimator.monoDecimated(url: url, rate: rate) else { return .none }
            let strip = SpectrogramBuilder.build(samples: decoded.samples, rate: rate,
                                                 columns: columns, rows: rows)
            let image = strip.makeImage()
            return SpectrogramRender(image: image, envelope: strip.envelope,
                                     degraded: image == nil || decoded.truncated)
        }
    }
}
