// Repo — the spectrogram strip's cache and its one entry point from a view (PRODUCT.md §2.11.1,
// §2.11.2).
//
// Three things this exists to guarantee.
//
// **One analysis per clip.** The strip is static once computed, so it is computed once and cached
// against the FILE'S OWN identity (`uniqueId`) plus the pixel size it was drawn at — never against
// a screen, a row index, or a message id. The same clip in the feed and in a thread is the same
// key, so the second one to appear awaits the first one's task instead of decoding again.
//
// **One analysis per clip across *widths*, too.** The dock's mini waveform (§2.11.2) is the same
// envelope at another width — "playing a clip must never trigger a second analysis" — and the strip
// cache cannot serve it, because its key contains the pixel size and the dock is not the strip's
// width. So the envelope is published separately, keyed by `uniqueId` alone, and the dock reads it
// through `peaks(uniqueId:columns:)`, which resamples and never analyses. `analyses` counts the
// times the analyser actually ran, which is what `MiniWaveformTests` asserts against.
//
// **Bounded bytes.** A strip is a bitmap like any decoded photo, so it is charged to the same
// budget rather than opening a second one beside it: `AppModel` derives the budget once
// (`ImageCache.swift` states the derivation) and splits it, and this cache drops everything on a
// memory warning through the same `MemoryPressureWatch` the image cache uses. The envelopes are not
// dropped with it: an envelope is a few hundred doubles against a texture's hundreds of kilobytes,
// and dropping them would flatten the dock of the clip that is playing to buy back nothing.

import CoreGraphics
import Foundation
import UIKit

/// NSCache needs a class, and the render is a struct: this is the box.
final class SpectrogramEntry: NSObject {
    let render: SpectrogramRender
    init(_ render: SpectrogramRender) { self.render = render }

    /// Bytes this entry holds: the texture's real buffer plus the envelope's doubles.
    var cost: Int {
        let pixels = render.image.map { $0.bytesPerRow * $0.height } ?? 0
        return max(pixels + render.envelope.count * MemoryLayout<Double>.size, 1)
    }
}

/// The same box for an envelope on its own — what the dock draws (§2.11.2).
final class EnvelopeEntry: NSObject {
    let peaks: [Double]
    init(_ peaks: [Double]) { self.peaks = peaks }
    var cost: Int { max(peaks.count * MemoryLayout<Double>.size, 1) }
}

@MainActor @Observable
final class SpectrogramStore {
    /// How many times the cache has been dropped under memory pressure — observable for the same
    /// reason `MediaLoader.imagePurges` is: so the Status sheet can say so, and so a test can prove
    /// the warning actually arrives.
    private(set) var purges = 0

    /// How many times the analyser has actually run. §2.11.2's "playing a clip must never trigger a
    /// second analysis" is a claim about this number, so it is a number and not a comment.
    private(set) var analyses = 0

    @ObservationIgnored private let cache = NSCache<NSString, SpectrogramEntry>()
    /// Envelopes by `uniqueId` alone — width-independent, so the dock can be any width (§2.11.2).
    @ObservationIgnored private let envelopes = NSCache<NSString, EnvelopeEntry>()
    @ObservationIgnored private var inflight: [String: Task<SpectrogramRender, Never>] = [:]
    @ObservationIgnored private var memoryWarning: MemoryPressureWatch?

