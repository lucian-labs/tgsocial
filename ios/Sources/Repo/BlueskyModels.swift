// Repo — a Bluesky post as the feed holds it (PROTOCOL.md §12.5, PRODUCT.md §2.36).
//
// A Bluesky post rides the same `Post` value every list already renders, with `bluesky` set. That is
// §2.36's "marked by source, not a different card": the merge, the window, the cache, the safety
// filter and every list keep working on one type, and the few places that differ (header, footer,
// sheet, share link) ask `post.bluesky`. Built from an ADMITTED item only — `Atproto.item` has
// already left out reposts, replies, labels and dateless posts.

import Foundation

struct BlueskyImage: Codable, Equatable, Hashable {
    var thumb: String
    var fullsize: String
    var alt: String
    var width: Int?
    var height: Int?
}

struct BlueskyExternal: Codable, Equatable, Hashable {
    var uri: String
    var title: String
    var description: String
    var thumb: String?
    var domain: String { URL(string: uri)?.host ?? uri }
}

struct BlueskyPost: Codable, Equatable, Hashable {
    var uri: String
    var cid: String
    var authorDid: String
    /// The AppView has checked it in both directions; `handle.invalid` renders as the DID (§12.4).
    var handle: String
    var displayName: String?
    var avatar: String?
    var text: RichText
    var images: [BlueskyImage] = []
    var external: BlueskyExternal?
    /// A video's still (§2.36: `Plays on Bluesky`, on all three builds).
    var videoThumb: String?
    var hasVideo = false
    /// §2.36 Quote: its media above, then `Quoting @handle`.
    var quoteUri: String?
    var quoteHandle: String?
    var likeCount: Int
    var replyCount: Int
    /// §12.6: the WaveLoop drop this post announces, when it is one by its poster.
    var dropRef: String?

    /// `@handle`, or the DID when the handle did not verify.
    var handleLabel: String { handle == "handle.invalid" || handle.isEmpty ? authorDid : "@" + handle }
    var name: String { (displayName?.isEmpty == false ? displayName : nil) ?? handleLabel }
    /// Share and `Open on Bluesky`: the DID form, which still opens after a handle change (§2.36).
    var webURL: String { Atproto.bskyPostUrl(uri) ?? Atproto.bskyProfileUrl(authorDid) }
    var profileURL: String { Atproto.bskyProfileUrl(authorDid) }
    var rkey: String { Atproto.parseAtUri(uri)?.rkey ?? "" }
}

enum BlueskyMapping {
    /// An admitted item → the feed's `Post`. `sourceKey` is the atproto source it arrived through
    /// (`at:<did>`, `bsky:following`, `tag:waveloop`) — used by the merge only; attribution is the
    /// author DID's, never the source's (§12.5 rule 4), and is stamped later.
    static func post(_ item: Atproto.Item, sourceKey: String) -> Post {
        let p = item.post
        let author = p["author"]
        let bluesky = BlueskyPost(
            uri: item.id,
            cid: p["cid"].string ?? "",
            authorDid: item.did,
            handle: author["handle"].string ?? "",
            displayName: author["displayName"].string,
            avatar: author["avatar"].string,
            text: richText(p["record"]),
            likeCount: p["likeCount"].int ?? 0,
            replyCount: p["replyCount"].int ?? 0,
            dropRef: Atproto.dropRef(p))
        var b = bluesky
        embed(p["embed"], into: &b)
        return Post(messageId: item.tie, chatId: 0, sourceKey: sourceKey, sourceUsername: "", sourceTitle: "Bluesky",
                    sourcePhoto: nil, date: item.date, text: b.text, media: [], albumId: 0, albumMessageIds: [],
                    views: 0, reactions: [], forwardedFrom: nil, forwardedChatId: nil, forwardedUserId: nil,
                    bluesky: b)
    }

    /// The hydrated embed VIEW (`post.embed`), which carries CDN URLs; the record's embed carries
    /// only blob refs. §2.36's table, v1: images, link card, video still, quote row.
    static func embed(_ e: JSONValue, into b: inout BlueskyPost) {
        switch e["$type"].string {
        case "app.bsky.embed.images#view":
            b.images = (e["images"].array ?? []).compactMap(image)
        case "app.bsky.embed.external#view":
            b.external = external(e["external"])
        case "app.bsky.embed.video#view":
            b.hasVideo = true
            b.videoThumb = e["thumbnail"].string
        case "app.bsky.embed.record#view":
            quote(e["record"], into: &b)
        case "app.bsky.embed.recordWithMedia#view":
            embed(e["media"], into: &b)
            quote(e["record"]["record"], into: &b)
        default:
            break
        }
    }

