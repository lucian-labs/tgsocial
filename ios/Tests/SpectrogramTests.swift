// Unit tests — the spectrogram strip (PRODUCT §2.11.1). Everything the picture is made of, tested
// as arithmetic rather than by eye:
//
//   · the one-pole follower — a step rises at the attack rate and decays at the release rate;
//   · the log frequency axis — a tone's centre frequency lands on the row the axis says it does,
//     end to end through a real FFT and not only in the mapping function;
//   · the rolling AGC — a QUIET clip still spans the strip, which is the whole reason it is not
//     absolute dBFS;
//   · the ramp — stops interpolate and both ends clamp, from the generated token set;
//   · the duration cap and the fallback path — what happens when the clip is too long, or when the
//     file will not decode at all;
//   · and the strip's hit region, measured on an ASSEMBLED card with a neighbour after it
//     (COMPONENTS.md rule 6: a region is a region only where something can actually reach it).

import AVFoundation
import CoreGraphics
import SwiftUI
import UIKit
import XCTest
@testable import tgsocial

// MARK: - The one-pole envelope

final class OnePoleFollowerTests: XCTestCase {
    private let rate: Double = 16_000

    /// A step held for one attack time constant covers 1 − 1/e of the distance. That is what "fast
    /// attack" *means*, and it is the claim the coefficient derivation has to keep.
    func testAStepRisesAtTheAttackRate() {
        var follower = OnePoleFollower(attackMs: 4, releaseMs: 160, rate: rate)
        let samples = Int(0.004 * rate)          // one attack time constant
        for _ in 0..<samples { follower.process(1) }
        XCTAssertEqual(follower.value, 1 - 1 / M_E, accuracy: 0.01)
    }

    /// …and released to silence it falls to 1/e over one release time constant.
    func testItDecaysAtTheReleaseRate() {
        var follower = OnePoleFollower(attackMs: 4, releaseMs: 160, rate: rate, start: 1)
        let samples = Int(0.160 * rate)          // one release time constant
        for _ in 0..<samples { follower.process(0) }
        XCTAssertEqual(follower.value, 1 / M_E, accuracy: 0.01)
    }

    /// The asymmetry is the point: a transient must show, a tail must linger.
    func testAttackIsFarFasterThanRelease() {
        let follower = OnePoleFollower(rate: rate)
        XCTAssertGreaterThan(follower.attack, follower.release * 10)
    }

    /// The coefficient is derived from the rate, never written down. Halving the rate halves the
    /// number of samples in a time constant, so the per-sample coefficient roughly doubles.
    func testTheCoefficientTracksTheRate() {
        let fast = SpectrogramSpec.coefficient(ms: 10, rate: 8_000)
        let slow = SpectrogramSpec.coefficient(ms: 10, rate: 16_000)
        XCTAssertEqual(fast / slow, 2, accuracy: 0.02)
        // Degenerate inputs do not produce a NaN that would poison a whole envelope.
        XCTAssertEqual(SpectrogramSpec.coefficient(ms: 0, rate: rate), 1)
        XCTAssertEqual(SpectrogramSpec.coefficient(ms: 10, rate: 0), 1)
    }

    /// The follower never overshoots its input, so the silhouette stays inside the strip.
    func testItNeverExceedsItsInput() {
        var follower = OnePoleFollower(rate: rate)
        for _ in 0..<100_000 { XCTAssertLessThanOrEqual(follower.process(0.7), 0.7 + 1e-9) }
    }
}

// MARK: - The log frequency axis

final class LogFrequencyAxisTests: XCTestCase {
    private let rows = 128
    /// The axis top an analysis at the rate ceiling actually runs on: 8 kHz, not the 20 kHz
    /// ceiling. Every assertion here names its own top, because the mapping has no default.
    private let top = SpectrogramSpec.axisMax(rate: SpectrogramSpec.maxRate)

    /// The inverse holds for every row: the row's own centre frequency maps back to that row.
    func testEveryRowsCentreFrequencyMapsBackToIt() {
        for row in 0..<rows {
            let f = LogFrequency.frequency(row: row, rows: rows, fMax: top)
            XCTAssertEqual(LogFrequency.row(frequency: f, rows: rows, fMax: top), row,
                           "row \(row) at \(f) Hz")
        }
    }

    /// 20 Hz–20 kHz is three decades, so a decade up is a third of the way up the strip. This is
    /// the property that makes the axis *log* rather than linear — asserted against the spec's
    /// ceiling because it is a claim about the mapping, not about any one analysis.
    func testADecadeIsAThirdOfTheStrip() {
        let ceiling = SpectrogramSpec.fMax
        let bottom = LogFrequency.row(frequency: 20, rows: 99, fMax: ceiling)
        let decade = LogFrequency.row(frequency: 200, rows: 99, fMax: ceiling)
        let twoDecades = LogFrequency.row(frequency: 2_000, rows: 99, fMax: ceiling)
        XCTAssertEqual(bottom, 0)
        XCTAssertEqual(decade, 33)
        XCTAssertEqual(twoDecades, 66)
    }

    /// Both ends clamp rather than running off the strip.
    func testTheAxisClampsAtBothEnds() {
        XCTAssertEqual(LogFrequency.row(frequency: 1, rows: rows, fMax: top), 0)
        XCTAssertEqual(LogFrequency.row(frequency: 0.0001, rows: rows, fMax: top), 0)
        XCTAssertEqual(LogFrequency.row(frequency: 40_000, rows: rows, fMax: top), rows - 1)
    }