    /// Bytes of strip texture this cache may hold, surfaced for the Status sheet.
    let byteLimit: Int

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
        cache.totalCostLimit = byteLimit
        // A count ceiling as well, for the same reason the image cache carries one: a feed of
        // one-second voice notes makes tiny strips, and bytes alone would let thousands accumulate.
        cache.countLimit = 64
        cache.name = "tgsocial.spectrogram-strips"
        // The envelopes are three orders of magnitude smaller — a full-width one is ~11 KB — so the
        // same count ceiling bounds them at about a megabyte, and they are charged nothing against
        // the texture budget.
        envelopes.countLimit = 64
        envelopes.name = "tgsocial.spectrogram-envelopes"
        memoryWarning = MemoryPressureWatch { [weak self] in self?.purge() }
    }

    /// The cache key: the file's identity and the pixel size of the strip. Nothing about *where*
    /// the row is — that is the whole point.
    nonisolated static func key(_ uniqueId: String, columns: Int, rows: Int) -> String {
        "\(uniqueId)#\(columns)x\(rows)"
    }

    func cached(uniqueId: String, columns: Int, rows: Int) -> SpectrogramRender? {
        cache.object(forKey: Self.key(uniqueId, columns: columns, rows: rows) as NSString)?.render
    }

    // MARK: The envelope, shared across widths (§2.11.2)

    /// Records the silhouette one clip is drawn with, whatever produced it: the analyser's one-pole
    /// follower, or a voice note's own TDLib waveform bytes, which need no decode at all. The strip
    /// publishes; the dock reads. Nothing here analyses.
    func publish(envelope: [Double], uniqueId: String) {
        guard !envelope.isEmpty else { return }
        let entry = EnvelopeEntry(envelope)
        envelopes.setObject(entry, forKey: uniqueId as NSString, cost: entry.cost)
    }

    /// The envelope for a clip at whatever width it was analysed at, or nil when nothing has
    /// analysed it yet.
    func envelope(uniqueId: String) -> [Double]? {
        envelopes.object(forKey: uniqueId as NSString)?.peaks
    }

    /// What the dock draws (§2.11.2): the strip's own envelope resampled to the dock's width, or an
    /// empty array when no strip has run — which `HPMiniWave` paints as the flat line. This method
    /// is the whole of the dock's data path, and it cannot analyse: there is no file path in it.
    func peaks(uniqueId: String, columns: Int) -> [Double] {
        guard let peaks = envelope(uniqueId: uniqueId) else { return [] }
        return Envelope.resample(peaks, to: columns)
    }

    // MARK: Analysis

    /// Analyse (or return the analysis of) one clip.
    ///
    /// `duration` decides the plan before a byte is read, so a three-hour file costs a comparison
    /// rather than a decode. The work itself runs in a **detached** task at utility priority: a
    /// 30 s clip is tens of milliseconds of FFT, which is several dropped frames if it happens on
    /// the main actor mid-scroll.
    ///
    /// Concurrent callers on the same key coalesce onto one task, so the feed row and the thread
    /// row do not each pay for a decode.
    @discardableResult
    func strip(uniqueId: String, path: String, duration: Double,
               columns: Int, rows: Int) async -> SpectrogramRender {
        let key = Self.key(uniqueId, columns: columns, rows: rows)
        if let hit = cache.object(forKey: key as NSString) { return hit.render }
        if let running = inflight[key] { return await running.value }

        let plan = SpectrogramPlan.forDuration(duration)
        guard plan != .none else { return .none }

        let task = Task<SpectrogramRender, Never> { [weak self] in
            // Cleared from INSIDE the task, not after `await task.value`: a caller whose `.task(id:)`
            // is cancelled mid-await never reaches its own cleanup, and the finished task — holding
            // a bitmap — would sit in `inflight` for the rest of the session.
            defer { self?.inflight[key] = nil }
            self?.analyses += 1
            let render = await Task.detached(priority: .utility) {
                SpectrogramAnalyzer.analyse(path: path, plan: plan, columns: columns, rows: rows)
            }.value
            // A failed decode is not cached: the file may simply not be finished downloading, and
            // caching "nothing" would make the row permanently blank.
            if render.image != nil || !render.envelope.isEmpty {
                self?.insert(render, key: key)
                self?.publish(envelope: render.envelope, uniqueId: uniqueId)
            }
            return render
        }
        inflight[key] = task
        return await task.value
    }

    private func insert(_ render: SpectrogramRender, key: String) {
        let entry = SpectrogramEntry(render)
        cache.setObject(entry, forKey: key as NSString, cost: entry.cost)
    }

    /// Drops every cached strip. Rows on screen keep their own `@State` copy, so nothing goes
    /// blank; a row scrolled back into view re-analyses from the file, which is still on disk. The
    /// envelopes stay — see the note at the top of this file.
    func purge() {
        cache.removeAllObjects()
        purges += 1
    }
}