    private static func image(_ v: JSONValue) -> BlueskyImage? {
        guard let thumb = v["thumb"].string, let full = v["fullsize"].string else { return nil }
        return BlueskyImage(thumb: thumb, fullsize: full, alt: v["alt"].string ?? "",
                            width: v["aspectRatio"]["width"].int, height: v["aspectRatio"]["height"].int)
    }

    private static func external(_ v: JSONValue) -> BlueskyExternal? {
        guard let uri = v["uri"].string else { return nil }
        return BlueskyExternal(uri: uri, title: v["title"].string ?? "", description: v["description"].string ?? "",
                               thumb: v["thumb"].string)
    }

    private static func quote(_ r: JSONValue, into b: inout BlueskyPost) {
        guard r["$type"].string == "app.bsky.embed.record#viewRecord", let uri = r["uri"].string else { return }
        b.quoteUri = uri
        b.quoteHandle = r["author"]["handle"].string
    }

    /// §2.36 Rich text: link facets are links, mention facets are `@handle` linking to that profile
    /// on Bluesky, tag facets are plain text. Facet indexes are UTF-8 BYTE offsets; one that does
    /// not land on a character boundary, overlaps another, or runs past the end is ignored — the text
    /// renders plain rather than cut mid-character.
    static func richText(_ record: JSONValue) -> RichText {
        let text = record["text"].string ?? ""
        let bytes = Array(text.utf8)
        func boundary(_ i: Int) -> Bool { i == bytes.count || (i >= 0 && i < bytes.count && bytes[i] & 0xC0 != 0x80) }
        struct F { let start: Int; let end: Int; let kind: RichSpan.Kind; let url: String? }
        var facets: [F] = []
        for f in record["facets"].array ?? [] {
            guard let s = f["index"]["byteStart"].int, let e = f["index"]["byteEnd"].int,
                  s >= 0, e > s, e <= bytes.count, boundary(s), boundary(e) else { continue }
            for feature in f["features"].array ?? [] {
                switch feature["$type"].string {
                case "app.bsky.richtext.facet#link":
                    if let uri = feature["uri"].string { facets.append(F(start: s, end: e, kind: .link, url: uri)) }
                case "app.bsky.richtext.facet#mention":
                    if let did = Atproto.normaliseDid(feature["did"].string) {
                        facets.append(F(start: s, end: e, kind: .mention, url: Atproto.bskyProfileUrl(did)))
                    }
                default: continue
                }
                break
            }
        }
        facets.sort { $0.start < $1.start }
        var spans: [RichSpan] = []
        var cursor = 0
        func slice(_ a: Int, _ b: Int) -> String { String(decoding: bytes[a..<b], as: UTF8.self) }
        for f in facets where f.start >= cursor {
            if f.start > cursor { spans.append(RichSpan(text: slice(cursor, f.start), kind: .plain)) }
            spans.append(RichSpan(text: slice(f.start, f.end), kind: f.kind, url: f.url))
            cursor = f.end
        }
        if cursor < bytes.count { spans.append(RichSpan(text: slice(cursor, bytes.count), kind: .plain)) }
        return RichText(spans: spans)
    }
}

// MARK: - Writing (PROTOCOL §12.8)

enum BlueskyText {
    /// Bluesky counts graphemes, and so does the compose counter (§2.38). Swift's `Character` is
    /// an extended grapheme cluster, which is what Bluesky means.
    static let maxGraphemes = 300
    static let maxBytes = 3000

    static func graphemes(_ text: String) -> Int { text.count }
    static func fits(_ text: String) -> Bool { text.count <= maxGraphemes && text.utf8.count <= maxBytes }