    /// Bands tile: one row's top edge is the next row's bottom, with no gap and no overlap, so no
    /// FFT bin is counted twice or dropped.
    func testBandsTileWithoutGaps() {
        for row in 0..<(rows - 1) {
            let a = LogFrequency.band(row: row, rows: rows, fMax: top)
            let b = LogFrequency.band(row: row + 1, rows: rows, fMax: top)
            XCTAssertEqual(a.hi, b.lo, accuracy: a.hi * 1e-9)
            XCTAssertGreaterThan(a.hi, a.lo)
        }
        XCTAssertEqual(LogFrequency.band(row: 0, rows: rows, fMax: top).lo,
                       SpectrogramSpec.fMin, accuracy: 1e-9)
        XCTAssertEqual(LogFrequency.band(row: rows - 1, rows: rows, fMax: top).hi,
                       top, accuracy: 1e-6)
    }

    /// The axis top is the DECIMATED NYQUIST, not the spec's 20 kHz ceiling. A literal 20 kHz top
    /// over §2.11.1's 8–16 kHz analysis band leaves rows nothing can ever light — 17 of a 132-row
    /// strip at 16 kHz and 30 at 8 kHz — and the size of that dead band moves with the clip's
    /// length, because the rate does. The ceiling still binds if the rate is ever high enough.
    func testTheAxisTopIsTheAnalysisNyquist() {
        XCTAssertEqual(SpectrogramSpec.axisMax(rate: SpectrogramSpec.maxRate), 8_000)
        XCTAssertEqual(SpectrogramSpec.axisMax(rate: SpectrogramSpec.minRate), 4_000)
        XCTAssertEqual(SpectrogramSpec.axisMax(rate: 96_000), SpectrogramSpec.fMax)
        XCTAssertEqual(SpectrogramSpec.axisMax(rate: 0), SpectrogramSpec.fMax)
        // Nothing sits above the top row, at either end of the rate band.
        for rate in [SpectrogramSpec.maxRate, SpectrogramSpec.minRate] {
            let axis = SpectrogramSpec.axisMax(rate: rate)
            XCTAssertEqual(LogFrequency.band(row: 131, rows: 132, fMax: axis).hi, rate / 2, accuracy: 1e-6)
        }
    }
}

// MARK: - The rolling AGC

final class RollingAGCTests: XCTestCase {
    /// The reason the strip is normalised by a rolling peak and not by absolute dBFS: a quiet
    /// recording has to still fill the strip instead of reading as silence.
    func testAQuietClipStillSpansTheStrip() {
        let quiet = [0.0, 0.00002, 0.0001]     // peak ≈ −80 dBFS
        var agc = RollingAGC(seed: quiet.max() ?? 0)
        let out = agc.normalise(quiet)
        XCTAssertEqual(out.max() ?? 0, 1, accuracy: 0.001, "the loudest bin has to reach the top")
        XCTAssertEqual(out.min() ?? 1, 0, accuracy: 0.001, "and the quietest still reaches the bottom")
    }

    /// The same shape at two very different levels normalises to the same picture — level-blind by
    /// construction, which is what "rolling peak rather than absolute dBFS" buys.
    func testNormalisationIsBlindToAbsoluteLevel() {
        let shape = [0.001, 0.01, 0.1, 1.0]
        var loud = RollingAGC(seed: 1.0)
        var quiet = RollingAGC(seed: 0.001)
        let a = loud.normalise(shape)
        let b = quiet.normalise(shape.map { $0 * 0.001 })
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: 0.001) }
    }

    /// True digital silence stays dark — the floor is what stops the AGC opening until noise fills
    /// the strip.
    func testDigitalSilenceStaysDark() {
        var agc = RollingAGC(seed: 0)
        for _ in 0..<500 { XCTAssertEqual(agc.normalise([0, 0, 0]).max() ?? 1, 0, accuracy: 1e-9) }
        XCTAssertEqual(agc.peak, SpectrogramSpec.agcFloor, accuracy: 1e-12)
    }

    /// Instant attack, slow release — Wake's law. A loud column raises the reference at once; the
    /// quiet columns after it only ease it back down.
    func testTheReferenceAttacksInstantlyAndReleasesSlowly() {
        var agc = RollingAGC(seed: 0.01)
        _ = agc.normalise([1.0])
        XCTAssertEqual(agc.peak, 1, accuracy: 1e-12)
        _ = agc.normalise([0])
        XCTAssertEqual(agc.peak, SpectrogramSpec.agcRelease, accuracy: 1e-12)
    }

    /// Everything below the dynamic range is clamped to the bottom rather than going negative.
    /// (The tolerance is a tenth of a dB rather than exact: a column whose max only *equals* the
    /// reference releases it by one step, which lifts the whole column by 0.05 dB.)
    func testTheDynamicRangeIsTheFloorOfTheDisplay() {
        var agc = RollingAGC(seed: 1)
        let out = agc.normalise([1, pow(10, -SpectrogramSpec.dynRangeDb / 20), 1e-12])
        XCTAssertEqual(out[0], 1, accuracy: 0.01)
        XCTAssertEqual(out[1], 0, accuracy: 0.01)
        XCTAssertEqual(out[2], 0)
    }

    /// The floor is relative to the clip, not absolute — which is what lets a take recorded far
    /// below the absolute floor still reach the top of the strip.
    func testTheFloorIsRelativeToTheClipButStillAbsoluteForSilence() {
        XCTAssertEqual(RollingAGC(seed: 0).floor, SpectrogramSpec.agcFloor)
        // A normally-levelled clip: the absolute floor binds, exactly as it does in Wake.
        XCTAssertEqual(RollingAGC(seed: 1).floor, SpectrogramSpec.agcFloor)
        // A very quiet one: the floor drops with it, one display range below its own peak.
        let quiet = RollingAGC(seed: 1e-4)
        XCTAssertLessThan(quiet.floor, SpectrogramSpec.agcFloor)
        XCTAssertEqual(quiet.peak, 1e-4, accuracy: 1e-12, "the reference is the clip's own peak")
    }
}

