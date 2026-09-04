// Demo — generated media (PRODUCT.md §2.22.1 "Media is generated, never bundled").
//
// Every image, clip, document and waveform in the demo is produced in-process from the item's key
// as a seed. Nothing ships in the bundle and nothing is fetched, so the world is the same on every
// install without a byte of anyone's content travelling with the app.
//
// Two things make this the demo's network guarantee rather than a nicety (§2.22.4):
//
// 1. Fixture media has NO TDLib file id. Every id here is negative and TDLib's are positive, so a
//    fixture file id can never collide with a real one, and `DemoMedia.isDemoFileId` is a check the
//    loader can actually make.
// 2. This file imports UIKit, AVFoundation and SwiftUI — and no TDLib symbol. `downloadFile` is
//    not reachable from here; the generators are, and `DemoIsolationTests` fails the build if that
//    ever stops being true.
//
// Assets are materialised as real files under a per-session temporary directory, so the app's own
// decode, playback and document paths run exactly as they do on a downloaded file. That is
// deliberate: a demo that swapped the player out would prove nothing about the player.

import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

// MARK: - Deterministic seeding

/// A tiny deterministic generator. Not for cryptography; for putting the same circle in the same
/// place every time, on every launch.
struct DemoRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> Double { Double(next() % 100_000) / 100_000 }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

// MARK: - The generators

/// Pure generation from a fixture key. Not actor-isolated and holding no mutable state: everything
/// it produces is a function of its arguments, which is what lets the heavy renders run off the
/// main thread and what makes them reproducible in a test.
enum DemoRender {
    /// FNV-1a over the key. The same arithmetic on the other two platforms yields the same world;
    /// the contract is the same world, not the same pixels.
    static func seed(_ key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return hash
    }

    /// The House Pour tokens a plate may draw with. Ad-hoc colour would put a palette in the demo
    /// that exists nowhere else in the app; these are the kit's own (design/tokens.json).
    static let plateColors: [UIColor] = [
        UIColor(HPTokens.Colors.accent),
        UIColor(HPTokens.Colors.accent2),
        UIColor(HPTokens.Colors.ink),
        UIColor(HPTokens.Colors.muted),
        UIColor(HPTokens.Colors.bg2),
        UIColor(HPTokens.Colors.panel),
    ]

    // MARK: Plates

