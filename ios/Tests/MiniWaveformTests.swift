// Unit tests — the now-playing dock's mini waveform (PRODUCT §2.11.2).
//
// The load-bearing claim in §2.11.2 is not about pixels: "It is a view of the analysis the strip
// already did — the same envelope array, resampled to the dock's width. **Playing a clip must never
// trigger a second analysis.**" That is a claim about a COUNT, so `SpectrogramStore.analyses` is a
// count and `MiniWaveformAnalysisTests` asserts against it — including the counterfactual, so the
// assertion is sharp rather than vacuous.
//
// The rest: the resampler that makes one envelope serve two widths, the flat line a degraded clip
// is entitled to, and the two dock controls' hit regions measured on the assembled dock
// (COMPONENTS.md rule 6 — a region is a region only where a neighbour leaves it room).

import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import tgsocial

// MARK: - One analysis, two widths

@MainActor
final class MiniWaveformAnalysisTests: XCTestCase {
    private static let stripColumns = 1_410   // a full-width strip on a 3× phone
    private static let stripRows = 132

    private func tone(seconds: Double = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mini-wave-\(UUID().uuidString).caf")
        try SpectrogramCostTests.writeTone(seconds: seconds, hz: 440, rate: 16_000, to: url)
        return url
    }

    /// The whole of §2.11.2's cost claim, in one test.
    ///
    /// The strip analyses once, at the strip's own pixel width. The dock is a different width and
    /// gets its peaks anyway — because the envelope is published under the clip's identity alone,
    /// not under `uniqueId#columnsxrows` — and the analysis count does not move. Then the
    /// counterfactual: asking the STORE for a strip at the dock's width *does* analyse again. The
    /// dock never makes that call, and this is what the difference is worth.
    func testPlayingAClipDoesNotTriggerASecondAnalysis() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SpectrogramStore(byteLimit: 4 << 20)
        XCTAssertEqual(store.analyses, 0)

        let render = await store.strip(uniqueId: "take3", path: url.path, duration: 2,
                                       columns: Self.stripColumns, rows: Self.stripRows)
        XCTAssertEqual(store.analyses, 1, "the strip should analyse exactly once")
        XCTAssertEqual(render.envelope.count, Self.stripColumns)

        // The dock, at the dock's width. This is the entire data path `DockWaveform` has.
        let dockColumns = DockWaveform.columns(width: HPTokens.Space.miniWaveWidth)
        XCTAssertNotEqual(dockColumns, Self.stripColumns, "the dock is not the strip's width")
        let peaks = store.peaks(uniqueId: "take3", columns: dockColumns)
        print("[mini-wave] strip=\(Self.stripColumns) dock=\(dockColumns) analyses=\(store.analyses)")
        XCTAssertEqual(peaks.count, dockColumns)
        XCTAssertEqual(store.analyses, 1, "drawing the dock triggered a second analysis")

        // Reading it again — a redraw on every playhead tick — still costs nothing.
        _ = store.peaks(uniqueId: "take3", columns: dockColumns)
        _ = store.peaks(uniqueId: "take3", columns: dockColumns)
        XCTAssertEqual(store.analyses, 1)