// MARK: - The ramp (the generated `--ramp-*` token set)

final class HPRampTests: XCTestCase {
    /// The stops themselves come from tokens.json through build.mjs — this is the shape the look
    /// specifies (PRODUCT §2.11.1): transparent at the bottom, `accent2` at the top.
    func testTheRampIsTheTokenSet() {
        let stops = HPTokens.Ramp.stops
        XCTAssertGreaterThanOrEqual(stops.count, 2)
        XCTAssertEqual(stops.first?.at, 0)
        XCTAssertEqual(stops.last?.at, 1)
        XCTAssertEqual(stops.first?.a, 0, "the low end of the ramp is transparent, not a colour")
        XCTAssertEqual(stops.last?.a, 1)
        // Ordered, and opacity never goes backwards: louder is never fainter.
        for i in 1..<stops.count {
            XCTAssertGreaterThan(stops[i].at, stops[i - 1].at)
            XCTAssertGreaterThanOrEqual(stops[i].a, stops[i - 1].a)
        }
    }

    /// Every stop is reproduced exactly at its own position.
    func testEachStopIsReturnedAtItsOwnPosition() {
        for stop in HPTokens.Ramp.stops {
            let c = HPRamp.rgba(Double(stop.at))
            XCTAssertEqual(c.r, stop.r, accuracy: 1e-9)
            XCTAssertEqual(c.g, stop.g, accuracy: 1e-9)
            XCTAssertEqual(c.b, stop.b, accuracy: 1e-9)
            XCTAssertEqual(c.a, stop.a, accuracy: 1e-9)
        }
    }

    /// Between two stops it is a straight interpolation — the midpoint is the average.
    func testStopsInterpolate() {
        let stops = HPTokens.Ramp.stops
        for i in 1..<stops.count {
            let lo = stops[i - 1], hi = stops[i]
            let mid = HPRamp.rgba(Double(lo.at + hi.at) / 2)
            XCTAssertEqual(mid.r, (lo.r + hi.r) / 2, accuracy: 1e-9)
            XCTAssertEqual(mid.g, (lo.g + hi.g) / 2, accuracy: 1e-9)
            XCTAssertEqual(mid.b, (lo.b + hi.b) / 2, accuracy: 1e-9)
            XCTAssertEqual(mid.a, (lo.a + hi.a) / 2, accuracy: 1e-9)
        }
    }

    /// Both ends clamp. A magnitude outside 0…1 — an AGC that has not caught up, a NaN-free but
    /// out-of-range value — paints the end stop rather than wrapping to the other end of the ramp.
    func testBothEndsClamp() {
        let low = HPRamp.rgba(0), high = HPRamp.rgba(1)
        for v in [-1.0, -0.001, -1e9] {
            let c = HPRamp.rgba(v)
            XCTAssertEqual(c.r, low.r); XCTAssertEqual(c.a, low.a)
        }
        for v in [1.001, 2.0, 1e9] {
            let c = HPRamp.rgba(v)
            XCTAssertEqual(c.r, high.r); XCTAssertEqual(c.a, high.a)
        }
    }

    /// The bitmap's pixels are PREMULTIPLIED, because the ramp's low end is transparent by design
    /// and `premultipliedFirst` is what the CGImage is built with.
    func testPackedPixelsArePremultiplied() {
        XCTAssertEqual(HPRamp.packedBGRA(0), 0, "a transparent stop is a zero pixel, not a black one")
        let top = HPRamp.packedBGRA(1)
        let stop = HPTokens.Ramp.stops[HPTokens.Ramp.stops.count - 1]
        XCTAssertEqual((top >> 24) & 0xFF, 255)
        XCTAssertEqual((top >> 16) & 0xFF, UInt32(stop.r * 255), accuracy: 1)
        // Halfway up, alpha is partial and the colour channels are scaled by it — never above it.
        let mid = HPRamp.packedBGRA(0.2)
        let midAlpha = (mid >> 24) & 0xFF
        XCTAssertLessThanOrEqual((mid >> 16) & 0xFF, midAlpha)
        XCTAssertLessThanOrEqual((mid >> 8) & 0xFF, midAlpha)
        XCTAssertLessThanOrEqual(mid & 0xFF, midAlpha)
    }
}

// MARK: - Bounded, and degrading rather than blocking

final class SpectrogramPlanTests: XCTestCase {
    /// PRODUCT §2.11.1's ceiling: "past a duration ceiling (about 10 minutes) … fall back to the
    /// amplitude-only silhouette".
    func testTheDurationCapDecidesThePlan() {
        XCTAssertEqual(SpectrogramPlan.forDuration(1), .spectrum)
        XCTAssertEqual(SpectrogramPlan.forDuration(SpectrogramSpec.durationCap - 1), .spectrum)
        XCTAssertEqual(SpectrogramPlan.forDuration(SpectrogramSpec.durationCap), .spectrum)
        XCTAssertEqual(SpectrogramPlan.forDuration(SpectrogramSpec.durationCap + 1), .envelopeOnly)
        XCTAssertEqual(SpectrogramPlan.forDuration(SpectrogramSpec.envelopeCap + 1), .none)
    }

