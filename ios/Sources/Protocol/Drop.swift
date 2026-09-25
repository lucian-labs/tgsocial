// Protocol — reading a WaveLoop drop (PROTOCOL.md §12.12). Pure Swift, no I/O.
//
// §12.6 (`Atproto.dropRef`) finds a drop ref on a post; this file is the part of §12.12 two clients
// must agree on to render the same drop the same way: which records are drops (rule 2), which blob
// references count (rule 4), what each kind needs and when (rule 7), when a drop falls back to its
// link card (rule 8), and the numbers WaveLoop's `/drop/` viewer draws with (rule 10). The network,
// the caches and the views sit on top of this in `DropStore.swift` and `DropViews.swift`.
//
// `AtprotoVectorTests` runs `atproto.dropRecord` in `docs/card-vectors.json` against `dropPlan`.
// Web and Android lag §12.12 and do not run those vectors yet (§12.12 "Platforms").

import CoreGraphics
import Foundation

/// The six kinds WaveLoop's lexicon names (`knownValues`, an open set — §12.12 rule 8). There is no
/// 3D video kind: `video` is a flat mp4, and the 3D kinds are two stills and a mesh (§12.10).
enum DropKind: String, CaseIterable, Equatable {
    case audio, video, image, stereo, depth, model

    /// PRODUCT §2.36.1's kind pill. Only the 3D kinds carry one; the others look like the media
    /// they are (a video has its duration pill, a sound its player row).
    var pill: String? {
        switch self {
        case .stereo: return DropCopy.stereoPill
        case .depth: return DropCopy.depthPill
        case .model: return DropCopy.modelPill
        case .audio, .video, .image: return nil
        }
    }
}

/// One blob reference that survived rule 4: a base32 CIDv1, a type the field accepts, and a size
/// under the field's cap. `size` is nil for the legacy `{cid, mimeType}` form.
struct DropBlob: Equatable, Hashable {
    let cid: String
    let mimeType: String
    let size: Int?
    /// The lexicon cap for the field it came from — enforced again on the wire (rule 4, last para).
    let cap: Int

    /// The file extension the disk cache stores it under. AVFoundation, SceneKit and Quick Look all
    /// decide what a local file is from its extension, so a blob named only by its CID would not
    /// play, load or preview.
    var fileExtension: String {
        switch mimeType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": return "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/mpeg": return "mp3"
        case "model/vnd.usdz+zip": return "usdz"
        case "model/gltf-binary": return "glb"
        default: return "bin"
        }
    }
}

/// A getRecord answer that rule 2 accepted, with every blob field rule 4 kept.
struct DropRecord: Equatable {
    let ref: String
    /// The record's CID, kept beside it (rule 2).
    let cid: String
    /// `kind` as written — possibly one this build does not know (rule 8).
    let kindName: String
    var kind: DropKind? { DropKind(rawValue: kindName) }
    /// Field name → blob, only the fields that passed rule 4.
    let blobs: [String: DropBlob]
    /// `aspectRatio` width / height, or nil.
    let aspect: Double?
    let durationMs: Int?
    /// `stereo.disparityAdjust`, only when inside the lexicon's −200…200 (rule 10).
    let disparityAdjust: Int?
}

/// What a card does with a drop (rule 7 and rule 8), the shape `atproto.dropRecord` states.
struct DropPlan: Equatable {
    /// nil is rule 8's link card; nothing else is meaningful then.
    let kind: DropKind?
    /// Blob field names, in order, fetched once the card is on screen.
    let onScreen: [String]
    /// Blob field names fetched when the reader taps.
    let onTap: [String]
    let aspect: Double?
    /// Stereo's starting shift, a fraction of the box width (rule 10). nil for every other kind.
    let shift: Double?

    static let link = DropPlan(kind: nil, onScreen: [], onTap: [], aspect: nil, shift: nil)
    var isLink: Bool { kind == nil }
}

extension Atproto {
    // MARK: §12.12 rule 4 — blob references

    /// Rule 4's caps: the lexicon's `maxSize` per field, in bytes.
    static let dropCaps: [String: Int] = [
        "preview": 1_000_000,
        "left": 5_000_000, "right": 5_000_000,
        "depth": 5_000_000,
        "media": 50_000_000,
        "usdz": 50_000_000,
    ]

    private static let base32Lower = Set("abcdefghijklmnopqrstuvwxyz234567")

    /// `b` then eight or more of `[a-z2-7]`: a base32 CIDv1 string. The CID goes into a getBlob URL,
    /// and this grammar is what keeps anything else — an `&`, a `/`, a second query parameter — out
    /// of it (rule 4, first bullet).
    static func isBlobCid(_ s: String?) -> Bool {
        guard let s, s.count >= 9, s.first == "b" else { return false }
        return s.dropFirst().allSatisfy { base32Lower.contains($0) }
    }