    /// A seeded gradient plate carrying the fixture key in its bottom-left corner (§2.22,
    /// indicator 3: "every generated image carries its own key … a single post card, cropped out of
    /// context, still says what it is"). There is no photograph of a person anywhere in the demo
    /// because there is no photograph in the demo at all.
    static func plate(key: String, width: Int, height: Int) -> UIImage {
        var rng = DemoRandom(seed(key))
        let a = plateColors[rng.int(0...(plateColors.count - 1))]
        var b = plateColors[rng.int(0...(plateColors.count - 1))]
        if b === a { b = plateColors[(rng.int(0...(plateColors.count - 1)) + 3) % plateColors.count] }
        let size = CGSize(width: max(1, width), height: max(1, height))
        return renderer(size).image { ctx in
            let cg = ctx.cgContext
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [a.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let shortest = min(size.width, size.height)
            for _ in 0..<rng.int(3...6) {
                let radius = shortest * (0.08 + rng.unit() * 0.22)
                let centre = CGPoint(x: rng.unit() * size.width, y: rng.unit() * size.height)
                cg.setFillColor(plateColors[rng.int(0...(plateColors.count - 1))]
                    .withAlphaComponent(0.10 + rng.unit() * 0.22).cgColor)
                cg.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                          width: radius * 2, height: radius * 2))
            }
            for _ in 0..<rng.int(2...4) {
                let thickness = shortest * (0.01 + rng.unit() * 0.04)
                cg.setFillColor(plateColors[rng.int(0...(plateColors.count - 1))]
                    .withAlphaComponent(0.12 + rng.unit() * 0.20).cgColor)
                cg.fill(CGRect(x: 0, y: rng.unit() * size.height, width: size.width, height: thickness))
            }
            drawKey(key, in: size, context: cg)
        }
    }

    /// One frame of a clip: the plate with a moving House Pour bar over it, at `index / total`.
    static func frame(key: String, index: Int, total: Int, size: CGSize) -> UIImage {
        let base = plate(key: key, width: Int(size.width), height: Int(size.height))
        return renderer(size).image { ctx in
            base.draw(in: CGRect(origin: .zero, size: size))
            let progress = total > 1 ? CGFloat(index) / CGFloat(total - 1) : 0
            let barWidth = size.width * 0.12
            ctx.cgContext.setFillColor(UIColor(HPTokens.Colors.accent).withAlphaComponent(0.9).cgColor)
            ctx.cgContext.fill(CGRect(x: progress * (size.width - barWidth), y: 0,
                                      width: barWidth, height: size.height))
        }
    }

    private static func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// The key, mono, `faint`, bottom-left over a scrim so it survives a bright plate. Inconsolata
    /// where the app's own face is registered (`project.yml` ships it), the system monospace
    /// otherwise — the corner is never blank.
    private static func drawKey(_ key: String, in size: CGSize, context: CGContext) {
        // Proportional to the plate, not a fixed point size. A plate is generated at its own
        // pixel dimensions and then DOWNSAMPLED to whatever the card draws it at, so a fixed size
        // legible in the source is three points on screen — and §2.22's third indicator is only an
        // indicator if the reader can read it. A sixteenth of the width survives the reduction.
        let points = max(10, min(72, size.width / 16))
        let font = UIFont(name: "Inconsolata-Regular", size: points)
            ?? UIFont.monospacedSystemFont(ofSize: points, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor(HPTokens.Colors.faint),
        ]
        let text = key as NSString
        let bounds = text.size(withAttributes: attributes)
        let inset = points * 0.6
        let origin = CGPoint(x: inset, y: size.height - bounds.height - inset)
        context.setFillColor(UIColor(HPTokens.Colors.ink).withAlphaComponent(0.34).cgColor)
        context.fill(CGRect(x: origin.x - inset / 3, y: origin.y - inset / 4,
                            width: bounds.width + inset * 0.66, height: bounds.height + inset / 2))
        text.draw(at: origin, withAttributes: attributes)
    }

    // MARK: Audio

    static let sampleRate = 22_050.0
    /// Where the sweep sits inside the clip (§2.22.1): 0:30 → 0:38, 220 Hz → 880 Hz, logarithmic.
    static let sweepStart = 30.0, sweepEnd = 38.0, sweepLow = 220.0, sweepHigh = 880.0
    /// Two 40 ms clicks a minute, at these offsets into each minute.
    static let clickOffsets = [10.0, 40.0]
    static let clickLength = 0.04

    /// 16-bit mono PCM for `seconds` of the clip: a pink-ish noise bed near −24 dBFS, the sweep,
    /// and the clicks.
    ///
    /// Broadband **plus** tonal on purpose. A pure tone gives §2.11.1's spectrogram one bright row
    /// and nothing else, and a constant-amplitude bed gives the one-pole envelope a rectangle. The
    /// whole reason to synthesise rather than ship silence is that both have a silhouette to draw.
    static func audioSamples(key: String, seconds: Int) -> [Int16] {
        let frames = Int(sampleRate) * max(1, seconds)
        var rng = DemoRandom(seed(key))
        var out = [Int16]()
        out.reserveCapacity(frames)
        var phase = 0.0
        // One-pole low pass over white noise: white alone is too bright to read as rain, and the
        // filter is what tilts it towards pink.
        var pink = 0.0
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            pink = pink * 0.86 + (rng.unit() * 2 - 1) * 0.14
            var value = pink * 0.063  // ≈ −24 dBFS

            if t >= sweepStart, t < sweepEnd {
                let progress = (t - sweepStart) / (sweepEnd - sweepStart)
                phase += 2 * Double.pi * (sweepLow * pow(sweepHigh / sweepLow, progress)) / sampleRate
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                // Eased in and out, so the sweep's own edges are not two more clicks.
                value += sin(phase) * 0.22 * sin(progress * Double.pi)
            }

            let intoMinute = t.truncatingRemainder(dividingBy: 60)
            for start in clickOffsets where intoMinute >= start && intoMinute < start + clickLength {
                let decay = 1 - (intoMinute - start) / clickLength
                value += (rng.unit() * 2 - 1) * 0.5 * decay * decay
            }
            out.append(Int16(max(-32_767, min(32_767, value * 32_767))))
        }
        return out
    }

    /// A 16-bit mono WAV. WAV rather than a compressed format because `AVAudioFile` — the
    /// spectrogram's reader in `Spectrogram.swift` — and `AVPlayer` both open it, so the strip, the
    /// scrubber and the now-playing dock all run their real code against it.
    static func wav(key: String, seconds: Int) -> Data {
        let samples = audioSamples(key: key, seconds: seconds)
        var body = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { body.append(contentsOf: $0) }
        }
        var out = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + body.count))
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                    // PCM header size
        append(UInt16(1))                     // PCM
        append(UInt16(1))                     // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)        // byte rate
        append(UInt16(2))                     // block align
        append(UInt16(16))                    // bits per sample
        out.append(contentsOf: Array("data".utf8))
        append(UInt32(body.count))
        out.append(body)
        return out
    }

    /// Telegram-shaped waveform bytes: 5-bit samples packed little-endian, the exact shape
    /// `WaveformCodec.decode` unpacks. Shipping these in the fixture is what makes §2.11.2's
    /// draw-immediately-then-analyse path the one the voice note runs.
    static func waveform(key: String, seconds: Int) -> Data {
        let count = max(32, min(256, seconds * 4))
        var rng = DemoRandom(seed(key))
        var out = Data()
        var accumulator: UInt32 = 0
        var held = 0
        for i in 0..<count {
            // A shape, not noise: two swells, so the bar chart reads as speech rather than hash.
            let x = Double(i) / Double(count)
            let level = UInt32(max(0, min(31, Int((abs(sin(x * Double.pi * 2)) * 0.7 + rng.unit() * 0.3) * 31))))
            accumulator |= level << UInt32(held)
            held += 5
            while held >= 8 {
                out.append(UInt8(accumulator & 0xFF))
                accumulator >>= 8
                held -= 8
            }
        }
        if held > 0 { out.append(UInt8(accumulator & 0xFF)) }
        return out
    }

    // MARK: Clips

    static let clipFrameRate = 12

    /// Procedural frames → H.264. §2.22.1 argues for a frame source over a bundled mp4, and this is
    /// that argument carried as far as iOS allows: the frames are drawn here, from the key, and
    /// nothing ships — but they are encoded to a real file, because `AVPlayer` draws the inline
    /// player, the poster, the duration pill, the scrubber and the full-screen player, and swapping
    /// it for a bespoke surface would leave every one of those untouched by the demo.
    static func writeClip(key: String, seconds: Int, width: Int, height: Int, to url: URL) async -> Bool {
        let size = CGSize(width: width, height: height)
        let frames = max(1, seconds * clipFrameRate)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            guard let cg = frame(key: key, index: i, total: frames, size: size).cgImage,
                  let pool = adaptor.pixelBufferPool,
                  let buffer = pixelBuffer(from: cg, pool: pool, width: width, height: height) else {
                writer.cancelWriting(); return false
            }
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 400 {
                try? await Task.sleep(for: .milliseconds(5))
                waited += 1
            }
            let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(clipFrameRate))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                writer.cancelWriting(); return false
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool,
                                    width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: Documents

    /// A real PDF, so the in-app document viewer (§2.11) opens it the way it opens a downloaded
    /// one. Its pages say what they are; there is nothing here to mistake for a scanned table.
    static func pdf(key: String, name: String, pages: Int) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)  // US Letter, in points
        let titleFont = UIFont(name: "Inconsolata-SemiBold", size: 18)
            ?? UIFont.monospacedSystemFont(ofSize: 18, weight: .semibold)
        let bodyFont = UIFont(name: "Inconsolata-Regular", size: 12)
            ?? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var rng = DemoRandom(seed(key))
        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            for pageIndex in 0..<max(1, pages) {
                ctx.beginPage()
                UIColor(HPTokens.Colors.panel).setFill()
                ctx.cgContext.fill(page)
                (name as NSString).draw(at: CGPoint(x: 48, y: 56), withAttributes: [
                    .font: titleFont, .foregroundColor: UIColor(HPTokens.Colors.ink)])
                (key as NSString).draw(at: CGPoint(x: 48, y: 82), withAttributes: [
                    .font: bodyFont, .foregroundColor: UIColor(HPTokens.Colors.faint)])
                ("Generated by the tgsocial demo. Page \(pageIndex + 1) of \(pages)." as NSString)
                    .draw(at: CGPoint(x: 48, y: 104), withAttributes: [
                        .font: bodyFont, .foregroundColor: UIColor(HPTokens.Colors.muted)])
                var y: CGFloat = 148
                for row in 0..<28 {
                    let line = String(format: "%02d:%02d   %.2f m",
                                      (pageIndex * 28 + row) % 24, rng.int(0...59), 1.2 + rng.unit() * 3.4)
                    (line as NSString).draw(at: CGPoint(x: 48, y: y), withAttributes: [
                        .font: bodyFont, .foregroundColor: UIColor(HPTokens.Colors.ink)])
                    y += 20
                }
            }
        }
    }
}