    /// A duration we do not have is not a reason to decode an unknown file.
    func testAnUnknownDurationBuysNoAnalysis() {
        XCTAssertEqual(SpectrogramPlan.forDuration(0), .none)
        XCTAssertEqual(SpectrogramPlan.forDuration(-5), .none)
        XCTAssertEqual(SpectrogramPlan.forDuration(.infinity), .none)
        XCTAssertEqual(SpectrogramPlan.forDuration(.nan), .none)
    }

    /// The decoded buffer is bounded whatever the clip's length: short clips get the full rate,
    /// and at the cap the adaptive rate lands exactly on the floor of §2.11.1's 8–16 kHz band.
    func testTheDecodedBufferIsBoundedByAnAdaptiveRate() {
        XCTAssertEqual(SpectrogramSpec.rate(forDuration: 30), SpectrogramSpec.maxRate)
        XCTAssertEqual(SpectrogramSpec.rate(forDuration: SpectrogramSpec.durationCap),
                       SpectrogramSpec.minRate, accuracy: 1)
        for seconds in [1.0, 30, 120, 300, 450, 600] {
            let samples = SpectrogramSpec.rate(forDuration: seconds) * seconds
            XCTAssertLessThanOrEqual(samples, Double(SpectrogramSpec.maxSamples) + 1, "\(seconds) s")
        }
    }

    /// The knee is 300 s, not the 600 s duration cap: `maxSamples / maxRate`. Naming it stops the
    /// two numbers being confused — a clip is at the full rate for five minutes, then slides.
    func testTheRateKneeIsHalfTheDurationCap() {
        XCTAssertEqual(SpectrogramSpec.rateKnee, 300, accuracy: 1e-9)
        XCTAssertEqual(SpectrogramSpec.rate(forDuration: SpectrogramSpec.rateKnee),
                       SpectrogramSpec.maxRate)
        XCTAssertLessThan(SpectrogramSpec.rate(forDuration: SpectrogramSpec.rateKnee + 1),
                          SpectrogramSpec.maxRate)
        XCTAssertGreaterThan(SpectrogramSpec.rate(forDuration: SpectrogramSpec.durationCap - 1),
                             SpectrogramSpec.minRate)
    }

    /// The envelope-only fallback has to cover the WHOLE clip, not its first forty minutes: its
    /// rate times its own ceiling has to fit the decoded-buffer cap, or the strip stretches a
    /// truncated decode across the full width and lies about the time axis.
    func testTheFallbackRateCoversItsOwnCeiling() {
        XCTAssertLessThanOrEqual(SpectrogramSpec.envelopeRate * SpectrogramSpec.envelopeCap,
                                 Double(SpectrogramSpec.maxSamples))
    }

    /// Work is bounded in the other axis too: a pathological layout cannot ask for a texture
    /// nobody can afford.
    func testColumnsAndRowsAreCapped() {
        let strip = SpectrogramBuilder.build(samples: [Float](repeating: 0, count: 4_000),
                                             rate: 16_000, columns: 99_999, rows: 99_999)
        XCTAssertEqual(strip.columns, SpectrogramSpec.maxColumns)
        XCTAssertEqual(strip.rows, SpectrogramSpec.maxRows)
    }
}

// MARK: - The analysis itself

final class SpectrogramBuilderTests: XCTestCase {
    private let rate: Double = 16_000
    /// The axis the grid actually runs on at `rate` — 8 kHz, not the 20 kHz ceiling. Every
    /// expectation below has to be computed against the SAME top the analyser used, which is the
    /// reason `LogFrequency` has no default for it.
    private var axis: Double { SpectrogramSpec.axisMax(rate: rate) }

