// Debug — every WaveLoop drop kind in the running app, over a PDS that is not there
// (PROTOCOL.md §12.12, PRODUCT.md §2.36.1). DEBUG builds only; a Release build has no trace of it.
//
// Why it exists: no drop existed on the network when §12.12 was built (the relay's
// `listReposByCollection` for `app.waveloop.social.drop` answered `{"repos":[]}` on 2026-09-25),
// so the only way to see a drop card render, move under a finger or a pointer, open its viewer and
// let go of its memory is to serve one. Launch with `-DropGallery` (simulator:
// `xcrun simctl launch booted ca.lucianlabs.tgsocial -DropGallery`; Mac: pass it to the binary) and
// the app shows one real `DropCard` per kind instead of its screens.
//
// Nothing is faked above the wire: the cards, the `DropStore`, its lane, disk cache, CID check and
// decode budget are the shipped ones. Only the two transports are stubs — the DID document and
// getRecord from `DropGalleryTransport`, the blobs from `DropGalleryBlobs` — and they answer what a
// real PDS was measured to answer (`200` for everything, `Range` ignored). The pictures are the
// same scene the tests use, ported from WaveLoop's `/drop/?demo=` generator: three discs at depths
// 0.3, 0.6 and 0.9 over a far background, the eyes shifted ±0.015 of the width by nearness.

#if DEBUG
import AVFoundation
import CryptoKit
import SceneKit
import SwiftUI
import UIKit

enum DropGalleryLaunch {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-DropGallery") }
}

struct DropGallery: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [DropGalleryFixtures.Entry]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HPTokens.Space.cardGap) {
                if let entries {
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                            HPSectionMark(e.label)
                            DropCard(post: e.post, external: e.external, ref: e.ref)
                        }
                        .accessibilityIdentifier("drop-gallery-\(e.id)")
                    }
                } else {
                    HPMonoSmall("Building drops")
                }
                Color.clear.frame(height: HPTokens.Space.bottomSafe)
            }
            .padding(.horizontal, HPTokens.Space.columnSide)
            .padding(.top, HPTokens.Space.cardPad)
            .frame(maxWidth: HPTokens.Space.columnMax)
            .frame(maxWidth: .infinity)
        }
        .task {
            guard entries == nil else { return }
            let built = await Task.detached(priority: .userInitiated) { DropGalleryFixtures.build() }.value
            // The shipped store over the stub wire, charged to the app's own photo budget, in a
            // disk cache of its own that starts empty each launch (so every download is seen).
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-gallery")
            try? FileManager.default.removeItem(at: dir)
            model.drops = DropStore(reader: AtprotoReader(transport: built.transport), blobs: built.blobs,
                                    images: model.drops.images, disk: DropBlobCache(directory: dir))
            entries = built.entries
        }
    }
}

// MARK: - The fixtures

enum DropGalleryFixtures {
    static let did = "did:plc:gallery2gallery2gallery2"
    static let pds = URL(string: "https://pds.gallery.test")!

    struct Entry: Identifiable {
        let id: String
        let label: String
        let ref: String
        let post: BlueskyPost
        let external: BlueskyExternal
    }

    struct Built: @unchecked Sendable {
        let entries: [Entry]
        let transport: DropGalleryTransport
        let blobs: DropGalleryBlobs
    }

    static func cid(_ data: Data) -> String { Atproto.rawCid(sha256: Array(SHA256.hash(data: data))) }