// MARK: - The store

/// Registers the fixture world's media and materialises it on first ask. One instance per demo
/// session; `discard()` takes every generated byte with it.
@MainActor
final class DemoMedia {
    /// What a demo file is, and how to make it. `key` is the fixture key (`demo_kiln_log/224-1`),
    /// and it is both the seed and the caption drawn into a plate's corner.
    enum Asset: Equatable {
        case plate(key: String, width: Int, height: Int)
        case audio(key: String, seconds: Int)
        case clip(key: String, seconds: Int, width: Int, height: Int)
        case pdf(key: String, name: String, pages: Int)
    }

    /// TDLib file ids are positive. Demo ids start here and count down, so the two ranges cannot
    /// overlap and a loader can tell them apart without being told which session it is in.
    static let firstFileId = -1_000

    static func isDemoFileId(_ fileId: Int) -> Bool { fileId <= firstFileId }

    private(set) var assets: [Int: Asset] = [:]
    private var materialised: [Int: URL] = [:]
    private var inflight: [Int: Task<String?, Never>] = [:]
    private var nextFileId = DemoMedia.firstFileId
    /// One directory per demo session. "Nothing is saved on this device" (§2.22.5) covers the bytes
    /// the generators wrote, so it goes when the demo does.
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgsocial-demo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func discard() {
        for task in inflight.values { task.cancel() }
        inflight = [:]
        try? FileManager.default.removeItem(at: directory)
        assets = [:]
        materialised = [:]
    }