    private func sine(hz: Double, seconds: Double, amplitude: Float = 0.5, rate: Double) -> [Float] {
        let n = Int(seconds * rate)
        return (0..<n).map { amplitude * sinf(Float(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// Deterministic broadband noise — a seeded LCG, not `random()`, so a row that goes dark fails
    /// every run rather than one in ten. Written out step by step: the one-expression form is over
    /// the Swift type checker's budget.
    private func noise(seconds: Double, rate: Double) -> [Float] {
        var state: UInt64 = 0x2545F4914F6CDD1D
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        let scale = 1.0 / 16_777_216.0          // 2^24, the width of the bits taken below
        for i in 0..<count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit: Double = Double(state >> 40) * scale
            let bipolar: Double = (unit * 2.0 - 1.0) * 0.4
            out[i] = Float(bipolar)
        }
        return out
    }

    /// The claim that ties the FFT to the axis: a 1 kHz tone lights the row the log mapping says
    /// 1 kHz belongs to — measured through the real analyser, not through the mapping alone.
    func testAToneLandsOnTheRowTheAxisPutsItOn() {
        let rows = 128
        let grid = SpectrogramBuilder.grid(samples: sine(hz: 1_000, seconds: 2, rate: rate),
                                           rate: rate, columns: 16, rows: rows)
        XCTAssertEqual(grid.rows, rows)
        let expected = LogFrequency.row(frequency: 1_000, rows: rows, fMax: axis)
        let column = 8
        var brightest = 0, best = -1.0
        for r in 0..<rows where grid.values[column * rows + r] > best {
            best = grid.values[column * rows + r]
            brightest = r
        }
        print("[spectrogram] 1 kHz → row \(brightest), axis says \(expected) of \(rows)")
        XCTAssertLessThanOrEqual(abs(brightest - expected), 1,
                                 "1 kHz lit row \(brightest); the axis puts it on \(expected)")
        // …and the tone is genuinely a peak, not a flat field: two octaves down is near the floor.
        let farBelow = LogFrequency.row(frequency: 250, rows: rows, fMax: axis)
        XCTAssertGreaterThan(best - grid.values[column * rows + farBelow], 0.5)
    }

    /// Two tones, two rows. The strip has to separate them or it is a level meter with colour.
    func testTwoTonesLightTwoRows() {
        let rows = 128
        let a = sine(hz: 300, seconds: 2, amplitude: 0.4, rate: rate)
        let b = sine(hz: 3_000, seconds: 2, amplitude: 0.4, rate: rate)
        let mixed = zip(a, b).map { $0 + $1 }
        let grid = SpectrogramBuilder.grid(samples: mixed, rate: rate, columns: 8, rows: rows)
        let lowRow = LogFrequency.row(frequency: 300, rows: rows, fMax: axis)
        let highRow = LogFrequency.row(frequency: 3_000, rows: rows, fMax: axis)
        let mid = LogFrequency.row(frequency: 950, rows: rows, fMax: axis)
        let column = 4
        let low = grid.values[column * rows + lowRow]
        let high = grid.values[column * rows + highRow]
        let gap = grid.values[column * rows + mid]
        print("[spectrogram] 300 Hz row \(lowRow) = \(low), 3 kHz row \(highRow) = \(high), gap = \(gap)")
        // The two tones are equal in amplitude but NOT equal on the strip, and that is the pink
        // tilt working: +4.5 dB/oct about 1 kHz puts 3 kHz about 15 dB above 300 Hz, which is
        // roughly a third of the display range. Both are unmistakably lit; the top one is brighter.
        XCTAssertGreaterThan(low, 0.6)
        XCTAssertGreaterThan(high, 0.9)
        XCTAssertGreaterThan(high, low)
        XCTAssertLessThan(gap, 0.4, "the gap between them should be dark")
        XCTAssertGreaterThan(low - gap, 0.25)
    }

    /// The AGC again, but end to end: the same take recorded 60 dB quieter produces the same strip.
    func testAQuietRecordingProducesTheSameStrip() {
        let loud = SpectrogramBuilder.grid(samples: sine(hz: 1_000, seconds: 1, amplitude: 0.5, rate: rate),
                                           rate: rate, columns: 8, rows: 64)
        let quiet = SpectrogramBuilder.grid(samples: sine(hz: 1_000, seconds: 1, amplitude: 0.0005, rate: rate),
                                            rate: rate, columns: 8, rows: 64)
        XCTAssertEqual(loud.values.count, quiet.values.count)
        for (a, b) in zip(loud.values, quiet.values) { XCTAssertEqual(a, b, accuracy: 0.02) }
        XCTAssertEqual(quiet.values.max() ?? 0, 1, accuracy: 0.02)
    }

    /// No row of the strip is structurally dead. The axis stops at the analysis Nyquist, so
    /// broadband content lights the TOP row at BOTH ends of §2.11.1's 8–16 kHz rate band — the
    /// 8 kHz end being the one a clip between five and ten minutes gets.
    ///
    /// This is the regression this test exists for: with the axis pinned at a literal 20 kHz, the
    /// top 17 of these 132 rows could never light at 16 kHz and the top 30 could never light at
    /// 8 kHz — 10pt of a 44pt control, dead, and the dead band's height set by the clip's length.
    func testTheTopRowLightsAtBothEndsOfTheRateBand() {
        let rows = 132
        for r in [SpectrogramSpec.maxRate, SpectrogramSpec.minRate] {
            let grid = SpectrogramBuilder.grid(samples: noise(seconds: 1, rate: r),
                                               rate: r, columns: 8, rows: rows)
            let top = grid.values[4 * rows + (rows - 1)]
            print("[spectrogram] \(Int(r)) Hz analysis → top row = \(top)")
            XCTAssertGreaterThan(top, 0, "the top row is dark at an \(Int(r)) Hz analysis rate")
        }
    }

    /// And every row in between has bins under it: the band collapse never asks for an empty
    /// range, at either end of the rate band.
    func testEveryRowHasBinsUnderIt() {
        let rows = SpectrogramSpec.maxRows
        for r in [SpectrogramSpec.maxRate, SpectrogramSpec.minRate] {
            let axis = SpectrogramSpec.axisMax(rate: r)
            let bins = SpectrogramSpec.fftSize / 2
            for row in 0..<rows {
                let (lo, _) = LogFrequency.band(row: row, rows: rows, fMax: axis)
                let firstBin = Int(lo * Double(SpectrogramSpec.fftSize) / r)
                XCTAssertLessThan(firstBin, bins, "row \(row) starts above Nyquist at \(Int(r)) Hz")
            }
        }
    }

    /// §2.11.1 opens with "a short-time FFT **across the clip**" — the strip is a picture of the
    /// whole clip, not a periodic sample of it. Web holds that with one invariant, `hop <= fftSize`
    /// (js/spectro.js `framePlan`, and the `MAX_FRAMES` note above it): every sample sits inside at
    /// least one window. iOS lays the STFT out per column rather than per frame, so the same
    /// invariant reads "every column's windows cover the column's slice" — and until this test it
    /// did not hold past about ninety seconds.
    ///
    /// Measured rather than argued: 150 s at 16 kHz across a phone-width strip puts 3428 samples in
    /// a column and, with one 2048-point window centred in it, leaves 690 samples blind at each end
    /// — 43 ms of clip, per column, that no FFT ever reads. The burst below is 32 ms of 2 kHz
    /// dropped squarely in that blind head, and it is the only sound in the file: if the column
    /// stays dark, the strip painted silence over a transient that is really there.
    func testABurstBetweenTheWindowsStillLightsItsColumn() {
        let columns = 700, rows = 64
        let n = Int(150 * rate)
        let column = 400
        let start = column * n / columns
        let end = (column + 1) * n / columns
        let fftSize = SpectrogramSpec.fftSize
        XCTAssertGreaterThan(end - start, fftSize, "pick a length whose columns are wider than a window")

        // The blind head is everything before the centred window opens.
        let windowOpens = (start + end) / 2 - fftSize / 2
        let burst = sine(hz: 2_000, seconds: 0.032, amplitude: 0.8, rate: rate)
        let burstAt = start + 64
        XCTAssertLessThan(burstAt + burst.count, windowOpens,
                          "the burst has to land in the gap, not in the window")

        var samples = [Float](repeating: 0, count: n)
        for i in 0..<burst.count { samples[burstAt + i] = burst[i] }

        let grid = SpectrogramBuilder.grid(samples: samples, rate: rate, columns: columns, rows: rows)
        let row = LogFrequency.row(frequency: 2_000, rows: rows, fMax: axis)
        let lit = grid.values[column * rows + row]
        print("[spectrogram] burst at +\(burstAt - start) of a \(end - start)-sample column → \(lit)")
        XCTAssertGreaterThan(lit, 0.5,
                             "the burst is inside column \(column) and the column is dark: the strip sampled the clip instead of covering it")
    }

    /// …and the invariant behind it, at the two ends of the rate band: a column's windows leave no
    /// sample of that column unread. This is `framePlan`'s `hop <= fftSize` in iOS's per-column
    /// shape, and it is what stops the burst above from being one lucky offset.
    func testAColumnsWindowsCoverEverySampleInIt() {
        let fftSize = SpectrogramSpec.fftSize
        for seconds in [30.0, 150.0, 600.0] {
            let r = SpectrogramSpec.rate(forDuration: seconds)
            let n = Int(seconds * r)
            let columns = 700
            for column in [0, 1, 349, 699] {
                let start = column * n / columns
                let end = (column + 1) * n / columns
                let frames = SpectrogramBuilder.frames(start: start, end: end, sampleCount: n, fftSize: fftSize)
                var reach = frames.offset(0)
                XCTAssertLessThanOrEqual(reach, start, "column \(column) starts unread at \(seconds)s")
                for f in 0..<frames.count {
                    let o = frames.offset(f)
                    XCTAssertLessThanOrEqual(o, reach, "a \(o - reach)-sample gap opened at \(seconds)s, column \(column)")
                    reach = max(reach, o + fftSize)
                }
                XCTAssertGreaterThanOrEqual(reach, end, "column \(column) ends unread at \(seconds)s")
            }
        }
    }

    /// The envelope is the shape of the take: a burst in the middle peaks in the middle columns and
    /// the silence around it stays flat.
    func testTheEnvelopeFollowsTheShapeOfTheTake() {
        let n = Int(rate)                       // one second
        var samples = [Float](repeating: 0, count: n)
        for i in (n / 2)..<(n / 2 + n / 10) { samples[i] = 0.8 }
        let env = SpectrogramBuilder.envelope(samples: samples, rate: rate, columns: 20)
        XCTAssertEqual(env.count, 20)
        XCTAssertEqual(env.max() ?? 0, 1, accuracy: 1e-9, "normalised to the clip's own peak")
        XCTAssertGreaterThan(env[10], 0.9)
        XCTAssertLessThan(env[2], 0.05)
        // Slow release: the tail after the burst is still above the silence before it.
        XCTAssertGreaterThan(env[13], env[2])
    }

    /// Silence is silence — no division by a zero peak, no NaN painted across the strip.
    func testASilentClipProducesAFlatEnvelopeAndNoNaN() {
        let env = SpectrogramBuilder.envelope(samples: [Float](repeating: 0, count: 8_000),
                                              rate: rate, columns: 32)
        XCTAssertEqual(env.count, 32)
        for v in env { XCTAssertEqual(v, 0) }
        let strip = SpectrogramBuilder.build(samples: [Float](repeating: 0, count: 8_000),
                                             rate: rate, columns: 32, rows: 32)
        XCTAssertEqual(strip.pixels.count, 32 * 32)
        for p in strip.pixels { XCTAssertEqual(p, 0, "silence is transparent, not a colour") }
    }

    /// The texture is a real CGImage of exactly the requested pixels — the thing the view blits.
    func testTheStripBecomesAnImageOfItsOwnDimensions() throws {
        let strip = SpectrogramBuilder.build(samples: sine(hz: 440, seconds: 1, rate: rate),
                                             rate: rate, columns: 200, rows: 64)
        XCTAssertEqual(strip.pixels.count, 200 * 64)
        XCTAssertEqual(strip.byteCount, 200 * 64 * 4)
        let image = try XCTUnwrap(strip.makeImage())
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 64)
        XCTAssertEqual(image.bitsPerPixel, 32)
    }

    /// A degenerate input returns an empty texture rather than a crash or a half-built one.
    func testAnEmptyBufferProducesNoTexture() {
        let strip = SpectrogramBuilder.build(samples: [], rate: rate, columns: 32, rows: 32)
        XCTAssertTrue(strip.pixels.isEmpty)
        XCTAssertTrue(strip.envelope.isEmpty)
        XCTAssertNil(strip.makeImage())
    }
}

// MARK: - Cost, on a real file

final class SpectrogramCostTests: XCTestCase {
    /// A 30 s clip written as a real audio file, decoded, analysed and colourised at the pixel size
    /// a phone actually draws the strip at. Prints the measured cost; asserts only a ceiling loose
    /// enough to survive a loaded CI machine — the number in the log is the point, the assertion is
    /// there so a ten-fold regression fails rather than scrolling past.
    ///
    /// Read the printed number knowing which build produced it: `make test` is Debug, so Swift is
    /// at `-Onone` and the sample loops cost roughly twenty times what they do shipped. On an M-series
    /// simulator this measures ~265 ms unoptimised and ~12 ms with `SWIFT_OPTIMIZATION_LEVEL=-O`,
    /// decode included. Both are off the main actor either way.
    func testThirtySecondsOfAudioEndToEnd() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrogram-30s-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(seconds: 30, hz: 440, rate: 44_100, to: url)

        let columns = 1_410, rows = 132        // a full-width strip on a 3× phone
        let started = CFAbsoluteTimeGetCurrent()
        let render = SpectrogramAnalyzer.analyse(path: url.path, plan: .spectrum, columns: columns, rows: rows)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        let image = try XCTUnwrap(render.image, "a 30 s tone should analyse")
        print(String(format: "[spectrogram] 30 s clip → %d×%d strip in %.1f ms (%d KB texture)",
                     image.width, image.height, elapsed * 1000,
                     image.bytesPerRow * image.height / 1024))
        XCTAssertEqual(image.width, columns)
        XCTAssertEqual(image.height, rows)
        XCTAssertEqual(render.envelope.count, columns)
        XCTAssertFalse(render.degraded)
        XCTAssertLessThan(elapsed, 5, "30 s of audio took \(elapsed) s to analyse")
    }

    /// The texture's real cost, which is what the byte budget charges for it.
    func testAFullWidthStripCostsUnderAMegabyte() throws {
        let strip = SpectrogramBuilder.build(samples: [Float](repeating: 0.1, count: 480_000),
                                             rate: 16_000, columns: 1_410, rows: 132)
        print("[spectrogram] full-width texture = \(strip.byteCount / 1024) KB")
        XCTAssertLessThan(strip.byteCount, 1 << 20)
    }

    static func writeTone(seconds: Double, hz: Double, rate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.5 * sinf(Float(2 * Double.pi * hz * Double(i) / rate))
        }
        try file.write(from: buffer)
    }
}