    /// §12.8: `#link` for URLs and `#tag` for hashtags, in UTF-8 byte offsets. Telegram
    /// `@usernames` stay plain text — they name Telegram channels, and a mention facet would point at
    /// whichever Bluesky account had that name, or at nobody.
    static func facets(_ text: String) -> [JSONValue] {
        var out: [JSONValue] = []
        let chars = Array(text)
        var offsets: [Int] = [0]
        for ch in chars { offsets.append(offsets.last! + String(ch).utf8.count) }
        func facet(_ a: Int, _ b: Int, _ feature: JSONValue) -> JSONValue {
            .object(["index": .object(["byteStart": .number(Double(offsets[a])), "byteEnd": .number(Double(offsets[b]))]),
                     "features": .array([feature])])
        }
        var i = 0
        while i < chars.count {
            let atStart = i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == "("
            let rest = String(chars[i...].prefix(8)).lowercased()
            if atStart, rest.hasPrefix("https://") || rest.hasPrefix("http://") {
                var j = i
                while j < chars.count, !chars[j].isWhitespace { j += 1 }
                // Trailing punctuation belongs to the sentence, not the URL.
                while j > i, ".,;:!?)\"'".contains(chars[j - 1]) { j -= 1 }
                let uri = String(chars[i..<j])
                if URL(string: uri)?.host != nil { out.append(facet(i, j, .object(["$type": .string("app.bsky.richtext.facet#link"), "uri": .string(uri)]))) }
                i = max(j, i + 1)
                continue
            }
            if atStart, chars[i] == "#" || chars[i] == "\u{FF03}" {
                var j = i + 1
                while j < chars.count, !chars[j].isWhitespace, chars[j] != "#" { j += 1 }
                while j > i + 1, ".,;:!?)\"'".contains(chars[j - 1]) { j -= 1 }
                let tag = String(chars[(i + 1)..<j])
                if !tag.isEmpty, tag.count <= 64, !tag.allSatisfy(\.isNumber) {
                    out.append(facet(i, j, .object(["$type": .string("app.bsky.richtext.facet#tag"), "tag": .string(tag)])))
                }
                i = max(j, i + 1)
                continue
            }
            i += 1
        }
        return out
    }

    /// The §12.8 record: the same text, facets, and an external embed pointing at the Telegram
    /// original — the link back, and the marker §12.5 rule 7 reads to hide the copy.
    static func postRecord(text: String, telegramLink: String, feedTitle: String, thumb: JSONValue?, now: Date = Date()) -> JSONValue {
        var external: [String: JSONValue] = ["uri": .string(telegramLink), "title": .string(feedTitle), "description": .string("")]
        if let thumb { external["thumb"] = thumb }
        var record: [String: JSONValue] = [
            "$type": .string(Atproto.postCollection),
            "text": .string(text),
            "createdAt": .string(iso(now)),
            "embed": .object(["$type": .string("app.bsky.embed.external"), "external": .object(external)]),
        ]
        let f = facets(text)
        if !f.isEmpty { record["facets"] = .array(f) }
        return .object(record)
    }

    /// PRODUCT §2.9, Bluesky only: the counter's line past 300. The app never cuts the sentence.
    static let tooLong = "Too long for Bluesky."

    /// The one photo a direct post carries (§12.8): the uploaded blob and its pixel size.
    struct PostImage: Equatable {
        var blob: JSONValue
        var width: Int
        var height: Int
    }

    /// PROTOCOL §12.8's direct post: text, facets, and `app.bsky.embed.images` with one image when
    /// a photo is attached — `alt` the empty string (the lexicon requires the field; v1 has no alt
    /// text to fill it from), `aspectRatio` from its pixel size. No external embed: there is no
    /// Telegram original to link back to, so §12.5 rule 7 never mistakes it for a cross-post.
    static func directRecord(text: String, image: PostImage?, now: Date = Date()) -> JSONValue {
        var record: [String: JSONValue] = [
            "$type": .string(Atproto.postCollection),
            "text": .string(text),
            "createdAt": .string(iso(now)),
        ]
        let f = facets(text)
        if !f.isEmpty { record["facets"] = .array(f) }
        if let image {
            var one: [String: JSONValue] = ["image": image.blob, "alt": .string("")]
            if image.width > 0, image.height > 0 {
                one["aspectRatio"] = .object(["width": .number(Double(image.width)), "height": .number(Double(image.height))])
            }
            record["embed"] = .object(["$type": .string("app.bsky.embed.images"), "images": .array([.object(one)])])
        }
        return .object(record)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