    /// Whether `field` of a `kind` drop accepts `mime` (rule 4's table). `media`'s answer depends on
    /// the kind; `stereo`'s media is the original spatial HEIC, accepted as anything because it is
    /// never fetched (rule 7).
    static func dropAccepts(field: String, kind: String, mime: String) -> Bool {
        let m = mime.lowercased()
        let stills: Set<String> = ["image/jpeg", "image/png", "image/webp"]
        switch field {
        case "preview", "left", "right": return stills.contains(m)
        case "depth": return m == "image/png" || m == "image/jpeg"
        case "usdz": return m == "model/vnd.usdz+zip"
        case "media":
            switch kind {
            case "audio": return m.hasPrefix("audio/")
            case "video": return m.hasPrefix("video/")
            case "image", "depth": return m.hasPrefix("image/")
            case "model": return m == "model/gltf-binary" || m == "application/octet-stream"
            case "stereo": return true
            default: return false
            }
        default: return false
        }
    }

    /// One blob field → a `DropBlob`, or nil when rule 4 makes it absent. Both wire forms are read:
    /// `{"$type":"blob","ref":{"$link":cid},"mimeType","size"}` and the legacy `{"cid","mimeType"}`.
    static func dropBlob(_ v: JSONValue, field: String, kind: String) -> DropBlob? {
        guard let cap = dropCaps[field], let mime = v["mimeType"].string, !mime.isEmpty else { return nil }
        let cid: String?
        let size: Int?
        if v["$type"].string == "blob" {
            cid = v["ref"]["$link"].string
            size = v["size"].int
            // A current-form blob without a size says nothing true about itself; rule 4 reads the
            // declared size before any request, and a negative one is not a size.
            guard let size, size >= 0 else { return nil }
        } else {
            cid = v["cid"].string
            size = nil
        }
        guard isBlobCid(cid), let cid, dropAccepts(field: field, kind: kind, mime: mime) else { return nil }
        if let size, size > cap { return nil }
        return DropBlob(cid: cid, mimeType: mime, size: size, cap: cap)
    }

    // MARK: §12.12 rule 2 — is this a drop?

    /// getRecord's JSON for `ref` → the drop, or nil when rule 2 refuses it: the answer's `uri` must
    /// be exactly the ref (a record read out of another repo proves nothing — §12.3's check), its
    /// `$type` the drop collection, and `kind` and `createdAt` non-empty strings.
    static func dropRecord(_ response: JSONValue, ref: String) -> DropRecord? {
        guard let uri = response["uri"].string, uri == ref, let at = parseAtUri(ref), at.collection == dropCollection else { return nil }
        let value = response["value"]
        guard value["$type"].string == dropCollection,
              let kind = value["kind"].string, !kind.isEmpty,
              let created = value["createdAt"].string, !created.isEmpty else { return nil }
        var blobs: [String: DropBlob] = [:]
        for field in dropCaps.keys {
            let v = value[field]
            guard !v.isNull, let blob = dropBlob(v, field: field, kind: kind) else { continue }
            blobs[field] = blob
        }
        var aspect: Double?
        if let w = value["aspectRatio"]["width"].number, let h = value["aspectRatio"]["height"].number, w > 0, h > 0 {
            aspect = w / h
        }
        var disparity: Int?
        if let d = value["stereo"]["disparityAdjust"].int, (-200...200).contains(d) { disparity = d }
        return DropRecord(ref: ref, cid: response["cid"].string ?? "", kindName: kind, blobs: blobs,
                          aspect: aspect, durationMs: value["durationMs"].int.flatMap { $0 > 0 ? $0 : nil },
                          disparityAdjust: disparity)
    }

    // MARK: §12.12 rules 7 and 8 — what loads, and when

    /// Rule 7's table. `needs` must all be present or the drop is its link card (rule 8).
    static func dropNeeds(_ kind: DropKind) -> (needs: [String], onScreen: [String], onTap: [String]) {
        switch kind {
        case .audio, .video, .image: return (["media"], [], ["media"])
        case .stereo: return (["left", "right"], ["left", "right"], [])
        case .depth: return (["media", "depth"], ["media", "depth"], [])
        // `media` is a GLB and is never fetched (§12.10): no Apple framework reads glTF.
        case .model: return (["usdz"], [], ["usdz"])
        }
    }