// MARK: - How it degrades

final class SpectrogramFallbackTests: XCTestCase {
    /// A file that is not there, or not audio, produces nothing — no throw, no crash, no partial
    /// texture. The row keeps whatever silhouette it already had (a voice note's waveform bytes).
    func testADecodeFailureDegradesToNothingRatherThanThrowing() {
        let missing = SpectrogramAnalyzer.analyse(path: "/nonexistent/not-a-file.m4a",
                                                  plan: .spectrum, columns: 100, rows: 32)
        XCTAssertNil(missing.image)
        XCTAssertTrue(missing.envelope.isEmpty)
        XCTAssertTrue(missing.degraded)

        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertNoThrow(try Data("this is not an audio file".utf8).write(to: junk))
        XCTAssertNil(AudioDecimator.monoDecimated(url: junk, rate: 16_000)?.samples)
        let render = SpectrogramAnalyzer.analyse(path: junk.path, plan: .spectrum, columns: 100, rows: 32)
        XCTAssertNil(render.image)
        XCTAssertTrue(render.degraded)
    }

    /// Past the ceiling the spectrum is skipped and what comes back is the amplitude-only
    /// silhouette — sized to the strip, marked degraded, and with no texture to pay for.
    func testPastTheCeilingItIsTheSilhouetteOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectrogram-fallback-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try SpectrogramCostTests.writeTone(seconds: 2, hz: 440, rate: 16_000, to: url)