    static func build() -> Built {
        var bytes: [String: Data] = [:]
        var records: [String: [String: Any]] = [:]
        var entries: [Entry] = []

        func blob(_ data: Data, _ mime: String) -> [String: Any] {
            let c = cid(data)
            bytes[c] = data
            return ["$type": "blob", "ref": ["$link": c], "mimeType": mime, "size": data.count]
        }
        func add(_ rkey: String, label: String, kind: String, fields: [String: [String: Any]], aspect: (Int, Int), extra: [String: Any] = [:]) {
            let ref = "at://\(did)/\(Atproto.dropCollection)/\(rkey)"
            var value: [String: Any] = ["$type": Atproto.dropCollection, "kind": kind, "createdAt": "2026-09-25T18:00:00.000Z",
                                        "aspectRatio": ["width": aspect.0, "height": aspect.1]]
            for (k, v) in fields { value[k] = v }
            for (k, v) in extra { value[k] = v }
            records[rkey] = ["uri": ref, "cid": "bafyreigallerygallerygallery", "value": value]
            // No `thumb`: the poster comes off the PDS as `preview`, rule 7's second path, so the
            // gallery exercises the store for posters too.
            let external = BlueskyExternal(uri: "https://waveloop.app/drop/?at=\(ref)", title: label, description: "", thumb: nil)
            var post = BlueskyPost(uri: "at://\(did)/app.bsky.feed.post/\(rkey)", cid: "bafygallery", authorDid: did,
                                   handle: "gallery.test", displayName: "Drop gallery", avatar: nil, text: RichText(spans: []),
                                   likeCount: 0, replyCount: 0, dropRef: ref)
            post.external = external
            entries.append(Entry(id: rkey, label: label, ref: ref, post: post, external: external))
        }

        let preview = blob(jpeg(scene(.colour, width: 1200, height: 900), quality: 0.7), "image/jpeg")
        add("3gallerystereo", label: "Stereo", kind: "stereo",
            fields: ["left": blob(jpeg(scene(.left)), "image/jpeg"), "right": blob(jpeg(scene(.right)), "image/jpeg"), "preview": preview],
            aspect: (4, 3), extra: ["stereo": ["disparityAdjust": 12]])
        add("3gallerydepth", label: "Depth", kind: "depth",
            fields: ["media": blob(scene(.colour).pngData()!, "image/png"),
                     "depth": blob(scene(.depth, width: 800, height: 600).pngData()!, "image/png"), "preview": preview],
            aspect: (4, 3))
        if let usdz = usdz() {
            add("3gallerymodel", label: "Model (USDZ)", kind: "model",
                fields: ["media": blob(Data(repeating: 0x67, count: 2048), "model/gltf-binary"),
                         "usdz": blob(usdz, "model/vnd.usdz+zip"), "preview": preview],
                aspect: (1, 1))
        }
        add("3galleryglb", label: "Model (GLB only: the link card)", kind: "model",
            fields: ["media": blob(Data(repeating: 0x68, count: 2048), "model/gltf-binary"), "preview": preview], aspect: (1, 1))
        add("3galleryimage", label: "Image", kind: "image",
            fields: ["media": blob(jpeg(scene(.colour, width: 2400, height: 1800)), "image/jpeg"), "preview": preview], aspect: (4, 3))
        add("3galleryaudio", label: "Sound", kind: "audio",
            fields: ["media": blob(wav(seconds: 4), "audio/wav"), "preview": preview], aspect: (1200, 630), extra: ["durationMs": 4000])
        if let mp4 = video(seconds: 3) {
            add("3galleryvideo", label: "Video", kind: "video",
                fields: ["media": blob(mp4, "video/mp4"), "preview": preview], aspect: (4, 3), extra: ["durationMs": 3000])
        }
        return Built(entries: entries, transport: DropGalleryTransport(records: records), blobs: DropGalleryBlobs(bytes: bytes))
    }

    // MARK: Pictures

    enum Frame { case left, right, colour, depth }

    private struct Disc { let x: CGFloat; let y: CGFloat; let r: CGFloat; let depth: CGFloat; let color: UIColor }
    private static let discs = [
        Disc(x: 0.25, y: 0.55, r: 0.16, depth: 0.3, color: .systemTeal),
        Disc(x: 0.55, y: 0.45, r: 0.20, depth: 0.6, color: .systemOrange),
        Disc(x: 0.78, y: 0.60, r: 0.12, depth: 0.9, color: .systemPink),
    ]

