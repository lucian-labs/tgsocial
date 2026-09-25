// Protocol — the atproto extension (PROTOCOL.md §12). Parse, serialise, verify, admit. Pure Swift.
//
// §12 is built the way §10 and §11 were, and this file has their shape for their reason: `Card.swift`
// is §2 and knows nothing about anything here. Delete this file and every card on the network still
// parses byte-identically — a card carrying `atproto.did` is a §2 card with one unknown key (the
// `parse` vector naming §12 is that sentence as a test). §12 is read by a SECOND pass over the same
// text, and meets §2 in exactly one place, the `CardCodec.serialise(_:work:privateId:private:atprotoDid:)`
// overload at the bottom (§12.2, which applies §10.6 word for word).
//
// Everything else here is the part two clients must agree on to show the same thing: the link
// check (§12.3), the merge date, tiebreak and admission rules (§12.5), the tag source's owner check
// (§12.6), the safety keys (§12.9) and the client-metadata checklist (§12.7). Each function is a
// port of the one of the same name in `web/js/protocol.js`, and `AtprotoVectorTests` runs every
// `atproto` vector in `docs/card-vectors.json` against it. Nothing here does I/O.

import Foundation

public enum Atproto {
    /// §12.3 — the collection a person's atproto repo uses to name their node back.
    public static let linkCollection = "ca.lucianlabs.tgsocial.link"
    public static let postCollection = "app.bsky.feed.post"
    /// §12.6 — WaveLoop's drop record, read exactly as WaveLoop writes it.
    public static let dropCollection = "app.waveloop.social.drop"
    /// §12.6 — the tag WaveLoop announces drops under. It was `#waveloopsocial` for about an hour on
    /// 2026-09-07; WaveLoop's spec file kept the old name, the tag did not.
    public static let tag = "waveloop"
    /// §12.2 — the one card key.
    public static let cardKey = "atproto.did"

    // MARK: §12.2 DIDs

    private static let plcAlphabet = Set("abcdefghijklmnopqrstuvwxyz234567")