        let render = SpectrogramAnalyzer.analyse(path: url.path, plan: .envelopeOnly, columns: 120, rows: 32)
        XCTAssertNil(render.image, "the envelope-only plan pays for no texture")
        XCTAssertEqual(render.envelope.count, 120)
        XCTAssertTrue(render.degraded)
        XCTAssertGreaterThan(render.envelope.max() ?? 0, 0.9)
    }

    /// `.none` never touches the disk at all.
    func testThePlanNoneReadsNothing() {
        let render = SpectrogramAnalyzer.analyse(path: "/dev/null", plan: .none, columns: 100, rows: 32)
        XCTAssertNil(render.image)
        XCTAssertTrue(render.envelope.isEmpty)
    }

    /// A voice note's silhouette needs no decode at all: TDLib's bytes are already 0…1 heights.
    func testAVoiceNoteHasItsSilhouetteBeforeAnythingIsDecoded() {
        let waveform = Data([0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
        let samples = WaveformCodec.decode(waveform)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(samples.max() ?? 0, 1, accuracy: 1e-9)
        for v in samples { XCTAssertTrue((0...1).contains(v)) }
    }
}

// MARK: - The cache key

final class SpectrogramStoreKeyTests: XCTestCase {
    /// The key is the FILE's identity plus the pixel size — nothing about where the row is. That is
    /// what makes the same clip in the feed and in a thread share one analysis.
    func testTheKeyIsTheFileAndTheSize() {
        let feed = SpectrogramStore.key("abc123", columns: 1_410, rows: 132)
        let thread = SpectrogramStore.key("abc123", columns: 1_410, rows: 132)
        XCTAssertEqual(feed, thread)
        XCTAssertNotEqual(feed, SpectrogramStore.key("other", columns: 1_410, rows: 132))
        XCTAssertNotEqual(feed, SpectrogramStore.key("abc123", columns: 700, rows: 132))
        XCTAssertNotEqual(feed, SpectrogramStore.key("abc123", columns: 1_410, rows: 66))
    }

    /// An entry's cost is the texture's real buffer, not a constant — the same rule the image cache
    /// charges by, because it is the same budget.
    func testAnEntryCostsWhatItsTextureCosts() throws {
        let strip = SpectrogramBuilder.build(samples: [Float](repeating: 0.2, count: 32_000),
                                             rate: 16_000, columns: 300, rows: 64)
        let image = try XCTUnwrap(strip.makeImage())
        let entry = SpectrogramEntry(SpectrogramRender(image: image, envelope: strip.envelope, degraded: false))
        XCTAssertEqual(entry.cost, image.bytesPerRow * image.height + 300 * MemoryLayout<Double>.size)
        XCTAssertGreaterThan(SpectrogramEntry(.none).cost, 0, "an empty entry still costs something")
    }
}

// MARK: - Which surfaces get the strip (PRODUCT §2.11.1)

final class StripBearingSurfaceTests: XCTestCase {
    /// §2.11.1, first sentence of the last paragraph: "Voice notes and video notes use the same
    /// strip." A video note is a player row like a voice note is, so the strip is its scrubber —
    /// the circle stays the picture. This was the half of that sentence the first pass missed:
    /// only the audio and voice rows were converted, and a video note rendered no scrubber at all.
    func testAVideoNoteUsesTheStrip() {
        XCTAssertTrue(InlineVideoView.Mode.videoNote.usesSpectrogramStrip)
    }

    /// And the second sentence is the exemption: "Video keeps its poster and transport; this
    /// replaces the audio scrubber only." That is video MESSAGES, which keep the hairline.
    func testAVideoMessageKeepsTheHairline() {
        XCTAssertFalse(InlineVideoView.Mode.video.usesSpectrogramStrip)
        XCTAssertFalse(InlineVideoView.Mode.animation.usesSpectrogramStrip)
    }

    /// Both video kinds carry a transport row; a muted looping animation has no playhead to move.
    func testOnlyAnAnimationHasNoTransportRow() {
        XCTAssertTrue(InlineVideoView.Mode.video.hasTransport)
        XCTAssertTrue(InlineVideoView.Mode.videoNote.hasTransport)
        XCTAssertFalse(InlineVideoView.Mode.animation.hasTransport)
    }
}

// MARK: - The hit region, on an assembled card (COMPONENTS.md rule 6)

@MainActor
final class SpectrogramHitRegionTests: XCTestCase {
    private static let cardWidth = HPTokens.Space.columnMax - 2 * HPTokens.Space.columnSide

    /// The strip is 44pt tall, so — unlike the header's controls — its painted shape simply *is*
    /// its target and it needs no overlay. This asserts that on the ASSEMBLED card: measured in one
    /// coordinate space, with the post text laid out after it and taking every point they share.
    func testTheStripKeepsAFullRegionAndTakesNothingFromItsNeighbour() throws {
        let regions = measure()
        let strip = try XCTUnwrap(regions[PostCardRegion.strip], "regions: \(regions.keys.sorted())")
        let text = try XCTUnwrap(regions[PostCardRegion.text])
        print("[regions] strip=\(strip) text=\(text)")
        XCTAssertGreaterThanOrEqual(strip.height, HPTokens.Space.touchMin, "the strip is \(strip.height)pt tall")
        XCTAssertGreaterThanOrEqual(strip.width, HPTokens.Space.touchMin)
        XCTAssertFalse(strip.intersects(text),
                       "the strip's region \(strip) reaches into the post text's tap surface \(text)")
    }

    /// And the painted height is the token, not a number typed into the view.
    func testThePaintedHeightIsTheToken() {
        let host = UIHostingController(rootView: HPSpectrogramStrip(content: .empty, progress: 0))
        let size = host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(size.height, max(HPTokens.Space.stripHeight, HPTokens.Space.touchMin))
    }

    private final class RegionBox { var regions: [HPTouchRegion] = [] }

    private func measure() -> [String: CGRect] {
        let box = RegionBox()
        let reported = expectation(description: "hit regions reported")
        reported.assertForOverFulfill = false
        let envelope = (0..<64).map { Double($0 % 8) / 8 }
        let probe = HPCard {
            HPPlayerRow(title: "Take 3", subtitle: "Ana Iliovic", elapsed: "0:04", total: "1:12",
                        state: .playing, buttonLabel: "Pause Take 3", onButton: {}) {
                HPSpectrogramStrip(content: .init(image: nil, envelope: envelope),
                                   progress: 0.35,
                                   label: "Take 3 progress",
                                   regionLabel: PostCardRegion.strip,
                                   onSeek: { _ in })
            }
            PostTextBlock(text: RichText(spans: [RichSpan(text: "Cut at the transient.",
                                                          kind: .plain, url: nil)]),
                          forwardedFrom: nil, label: "Open thread", onOpen: {}, onDetails: {})
        }
        .frame(width: Self.cardWidth)
        .environment(\.hpMeasureTouchTargets, true)
        .hpTouchSpace()
        .onPreferenceChange(HPTouchTargetKey.self) { regions in
            guard !regions.isEmpty else { return }
            box.regions = regions
            reported.fulfill()
        }
        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: HPTokens.Space.columnMax, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        wait(for: [reported], timeout: 5)
        window.isHidden = true
        window.rootViewController = nil

        var out: [String: CGRect] = [:]
        for region in box.regions { out[region.label] = region.rect }
        return out
    }
}