    /// A parsed record → the plan. `thumb` is whether the post view carries an image the card can
    /// use as its poster (the external embed's thumb, else the first image's, else the video's);
    /// only when it does not is `preview` fetched from the PDS, on screen, ahead of anything else.
    static func dropPlan(_ record: DropRecord?, thumb: Bool) -> DropPlan {
        guard let record, let kind = record.kind else { return .link }
        let t = dropNeeds(kind)
        guard t.needs.allSatisfy({ record.blobs[$0] != nil }) else { return .link }
        var onScreen = t.onScreen
        if !thumb, record.blobs["preview"] != nil { onScreen.insert("preview", at: 0) }
        let shift: Double? = kind == .stereo ? Double(record.disparityAdjust ?? 0) / 1000 : nil
        return DropPlan(kind: kind, onScreen: onScreen, onTap: t.onTap, aspect: record.aspect, shift: shift)
    }

    /// The vector entry point: a drop ref and getRecord's JSON (or its error body) → the plan.
    static func dropPlan(ref: String, response: JSONValue, thumb: Bool) -> DropPlan {
        dropPlan(dropRecord(response, ref: ref), thumb: thumb)
    }

    /// `<pds>/xrpc/com.atproto.sync.getBlob?did=<did>&cid=<cid>` (rule 4), or nil for a CID that
    /// rule 4 would not have kept.
    static func blobURL(pds: URL, did: String, cid: String) -> URL? {
        guard isBlobCid(cid), let did = normaliseDid(did),
              var c = URLComponents(url: pds.appendingPathComponent("xrpc/com.atproto.sync.getBlob"), resolvingAgainstBaseURL: false)
        else { return nil }
        c.queryItems = [URLQueryItem(name: "did", value: did), URLQueryItem(name: "cid", value: cid)]
        return c.url
    }

    /// `<pds>/xrpc/com.atproto.repo.getRecord?repo=&collection=app.waveloop.social.drop&rkey=` (rule 2).
    static func dropRecordURL(pds: URL, ref: String) -> URL? {
        guard let at = parseAtUri(ref), at.collection == dropCollection,
              var c = URLComponents(url: pds.appendingPathComponent("xrpc/com.atproto.repo.getRecord"), resolvingAgainstBaseURL: false)
        else { return nil }
        c.queryItems = [URLQueryItem(name: "repo", value: at.did), URLQueryItem(name: "collection", value: dropCollection),
                        URLQueryItem(name: "rkey", value: at.rkey)]
        return c.url
    }

    // MARK: §12.12 rule 6 — checking a blob against its CID

    /// The SHA-256 digest a `bafkrei…` CID names: CIDv1 (0x01), raw codec (0x55), sha2-256 (0x12),
    /// 32 bytes (0x20), then the digest. nil for any other CID shape, which rule 6 leaves unchecked.
    static func sha256Digest(ofCid cid: String) -> Data? {
        guard isBlobCid(cid), let bytes = base32Decode(String(cid.dropFirst())),
              bytes.count == 36, bytes[0] == 0x01, bytes[1] == 0x55, bytes[2] == 0x12, bytes[3] == 0x20 else { return nil }
        return Data(bytes[4...])
    }