    // MARK: Registration

    private func register(_ asset: Asset) -> Int {
        let id = nextFileId
        nextFileId -= 1
        assets[id] = asset
        return id
    }

    /// A photo at a given aspect. `uniqueId` is the fixture key — which is also what the plate
    /// carries in its corner, so the image on screen names the row that made it.
    func photo(key: String, width: Int, height: Int) -> PhotoRef {
        // No minithumbnail: TDLib ships those inline and a fixture has none, so the placeholder is
        // the kit's own empty media box rather than an invented blur.
        PhotoRef(fileId: register(.plate(key: key, width: width, height: height)),
                 uniqueId: key, width: width, height: height, minithumbnail: nil)
    }

    func audio(key: String, seconds: Int) -> FileRef {
        FileRef(fileId: register(.audio(key: key, seconds: seconds)), uniqueId: key,
                size: Int64(Double(seconds) * DemoRender.sampleRate * 2), mimeType: "audio/wav",
                fileName: key.replacingOccurrences(of: "/", with: "-") + ".wav")
    }

    func clip(key: String, seconds: Int, width: Int, height: Int) -> FileRef {
        FileRef(fileId: register(.clip(key: key, seconds: seconds, width: width, height: height)),
                uniqueId: key, size: Int64(seconds) * 120_000, mimeType: "video/mp4",
                fileName: key.replacingOccurrences(of: "/", with: "-") + ".mp4")
    }

    func document(key: String, name: String, bytes: Int64, mimeType: String) -> FileRef {
        FileRef(fileId: register(.pdf(key: key, name: name, pages: 3)), uniqueId: key,
                size: bytes, mimeType: mimeType, fileName: name)
    }

    // MARK: Materialising

    /// The local path of a generated file, making it on first ask and coalescing concurrent asks.
    /// Nil only when generation failed — a clip on a device whose encoder refuses, say — in which
    /// case the caller behaves exactly as it does for a download that did not finish.
    func path(fileId: Int) async -> String? {
        if let url = materialised[fileId] { return url.path }
        guard let asset = assets[fileId] else { return nil }
        if let running = inflight[fileId] { return await running.value }
        let url = destination(fileId: fileId, asset: asset)
        let task = Task<String?, Never> { [weak self] in
            let made = await Self.write(asset, to: url)
            guard let self else { return made ? url.path : nil }
            self.inflight[fileId] = nil
            guard made else { return nil }
            self.materialised[fileId] = url
            return url.path
        }
        inflight[fileId] = task
        return await task.value
    }

    /// The size on disk once generated — what a progress ring would divide by. Zero until then.
    func size(fileId: Int) -> Int64 {
        guard let url = materialised[fileId],
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return Int64(size)
    }

    private static func write(_ asset: Asset, to url: URL) async -> Bool {
        switch asset {
        case .plate(let key, let width, let height):
            return await Task.detached(priority: .userInitiated) {
                guard let data = DemoRender.plate(key: key, width: width, height: height).pngData(),
                      (try? data.write(to: url, options: .atomic)) != nil else { return false }
                return true
            }.value
        case .audio(let key, let seconds):
            return await Task.detached(priority: .userInitiated) {
                let data = DemoRender.wav(key: key, seconds: seconds)
                return (try? data.write(to: url, options: .atomic)) != nil
            }.value
        case .clip(let key, let seconds, let width, let height):
            // Not detached: AVAssetWriter drives its own queues and this loop only awaits it.
            return await DemoRender.writeClip(key: key, seconds: seconds, width: width, height: height, to: url)
        case .pdf(let key, let name, let pages):
            return await Task.detached(priority: .userInitiated) {
                let data = DemoRender.pdf(key: key, name: name, pages: pages)
                return (try? data.write(to: url, options: .atomic)) != nil
            }.value
        }
    }

    private func destination(fileId: Int, asset: Asset) -> URL {
        let ext: String
        switch asset {
        case .plate: ext = "png"
        case .audio: ext = "wav"
        case .clip: ext = "mp4"
        case .pdf: ext = "pdf"
        }
        return directory.appendingPathComponent("f\(-fileId).\(ext)")
    }
}