        // The counterfactual: the call the dock does NOT make would have analysed again, because
        // the strip cache's key contains the pixel size. That is why the envelope is published
        // separately at all.
        _ = await store.strip(uniqueId: "take3", path: url.path, duration: 2,
                              columns: dockColumns, rows: Self.stripRows)
        XCTAssertEqual(store.analyses, 2)
    }

    /// The same envelope, at the same width, is the same array — not a re-derivation.
    func testTheDockDrawsTheStripsOwnPeaks() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SpectrogramStore(byteLimit: 4 << 20)
        let render = await store.strip(uniqueId: "take3", path: url.path, duration: 2,
                                       columns: 400, rows: 44)
        XCTAssertEqual(store.envelope(uniqueId: "take3"), render.envelope)
        XCTAssertEqual(store.peaks(uniqueId: "take3", columns: 400), render.envelope)
    }

    /// A voice note ships its own waveform bytes and needs no decode, so the dock has a shape from
    /// the first frame — before anything has been analysed at all.
    func testAVoiceNotesBytesDockBeforeAnythingIsDecoded() {
        let store = SpectrogramStore(byteLimit: 4 << 20)
        let bytes = WaveformCodec.decode(Data([0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertFalse(bytes.isEmpty)
        store.publish(envelope: bytes, uniqueId: "voice")
        XCTAssertEqual(store.analyses, 0)
        XCTAssertEqual(store.peaks(uniqueId: "voice", columns: 32).count, 32)
    }

    /// "A clip whose strip degraded to the hairline shows a flat line rather than nothing" — so an
    /// unknown clip yields no peaks, which `HPMiniWave` paints as the flat line, and it still costs
    /// no analysis to find that out.
    func testAClipWithNoAnalysisYieldsNoPeaksAndNoAnalysis() {
        let store = SpectrogramStore(byteLimit: 4 << 20)
        XCTAssertNil(store.envelope(uniqueId: "never-seen"))
        XCTAssertTrue(store.peaks(uniqueId: "never-seen", columns: 96).isEmpty)
        XCTAssertEqual(store.analyses, 0)
    }

    /// A memory warning drops the textures — they are the megabytes — and keeps the envelopes,
    /// because flattening the line of the clip that is *currently playing* buys back eleven
    /// kilobytes.
    func testAPurgeDropsTheTextureAndKeepsTheDockLine() async throws {
        let url = try tone()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SpectrogramStore(byteLimit: 4 << 20)
        _ = await store.strip(uniqueId: "take3", path: url.path, duration: 2, columns: 400, rows: 44)
        store.purge()
        XCTAssertNil(store.cached(uniqueId: "take3", columns: 400, rows: 44), "the texture should go")
        XCTAssertFalse(store.peaks(uniqueId: "take3", columns: 96).isEmpty, "the dock line should not")
        XCTAssertEqual(store.analyses, 1)
    }
}

// MARK: - The resampler

final class EnvelopeResampleTests: XCTestCase {
    func testResamplingToItsOwnWidthIsTheIdentity() {
        let peaks = (0..<64).map { Double($0) / 64 }
        XCTAssertEqual(Envelope.resample(peaks, to: 64), peaks)
    }

    /// Narrowing takes the MAXIMUM of each span, not a mean: the follower's fast attack exists to
    /// keep transients, and a mean would average them straight back out.
    func testNarrowingKeepsTheTransientRatherThanAveragingItAway() {
        var peaks = [Double](repeating: 0.1, count: 100)
        peaks[42] = 1.0
        let narrow = Envelope.resample(peaks, to: 10)
        XCTAssertEqual(narrow.count, 10)
        XCTAssertEqual(narrow.max() ?? 0, 1.0, accuracy: 1e-9, "the spike was averaged away")
        // …and only the span it fell in carries it.
        XCTAssertEqual(narrow.filter { $0 > 0.5 }.count, 1)
    }

    /// Widening interpolates between neighbours: there is nothing between two peaks to maximise.
    func testWideningInterpolatesBetweenNeighbours() {
        let wide = Envelope.resample([0, 1], to: 5)
        XCTAssertEqual(wide.count, 5)
        XCTAssertEqual(wide.first ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(wide.last ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(wide[2], 0.5, accuracy: 1e-9)
        // Monotone in, monotone out.
        XCTAssertEqual(wide, wide.sorted())
    }

    /// Degenerate inputs are the flat line, not a crash and not an empty path.
    func testDegenerateInputsFlattenRatherThanFail() {
        XCTAssertEqual(Envelope.resample([], to: 4), [0, 0, 0, 0])
        XCTAssertEqual(Envelope.resample([0.7], to: 3), [0.7, 0.7, 0.7])
        XCTAssertTrue(Envelope.resample([0.1, 0.9], to: 0).isEmpty)
        XCTAssertEqual(Envelope.resample([0.1, 0.9, 0.4], to: 1), [0.9])
    }

    /// Every output column comes from somewhere: no NaN, no value outside the input's range.
    func testResamplingStaysInsideTheInputsRange() {
        let peaks = (0..<317).map { abs(sin(Double($0) / 9)) }
        for columns in [1, 7, 96, 317, 1_410] {
            let out = Envelope.resample(peaks, to: columns)
            XCTAssertEqual(out.count, columns)
            for v in out {
                XCTAssertTrue(v.isFinite)
                XCTAssertGreaterThanOrEqual(v, peaks.min() ?? 0)
                XCTAssertLessThanOrEqual(v, (peaks.max() ?? 1) + 1e-9)
            }
        }
    }

    /// One vertex per point, capped — the dock is a stroked path redrawn on every playhead tick,
    /// not a texture built once like the strip.
    func testTheDockAsksForOneColumnPerPoint() {
        XCTAssertEqual(DockWaveform.columns(width: 96), 96)
        XCTAssertEqual(DockWaveform.columns(width: 0), 1)
        XCTAssertEqual(DockWaveform.columns(width: 99_999), SpectrogramSpec.maxColumns)
    }
}

// MARK: - The painted control

@MainActor
final class MiniWavePaintingTests: XCTestCase {
    /// It paints thinner than it is touched: the band is the token, the frame is the hit target.
    func testItPaintsAtTheTokenHeightAndIsTouchedAtTheTarget() {
        let host = UIHostingController(rootView: HPMiniWave(peaks: [0, 0.5, 1], progress: 0.5))
        let size = host.sizeThatFits(in: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        print("[mini-wave] painted=\(HPTokens.Space.miniWaveHeight) frame=\(size)")
        XCTAssertEqual(size.height, HPTokens.Space.touchMin)
        XCTAssertLessThan(HPTokens.Space.miniWaveHeight, HPTokens.Space.touchMin,
                          "the point of §2.11.2 is that it paints thinner than it is touched")
    }

    /// And it never lets the dock squeeze it under a hit target's width, however long the title is.
    func testItKeepsAWidthFloor() {
        let host = UIHostingController(rootView: HPMiniWave(peaks: [], progress: 0))
        let size = host.sizeThatFits(in: CGSize(width: 1, height: HPTokens.Space.touchMin))
        XCTAssertGreaterThanOrEqual(size.width, HPTokens.Space.miniWaveWidth)
        XCTAssertGreaterThanOrEqual(size.width, HPTokens.Space.touchMin)
    }
}

// MARK: - The dock's hit regions, on the assembled dock (COMPONENTS.md rule 6)

@MainActor
final class DockHitRegionTests: XCTestCase {
    /// The dock's own width: the app column, less its side padding.
    private static let dockWidth = HPTokens.Space.columnMax - 2 * HPTokens.Space.columnSide

    /// Both dock controls keep a full `touchMin` in both axes, and they TILE — the boundary between
    /// the play button and the waveform is a line, not an overlap. Measured on the assembled row,
    /// because the waveform's frame reaches past its painted band and a region that lands on a
    /// neighbour is not a region.
    func testBothDockControlsKeepAFullRegionAndDoNotOverlap() throws {
        let regions = measure()
        let play = try XCTUnwrap(regions[DockRegion.play], "regions: \(regions.keys.sorted())")
        let wave = try XCTUnwrap(regions[DockRegion.wave])
        print("[regions] play=\(play) wave=\(wave)")
        for (label, rect) in [(DockRegion.play, play), (DockRegion.wave, wave)] {
            XCTAssertGreaterThanOrEqual(rect.width, HPTokens.Space.touchMin, "\(label) is \(rect.width)pt wide")
            XCTAssertGreaterThanOrEqual(rect.height, HPTokens.Space.touchMin, "\(label) is \(rect.height)pt tall")
        }
        XCTAssertFalse(play.intersects(wave.insetBy(dx: 0.5, dy: 0.5)),
                       "the play button's region \(play) overlaps the waveform's \(wave)")
    }

    /// A long title truncates against the waveform rather than squeezing it out: the row's flexible
    /// member is the waveform, and its floor is a token.
    func testALongTitleDoesNotSqueezeTheWaveformBelowItsFloor() throws {
        let long = String(repeating: "Take 3 — the one with the bass ", count: 4)
        let wave = try XCTUnwrap(measure(title: long)[DockRegion.wave])
        print("[regions] longTitle wave=\(wave)")
        XCTAssertGreaterThanOrEqual(wave.width, HPTokens.Space.miniWaveWidth - 0.5)
    }

    private final class RegionBox { var regions: [HPTouchRegion] = [] }

    private func measure(title: String = "Take 3") -> [String: CGRect] {
        let box = RegionBox()
        let reported = expectation(description: "hit regions reported")
        reported.assertForOverFulfill = false
        // The shipped dock. `HPMiniWave` stands in for `DockWaveform`, which is that view plus a
        // `GeometryReader` that reads the width to resample against — the geometry is the kit
        // view's, and it is the geometry this test is about (the same substitution
        // `PostHeaderTests` makes for `NodeAvatar`).
        let probe = HPNowPlaying(title: title, elapsed: "0:41", playing: true,
                                 onToggle: {}, onOpen: {}, playRegion: DockRegion.play) {
            HPMiniWave(peaks: (0..<64).map { Double($0 % 8) / 8 }, progress: 0.4,
                       label: "\(title) progress", regionLabel: DockRegion.wave, onSeek: { _ in })
        }
        .frame(width: Self.dockWidth)
        .environment(\.hpMeasureTouchTargets, true)
        .hpTouchSpace()
        .onPreferenceChange(HPTouchTargetKey.self) { regions in
            guard !regions.isEmpty else { return }
            box.regions = regions
            reported.fulfill()
        }
        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: HPTokens.Space.columnMax, height: 200))
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