    /// §12.2 — the two DID methods atproto blesses, canonical form, or nil.
    ///
    /// `did:plc` is compared exactly: its identifier is lowercase base32 by construction, so an
    /// uppercase one is not the same DID written differently, it is not a DID. `did:web` names a
    /// hostname, which DNS compares case-insensitively, so the host is lowercased. Hostname-level
    /// `did:web` only — a port (`%3A`) or a path (a further `:`) is refused rather than resolved
    /// wrongly (WaveLoop's `pdsFor` mis-resolves the path form), and so is a single-label host.
    public static func normaliseDid(_ input: String?) -> String? {
        guard let input else { return nil }
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("did:plc:") {
            let id = s.dropFirst("did:plc:".count)
            guard id.count == 24, id.allSatisfy({ plcAlphabet.contains($0) }) else { return nil }
            return s
        }
        guard s.hasPrefix("did:web:") else { return nil }
        let host = s.dropFirst("did:web:".count).lowercased()
        guard host.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }),
                  label.first != "-", label.last != "-" else { return nil }
        }
        return "did:web:" + host
    }

    /// §12.2 — the one §12 key, read off a PUBLIC card. First token only: the key is "one", a
    /// repeated line concatenates by §2 and the first claim stands. Malformed → nil, never fatal.
    public static func did(fromCard text: String) -> String? {
        guard CardCodec.parse(text).card != nil else { return nil }
        let value = PrivateCodec.raw(text, keys: [cardKey])[cardKey] ?? ""
        let first = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return normaliseDid(first)
    }

    /// The §12 line, after every §2, §10 and §11 line. Never on a private card (§12.9): a private
    /// card names a public node and nothing else, and a DID on it would attach a public account to
    /// a channel whose point is that it is not.
    public static func lines(did: String?, isPrivateCard: Bool) -> [String] {
        guard !isPrivateCard, let did = normaliseDid(did) else { return [] }
        return ["\(cardKey): \(did)"]
    }

    // MARK: at-uris

    public struct AtUri: Equatable {
        public let did: String
        public let collection: String
        public let rkey: String
        public var string: String { "at://\(did)/\(collection)/\(rkey)" }
    }

    private static let nsidChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
    private static let rkeyChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:~-")

    /// `at://<did>/<collection>/<rkey>` → parts, when the authority is a DID by §12.2's grammar.
    public static func parseAtUri(_ uri: String?) -> AtUri? {
        guard let uri else { return nil }
        let s = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("at://") else { return nil }
        let parts = s.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty,
              !parts[1].isEmpty, parts[1].allSatisfy({ nsidChars.contains($0) }),
              (1...512).contains(parts[2].count), parts[2].allSatisfy({ rkeyChars.contains($0) }),
              let did = normaliseDid(String(parts[0])) else { return nil }
        return AtUri(did: did, collection: String(parts[1]), rkey: String(parts[2]))
    }

    // MARK: §12.3 the link

    /// The record key is the node's username, lowercased, so "does this DID name this node?" is one
    /// keyed getRecord and never a listing. Usernames are `[A-Za-z0-9_]`, inside the rkey grammar.
    public static func linkRecordKey(_ node: String?) -> String? {
        guard let node, let u = Username.normalise(node) else { return nil }
        return Username.key(u)
    }

    /// §12.8 — the record a client writes into the person's own repo.
    public static func linkRecord(node: String, createdAt: String) -> JSONValue? {
        guard let key = linkRecordKey(node) else { return nil }
        return .object(["$type": .string(linkCollection), "node": .string(key), "createdAt": .string(createdAt)])
    }

    /// §12.3 — is `did` this node's atproto account? Both halves or nothing.
    ///
    /// The card half: only the node's owner can write the card, and it must name exactly this DID.
    /// The atproto half: only the DID's owner can write into its repo, and the record at
    /// `<did>/ca.lucianlabs.tgsocial.link/<node>` must name this node. `record` is getRecord's
    /// `{ uri, value }`, or nil for RecordNotFound. The uri is checked too, so a record read out of
    /// some other repo — a PDS answering for the wrong DID — proves nothing.
    public static func linkVerified(cardText: String, node: String, did: String?, record: JSONValue?) -> Bool {
        guard let claimed = Atproto.did(fromCard: cardText), let asked = normaliseDid(did), claimed == asked,
              let key = linkRecordKey(node) else { return false }
        return recordNamesNode(record, did: claimed, key: key)
    }

    /// The atproto half alone, for a caller that already holds the card's DID.
    public static func recordNamesNode(_ record: JSONValue?, did: String, key: String) -> Bool {
        guard let record, record["uri"].string == "at://\(did)/\(linkCollection)/\(key)" else { return false }
        let value = record["value"]
        guard value["$type"].string == linkCollection else { return false }
        return linkRecordKey(value["node"].string) == key
    }

    // MARK: §12.5 dates

    /// An atproto datetime — RFC 3339 WITH a timezone — in milliseconds; nil otherwise. A zoneless
    /// one is not a datetime: read in the device's zone, it would move with the reader.
    /// JavaScript's `Date.parse` is the reference, so extra fraction digits truncate to the ms.
    public static func datetimeMs(_ s: String?) -> Int64? {
        guard let s else { return nil }
        let c = Array(s.utf8)
        func digits(_ from: Int, _ n: Int) -> Int? {
            guard from + n <= c.count else { return nil }
            var v = 0
            for i in from..<(from + n) {
                guard c[i] >= 48, c[i] <= 57 else { return nil }
                v = v * 10 + Int(c[i] - 48)
            }
            return v
        }
        guard c.count >= 20, c[4] == 45, c[7] == 45, c[10] == 84, c[13] == 58, c[16] == 58,
              let y = digits(0, 4), let mo = digits(5, 2), let d = digits(8, 2),
              let h = digits(11, 2), let mi = digits(14, 2), let sec = digits(17, 2) else { return nil }
        var i = 19
        var ms = 0
        if i < c.count, c[i] == 46 {
            i += 1
            let start = i
            while i < c.count, c[i] >= 48, c[i] <= 57 { i += 1 }
            guard i > start else { return nil }
            var frac = 0
            for k in 0..<3 { frac = frac * 10 + (start + k < i ? Int(c[start + k] - 48) : 0) }
            ms = frac
        }
        guard i < c.count else { return nil }
        var offsetMinutes = 0
        if c[i] == 90 {
            guard i + 1 == c.count else { return nil }
        } else if c[i] == 43 || c[i] == 45 {
            guard i + 6 == c.count, c[i + 3] == 58, let oh = digits(i + 1, 2), let om = digits(i + 4, 2),
                  oh <= 23, om <= 59 else { return nil }
            offsetMinutes = (oh * 60 + om) * (c[i] == 45 ? -1 : 1)
        } else {
            return nil
        }
        guard (1...12).contains(mo), d >= 1, d <= WorkCodec.daysIn(month: mo, year: y),
              h <= 23, mi <= 59, sec <= 59 else { return nil }
        let days = Int64(daysFromCivil(y, mo, d))
        let seconds = days * 86_400 + Int64(h * 3600 + mi * 60 + sec) - Int64(offsetMinutes * 60)
        return seconds * 1000 + Int64(ms)
    }

    /// Howard Hinnant's days-from-civil: proleptic Gregorian date → days since 1970-01-01.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func floorSeconds(_ ms: Int64) -> Int {
        Int(ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000))
    }

    /// §12.5 rule 1 — a post's merge date, in seconds: the EARLIER of the author's `createdAt` and
    /// the AppView's `indexedAt`. That is the key the AppView sorts an author feed by, so a source's
    /// pages stay newest-first in it; and it is why a post its author dated 2099 cannot sit above
    /// every Telegram post forever — `indexedAt` is the AppView's clock. No `indexedAt`, no date.
    public static func sortAt(_ post: JSONValue) -> Int? {
        guard let indexed = datetimeMs(post["indexedAt"].string) else { return nil }
        let created = datetimeMs(post["record"]["createdAt"].string)
        return floorSeconds(created.map { min($0, indexed) } ?? indexed)
    }

    /// §12.5 rule 2 — the time an entry holds its PAGE position by: a repost at the repost's time,
    /// everything else at its sortAt. Reposts are dropped, but the merge still has to know where
    /// they were, or a page of nothing but reposts would say nothing about how far down it read.
    public static func feedTime(_ entry: JSONValue) -> Int? {
        if let reason = datetimeMs(entry["reason"]["indexedAt"].string) { return floorSeconds(reason) }
        return sortAt(entry["post"].isNull ? entry : entry["post"])
    }

    private static let tidAlphabet = Array("234567abcdefghijklmnopqrstuvwxyz")
    private static let tidFirst = Set("234567abcdefghij")

    /// A TID record key → its microsecond timestamp, the merge's within-a-second tiebreak (§12.5);
    /// 0 when the key is not a TID.
    public static func tidMicros(_ rkey: String?) -> Int64 {
        guard let rkey, rkey.count == 13, let first = rkey.first, tidFirst.contains(first) else { return 0 }
        var n: UInt64 = 0
        for ch in rkey {
            guard let i = tidAlphabet.firstIndex(of: ch) else { return 0 }
            n = n &* 32 &+ UInt64(i)
        }
        return Int64(n >> 10)
    }

    // MARK: §12.5 admission

    /// §12.9 — label values that drop a post at admission, with no switch (PRODUCT §2.18), whoever
    /// applied them, the author's own self-label included.
    public static let hideLabels: Set<String> = ["!hide", "!takedown", "porn", "sexual", "nudity", "graphic-media", "gore"]

    /// True when the post or its author carries a live hiding label. A `neg` label from the same
    /// source for the same value cancels it.
    public static func labelsHide(_ post: JSONValue) -> Bool {
        var live: [String: String] = [:]
        for l in (post["author"]["labels"].array ?? []) + (post["labels"].array ?? []) {
            guard let val = l["val"].string else { continue }
            let k = "\(l["src"].string ?? "")|\(val)"
            if l["neg"].bool == true {
                live.removeValue(forKey: k)
            } else {
                live[k] = val
            }
        }
        return live.values.contains { hideLabels.contains($0) }
    }

    /// One post admitted to the merge.
    public struct Item: Equatable {
        /// The post's at-uri — the merge-wide dedupe key (§12.5 rule 4).
        public let id: String
        /// sortAt, seconds.
        public let date: Int
        /// The rkey's TID microseconds; 0 when not a TID.
        public let tie: Int64
        /// The author, from the uri — attribution runs on this and never on the source (rule 4).
        public let did: String
        public let post: JSONValue
    }

    /// §12.5 rule 5 — a FeedViewPost (getAuthorFeed, getTimeline) or a bare PostView (searchPosts)
    /// → a merge item, or nil when §12.5 leaves it out: reposts and pins (any `reason`), replies,
    /// a hiding label, a date that will not parse, anything that is not an `app.bsky.feed.post`.
    public static func item(_ entry: JSONValue) -> Item? {
        let post = entry["post"].isNull ? entry : entry["post"]
        guard let uri = post["uri"].string, let at = parseAtUri(uri), at.collection == postCollection else { return nil }
        if entry["reason"].isTruthy { return nil }
        if post["record"]["reply"].isTruthy { return nil }
        if labelsHide(post) { return nil }
        guard let date = sortAt(post) else { return nil }
        return Item(id: uri, date: date, tie: tidMicros(at.rkey), did: at.did, post: post)
    }

    /// §12.6 — the tag source's admission: §12.5's rule, and it must be a drop by its poster.
    public static func tagItem(_ entry: JSONValue) -> Item? {
        guard let item = item(entry), dropRef(item.post) != nil else { return nil }
        return item
    }

    /// §12.5 — source keys. `:` never occurs in a username or a `c/<id>` key, so no namespace can
    /// collide with Telegram's.
    public enum SourceKind: Equatable { case author(did: String), following, tag(String) }

    public static func sourceKey(_ kind: SourceKind) -> String {
        switch kind {
        case .author(let did): return "at:" + (normaliseDid(did) ?? "")
        case .following: return "bsky:following"
        case .tag(let t): return "tag:" + t.lowercased()
        }
    }

    public static func isAtprotoSourceKey(_ key: String) -> Bool { key.contains(":") }

    // MARK: §12.5 rule 7 cross-posts

    /// The web reference's `targetKey`: a t.me post link → `<channel lowercased>/<id>`.
    public static func telegramPostKey(_ link: String?) -> String? {
        guard var s = link?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("https://") { s = String(s.dropFirst(8)) } else if lower.hasPrefix("http://") { s = String(s.dropFirst(7)) } else { return nil }
        if s.lowercased().hasPrefix("www.") { s = String(s.dropFirst(4)) }
        guard s.lowercased().hasPrefix("t.me/") else { return nil }
        s = String(s.dropFirst(5))
        if s.hasSuffix("/") { s.removeLast() }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return parts[0].lowercased() + "/" + parts[1]
    }

    /// An atproto post whose external embed is the t.me link of a post in one of the linked
    /// node's own feeds is the §12.8 copy of a post the reader already has. `nodeFeeds` is the
    /// `feeds:` of the node the author is VERIFIED to; an unlinked author passes [] and nothing of
    /// theirs is suppressed.
    public static func crossPostTarget(_ post: JSONValue, nodeFeeds: [String]) -> String? {
        let embed = post["record"]["embed"]
        guard embed["$type"].string == "app.bsky.embed.external",
              let key = telegramPostKey(embed["external"]["uri"].string) else { return nil }
        let channel = String(key.split(separator: "/").first ?? "")
        let listed = nodeFeeds.contains { Username.key($0.hasPrefix("@") ? String($0.dropFirst()) : $0) == channel }
        return listed ? key : nil
    }

    // MARK: §12.6 the tag source

    /// WaveLoop's drop link, either form it writes: `?at=<at-uri>` or `?d=<did>&r=<rkey>`. A `d=`
    /// that is a handle is not resolved: attribution runs on DIDs, and a handle is a claim until it is.
    public static func waveloopDropRef(_ url: String?) -> String? {
        guard let url, let u = URLComponents(string: url), let host = u.host?.lowercased(),
              host == "waveloop.app" || host.hasSuffix(".waveloop.app"),
              u.path.hasPrefix("/drop") else { return nil }
        let q = u.queryItems ?? []
        func param(_ name: String) -> String? { q.first(where: { $0.name == name })?.value }
        if let at = param("at"), !at.isEmpty {
            guard let p = parseAtUri(at), p.collection == dropCollection else { return nil }
            return p.string
        }
        guard let d = normaliseDid(param("d") ?? ""), let r = param("r"), (1...512).contains(r.count),
              r.allSatisfy({ rkeyChars.contains($0) }) else { return nil }
        return "at://\(d)/\(dropCollection)/\(r)"
    }

    /// The drop an announcement post points at, found the way WaveLoop's own reader finds it —
    /// external embed, then link facets, then URLs in the text; first hit wins — and kept only when
    /// the drop lives in the POSTER's repo. Anyone can type #waveloop and paste someone else's drop
    /// link; the owner check is what makes a tag hit a drop by the person shown on it.
    public static func dropRef(_ post: JSONValue) -> String? {
        let rec = post["record"]
        let author = parseAtUri(post["uri"].string)?.did ?? normaliseDid(post["author"]["did"].string)
        var cands: [String] = []
        let emb = rec["embed"]
        let ext = emb["external"].isNull ? emb["media"]["external"] : emb["external"]
        if let uri = ext["uri"].string, !uri.isEmpty { cands.append(uri) }
        for f in rec["facets"].array ?? [] {
            for ft in f["features"].array ?? [] { if let uri = ft["uri"].string, !uri.isEmpty { cands.append(uri) } }
        }
        cands += urls(in: rec["text"].string ?? "")
        for c in cands {
            guard let ref = waveloopDropRef(c) else { continue }
            return author != nil && parseAtUri(ref)?.did == author ? ref : nil
        }
        return nil
    }

    /// `https?://[^\s)]+` — the reference's URL scan over post text.
    static func urls(in text: String) -> [String] {
        var out: [String] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            var matched = 0
            for prefix in ["https://", "http://"] {
                let p = Array(prefix.unicodeScalars)
                if i + p.count <= scalars.count, Array(scalars[i..<(i + p.count)]) == p { matched = p.count; break }
            }
            guard matched > 0 else { i += 1; continue }
            var j = i + matched
            while j < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[j]), scalars[j] != ")" { j += 1 }
            if j > i + matched {
                var s = String.UnicodeScalarView(); s.append(contentsOf: scalars[i..<j])
                out.append(String(s))
            }
            i = max(j, i + 1)
        }
        return out
    }

    // MARK: §12.9 safety keys and links

    /// The hidden-list key for a Bluesky post: its at-uri. Accepts the at-uri or the bsky.app URL
    /// in DID form. A post's record key is a TID by its lexicon, lowercase by construction, so
    /// §7.1's lowercasing of hidden keys loses nothing; a non-TID key is not a post this renders.
    public static func postKey(_ link: String?) -> String? {
        let s = (link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var did: String?
        var rkey: String?
        if let at = parseAtUri(s), at.collection == postCollection { did = at.did; rkey = at.rkey }
        let prefix = "https://bsky.app/profile/"
        if s.hasPrefix(prefix) {
            var rest = String(s.dropFirst(prefix.count))
            if rest.hasSuffix("/") { rest.removeLast() }
            let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 3, parts[1] == "post", !parts[0].isEmpty, !parts[2].isEmpty,
               !parts[2].contains(where: { $0 == "?" || $0 == "#" }) {
                did = normaliseDid(String(parts[0])); rkey = String(parts[2])
            }
        }
        guard let did, let rkey, rkey.count == 13, rkey.first.map({ tidFirst.contains($0) }) == true,
              rkey.allSatisfy({ tidAlphabet.contains($0) }) else { return nil }
        return "at://\(did)/\(postCollection)/\(rkey)"
    }

    /// One lookup for every kind of thing a reader can hide: a t.me post or comment, or a Bluesky post.
    public static func safetyKey(_ link: String?) -> String? { telegramPostKey(link) ?? postKey(link) }

    /// Share and `Open on Bluesky`: the DID form, which survives a handle change.
    public static func bskyPostUrl(_ uri: String?) -> String? {
        guard let at = parseAtUri(uri), at.collection == postCollection else { return nil }
        return "https://bsky.app/profile/\(at.did)/post/\(at.rkey)"
    }

    public static func bskyProfileUrl(_ did: String) -> String { "https://bsky.app/profile/\(did)" }

    // MARK: §12.7 client metadata

    /// The custom scheme a native client may redirect to: the client_id host, labels reversed.
    public static func nativeRedirectScheme(_ clientId: String?) -> String? {
        guard let clientId, let host = URLComponents(string: clientId)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.split(separator: ".").reversed().joined(separator: ".")
    }

    private static func origin(_ u: URLComponents) -> String {
        let scheme = u.scheme?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = u.port.flatMap { $0 == defaultPort ? nil : $0 }
        return "\(scheme)://\(u.host?.lowercased() ?? "")" + (port.map { ":\($0)" } ?? "")
    }

    /// §12.7 — what is wrong with a client-metadata document, as the reference's short codes; []
    /// is a document a client may publish. atproto's own rules plus two of this protocol's: a public
    /// client (no secret can ship in an app), and no `transition:generic` (deprecated, and it grants
    /// the whole account where §12 needs six narrow things). `fetchedFrom` is the URL the document
    /// was served at; client_id must equal it.
    public static func clientMetadataProblems(_ doc: JSONValue, fetchedFrom: String? = nil) -> [String] {
        var out: [String] = []
        let clientId = doc["client_id"].string ?? ""
        let id = URLComponents(string: clientId).flatMap { $0.host?.isEmpty == false ? $0 : nil }
        if id == nil || id?.scheme?.lowercased() != "https" || (id?.port != nil && id?.port != 443)
            || id?.fragment != nil || (fetchedFrom != nil && clientId != fetchedFrom) { out.append("client_id") }
        let type = doc["application_type"].string ?? "web"
        if type != "web" && type != "native" { out.append("application_type") }
        if !(doc["grant_types"].array ?? []).contains(.string("authorization_code")) { out.append("grant_types") }
        if doc["response_types"].array != [.string("code")] { out.append("response_types") }
        let scopes = (doc["scope"].string ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !scopes.contains("atproto") { out.append("scope_atproto") }
        if scopes.contains("transition:generic") { out.append("scope_generic") }
        if doc["dpop_bound_access_tokens"].bool != true { out.append("dpop") }
        if doc["token_endpoint_auth_method"].string != "none" || doc["jwks"].isTruthy || doc["jwks_uri"].isTruthy { out.append("auth_method") }
        let redirects = (doc["redirect_uris"].array ?? []).map { $0.string ?? "" }
        if redirects.isEmpty { out.append("redirect_uris") }
        let scheme = id != nil ? nativeRedirectScheme(clientId) : nil
        for r in redirects {
            if r.hasPrefix("https://") {
                let ru = URLComponents(string: r).flatMap { $0.host?.isEmpty == false ? $0 : nil }
                if ru == nil || (type == "native" && id != nil && origin(ru!) != origin(id!)) { out.append("redirect_origin") }
                continue
            }
            guard let colon = r.firstIndex(of: ":") else { out.append("redirect_scheme"); continue }
            let s = String(r[..<colon])
            let rest = r[r.index(after: colon)...]
            let validScheme = s.first.map { $0.isASCII && $0.isLowercase && $0.isLetter } == true
                && s.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || "+.-".contains($0) }
            guard validScheme, type == "native", s == scheme else { out.append("redirect_scheme"); continue }
            let chars = Array(rest)
            if !(chars.count >= 2 && chars[0] == "/" && chars[1] != "/") { out.append("redirect_slash") }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - Where §12 meets §2 (§12.2)

public extension CardCodec {
    /// §2's serialiser with the §10 lines, the §11 lines and then the §12 line, each omitted when
    /// empty. With `atprotoDid` nil this is the §11 overload, character for character. This is the
    /// one place the atproto extension touches the protocol's own codec, and it is the whole of
    /// §12.2's write-back rule: a client that read `atproto.did` hands it back here on every write,
    /// or a follow — which rewrites the entire pinned message — unlinks the owner's Bluesky account
    /// for every reader until the line is restored.
    static func serialise(_ card: Card, work: Work?, privateId: String?, private priv: PrivateCard? = nil,
                          atprotoDid: String?) -> String {
        let base = serialise(card, work: work, privateId: privateId, private: priv)
        let lines = Atproto.lines(did: atprotoDid, isPrivateCard: priv != nil)
        return lines.isEmpty ? base : base + "\n" + lines.joined(separator: "\n")
    }

    /// §2's 4096 cap, unmoved, counting the §12 line too (about 45 characters).
    static func isFull(_ card: Card, work: Work?, privateId: String?, private priv: PrivateCard? = nil,
                       atprotoDid: String?) -> Bool {
        serialise(card, work: work, privateId: privateId, private: priv, atprotoDid: atprotoDid).count > maxLength
    }
}