    /// RFC 4648 base32, lowercase, unpadded — multibase `b`.
    static func base32Decode(_ s: String) -> [UInt8]? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var lookup: [Character: UInt32] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt32(i) }
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for ch in s {
            guard let v = lookup[ch] else { return nil }
            buffer = (buffer << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    /// The inverse, for building fixtures that name real bytes.
    static func base32Encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for b in bytes {
            buffer = (buffer << 8) | UInt32(b)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return out
    }

    /// The `bafkrei…` CID of a SHA-256 digest — what atproto names every blob by.
    static func rawCid(sha256 digest: [UInt8]) -> String {
        "b" + base32Encode([0x01, 0x55, 0x12, 0x20] + digest)
    }
}

// MARK: - §12.12 rule 10 — stereo

/// WaveLoop's stereo numbers (`/drop/` social.js), so a pair looks the same there and here.
enum StereoMath {
    /// "the classic wigglegram beat": each eye shows for 110 ms.
    static let period: TimeInterval = 0.110
    /// One converge step, a fraction of the box width.
    static let step = 0.004
    /// The shift stays within ±0.2 of the width — the lexicon's ±200 thousandths.
    static let limit = 0.2

    enum Eye: Equatable { case left, right }

    /// Wiggle: `floor(t / 110 ms) mod 2` — left, then right.
    static func eye(at elapsed: TimeInterval) -> Eye {
        // A microsecond of slack: the schedule's entries sit exactly on multiples of 110 ms, and
        // `3 × 0.11 / 0.11` is 2.9999… in binary floating point — the flip would land one frame late.
        let n = Int((max(elapsed, 0) / period + 1e-6).rounded(.down))
        return n % 2 == 0 ? .left : .right
    }

    /// `◂` pulls the eyes apart (−), `▸` together (+); clamped to ±0.2.
    static func converge(_ shift: Double, steps: Int) -> Double {
        min(max(shift + Double(steps) * step, -limit), limit)
    }

    /// Each eye's horizontal offset in points: the left by `+shift/2`, the right by `−shift/2`.
    static func offset(_ eye: Eye, shift: Double, width: CGFloat) -> CGFloat {
        let half = CGFloat(shift / 2) * width
        return eye == .left ? half : -half
    }
}

// MARK: - §12.12 rule 10 — depth

/// The depth parallax, the WebGL shader's maths and constants (`/drop/` social.js). The same
/// formula runs on the GPU in `DropDepth.metal`; `sample` here is the CPU reference the tests
/// render with, so "a drag changes the picture" is measured on pixels and not only on state.
struct DepthParallax: Equatable {
    static let defaultAmp = 0.04
    static let ampRange = 0.005...0.12
    static let ampFactor = 1.3
    /// Eased toward the target by 0.08 per 1/60 s.
    static let ease = 0.08
    /// Input idle this long, and the target becomes the sway.
    static let idle: TimeInterval = 1.8
    /// ±18° of tilt maps to ±1 (the viewer's tilt mapping).
    static let tiltDegrees = 18.0

    var amp = DepthParallax.defaultAmp
    /// The eased position, −1…1 on each axis.
    var cx = 0.0
    var cy = 0.0

    /// `Depth +` / `Depth −`: ×1.3 or ÷1.3, within 0.005…0.12.
    mutating func stepAmp(up: Bool) {
        let next = up ? amp * Self.ampFactor : amp / Self.ampFactor
        amp = min(max(next, Self.ampRange.lowerBound), Self.ampRange.upperBound)
    }

    /// `zoom = 1 − 1.2 × amp`, which hides the edge smear.
    var zoom: Double { 1 - 1.2 * amp }
    /// `shift = (cx × amp, cy × amp × 0.6)`, in uv units.
    var shift: (x: Double, y: Double) { (cx * amp, cy * amp * 0.6) }

    /// One frame toward `target`. `k = 1 − 0.92^(Δt × 60)`: a 120 Hz display eases at the viewer's
    /// 60 Hz rate, and a dropped frame catches up instead of slowing the motion down.
    mutating func ease(toward target: (x: Double, y: Double), dt: TimeInterval) {
        let clamped = min(max(dt, 0), 0.25)
        let k = 1 - pow(1 - Self.ease, clamped * 60)
        cx += (target.x - cx) * k
        cy += (target.y - cy) * k
    }

    /// The idle sway: a Lissajous path, `t` in seconds.
    static func sway(_ t: TimeInterval) -> (x: Double, y: Double) {
        (0.7 * sin(0.9 * t), 0.35 * sin(1.3 * t + 1.2))
    }

    /// A tilt in degrees → the target axis, clamped to −1…1.
    static func tilt(_ degrees: Double) -> Double {
        min(max(degrees / tiltDegrees, -1), 1)
    }

    /// The shader, on the CPU: the colour at pixel position `v` (0…1, y down).
    /// `uv = (v − 0.5) × zoom + 0.5`, `d = depth(uv) − 0.5`, `colour = image(clamp(uv + shift × d))`.
    static func sample(v: (x: Double, y: Double), shift: (x: Double, y: Double), zoom: Double,
                       depth: (Double, Double) -> Double) -> (x: Double, y: Double) {
        let u = ((v.x - 0.5) * zoom + 0.5, (v.y - 0.5) * zoom + 0.5)
        let d = depth(u.0, u.1) - 0.5
        return (min(max(u.0 + shift.x * d, 0.002), 0.998), min(max(u.1 + shift.y * d, 0.002), 0.998))
    }
}

// MARK: - Labels (PRODUCT §2.36.1, §3's word list)

enum DropCopy {
    static let stereoPill = "3D \u{00B7} Stereo"
    static let depthPill = "3D \u{00B7} Depth"
    static let modelPill = "3D \u{00B7} Model"
    static let wiggle = "Wiggle"
    static let anaglyph = "Anaglyph"
    static let sideBySide = "Side by Side"
    static let swap = "Swap"
    static let sway = "Sway"
    static let depthLess = "Depth \u{2212}"
    static let depthMore = "Depth +"
    static let spin = "Spin"
    static let ar = "AR"
    static let apart = "Eyes apart"
    static let together = "Eyes together"
    static let failed = "Couldn't load this drop."
    static let save = "Save"
}