    static func scene(_ frame: Frame, width: Int = 1600, height: Int = 1200, drift: CGFloat = 0) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            (frame == .depth ? UIColor.black : UIColor(white: 0.12, alpha: 1)).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            if frame != .depth {
                // A faint grid on the far plane, so the background visibly moves under parallax.
                UIColor(white: 0.2, alpha: 1).setFill()
                for i in stride(from: 0, to: width, by: max(width / 16, 1)) { g.fill(CGRect(x: i, y: 0, width: 2, height: height)) }
                for j in stride(from: 0, to: height, by: max(height / 12, 1)) { g.fill(CGRect(x: 0, y: j, width: width, height: 2)) }
            }
            for d in discs {
                let dx: CGFloat = frame == .left ? 0.015 * d.depth : frame == .right ? -0.015 * d.depth : 0
                let x = d.x + dx + drift * d.depth
                let rect = CGRect(x: (x - d.r) * size.width, y: (d.y - d.r) * size.height,
                                  width: 2 * d.r * size.width, height: 2 * d.r * size.width)
                (frame == .depth ? UIColor(white: d.depth, alpha: 1) : d.color).setFill()
                g.fillEllipse(in: rect)
            }
        }
    }

    static func jpeg(_ image: UIImage, quality: CGFloat = 0.85) -> Data { image.jpegData(compressionQuality: quality)! }

    // MARK: A model

    /// The three discs as spheres at their depths over a slab, written by SceneKit as USDZ — the
    /// Apple copy WaveLoop's lexicon carries beside the GLB.
    static func usdz() -> Data? {
        let scene = SCNScene()
        let slab = SCNNode(geometry: SCNBox(width: 3, height: 0.1, length: 2, chamferRadius: 0.02))
        slab.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.85, alpha: 1)
        slab.position = SCNVector3(0, -0.6, 0)
        scene.rootNode.addChildNode(slab)
        for d in discs {
            let sphere = SCNNode(geometry: SCNSphere(radius: d.r * 2))
            sphere.geometry?.firstMaterial?.diffuse.contents = d.color
            sphere.position = SCNVector3(Float(d.x - 0.5) * 3, Float(0.5 - d.y) * 2, Float(d.depth - 0.5) * 2)
            scene.rootNode.addChildNode(sphere)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: url) }
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: A sound

    /// A 16-bit mono WAV: a slow sweep with a pulse, so the spectrogram strip has something to draw.
    static func wav(seconds: Double, rate: Int = 22_050) -> Data {
        let n = Int(Double(rate) * seconds)
        var samples = [Int16](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let f = 220 + 660 * t / seconds
            phase += 2 * .pi * f / Double(rate)
            let pulse = 0.5 + 0.5 * sin(2 * .pi * 2 * t)
            samples[i] = Int16(sin(phase) * pulse * 12_000)
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(n * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    // MARK: A video

    /// H.264 in an mp4: the discs drifting across, near ones faster. Written with AVAssetWriter, so
    /// it is the flat mp4 the lexicon's `video` kind names.
    static func video(seconds: Double, fps: Int32 = 30) -> Data? {
        let width = 640, height = 480
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(Double(fps) * seconds)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            let image = scene(.colour, width: width, height: height, drift: 0.25 * sin(2 * .pi * Double(i) / Double(frames)))
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
               let cg = image.cgImage {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { return nil }
        return try? Data(contentsOf: url)
    }
}

// MARK: - The wire, stubbed

/// plc.directory and the PDS's getRecord. Everything else is a 404, so nothing here can reach a
/// real host by accident.
struct DropGalleryTransport: HTTPTransport, @unchecked Sendable {
    let records: [String: [String: Any]]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        func reply(_ status: Int, _ object: [String: Any]) -> (Data, HTTPURLResponse) {
            let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        }
        try? await Task.sleep(for: .milliseconds(120))
        if url.host == "plc.directory" {
            return reply(200, ["id": DropGalleryFixtures.did, "alsoKnownAs": ["at://gallery.test"],
                               "service": [["id": "#atproto_pds", "type": "AtprotoPersonalDataServer",
                                            "serviceEndpoint": DropGalleryFixtures.pds.absoluteString]]])
        }
        if url.host == DropGalleryFixtures.pds.host, url.path.hasSuffix("com.atproto.repo.getRecord") {
            let rkey = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "rkey" }?.value ?? ""
            if let record = records[rkey] { return reply(200, record) }
            return reply(400, ["error": "RecordNotFound", "message": "Could not locate record"])
        }
        return reply(404, [:])
    }
}

/// getBlob: the bytes a CID names, in 64 KB chunks a few milliseconds apart — slow enough that the
/// §2.11 ring is on screen for a moment, as it is on a real network.
final class DropGalleryBlobs: BlobSource, @unchecked Sendable {
    let bytes: [String: Data]
    init(bytes: [String: Data]) { self.bytes = bytes }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<BlobEvent, Error> {
        let url = request.url!
        let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cid" }?.value ?? ""
        let body = bytes[cid]
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let body else {
                    continuation.yield(.response(HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: [:])!))
                    continuation.finish()
                    return
                }
                continuation.yield(.response(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                             headerFields: ["Content-Length": "\(body.count)", "Content-Type": "application/octet-stream"])!))
                var i = 0
                while i < body.count, !Task.isCancelled {
                    let end = min(i + (64 << 10), body.count)
                    continuation.yield(.data(body.subdata(in: i..<end)))
                    i = end
                    try? await Task.sleep(for: .milliseconds(12))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
