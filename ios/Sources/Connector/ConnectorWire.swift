// Connector — the wire: HTTP framing, error shapes, and the §4 JSON bodies. Mac only.
//
// There is no web-server dependency here and there is not going to be one. The bridge speaks
// HTTP/1.1 to exactly one client on loopback; a framework would bring routing, middleware,
// content negotiation and a supply chain, none of which this needs and all of which would be
// running inside the process that holds a Telegram session.
//
// Every optional in every response body is encoded explicitly, so a key is always present and
// absence is `null` rather than a missing field. A consumer parsing this should never have to
// tell "the app did not say" from "the app said nothing".

#if targetEnvironment(macCatalyst)

import Foundation

// MARK: - Errors (CONNECTOR.md §2)

enum ConnectorError: Swift.Error, Equatable {
    case unauthorized
    case signedOut
    case outOfScope(String)
    case readOnly
    case telegram(code: Int, message: String)
    case floodWait(seconds: Int)
    case notFound(String)
    case badRequest(String)
    case tooLarge(bytes: Int64, maxBytes: Int64)

    var status: Int {
        switch self {
        case .unauthorized: return 401
        case .signedOut: return 409
        case .outOfScope, .readOnly: return 403
        case .telegram: return 502
        case .floodWait: return 429
        case .notFound: return 404
        case .badRequest: return 400
        case .tooLarge: return 413
        }
    }

    /// The `error` value in the body, and the phrase the audit line records.
    var wire: String {
        switch self {
        case .unauthorized: return "unauthorized"
        case .signedOut: return "signed out"
        case .outOfScope: return "out of scope"
        case .readOnly: return "read only"
        case .telegram: return "telegram"
        case .floodWait: return "flood wait"
        case .notFound: return "not found"
        case .badRequest: return "bad request"
        case .tooLarge: return "too large"
        }
    }

    /// §6 prints the decision, not the payload: `read-only`, `out-of-scope`, `flood-wait`.
    var auditReason: String { wire.replacingOccurrences(of: " ", with: "-") }

    var body: [String: Any] {
        var out: [String: Any] = ["error": wire]
        switch self {
        case .outOfScope(let what): out["detail"] = what
        case .badRequest(let what), .notFound(let what): out["detail"] = what
        case .telegram(let code, let message):
            out["code"] = code
            out["message"] = message
        case .floodWait(let seconds): out["seconds"] = seconds
        case .tooLarge(let bytes, let maxBytes):
            out["bytes"] = bytes
            out["maxBytes"] = maxBytes
        default: break
        }
        return out
    }

    /// TDLib failures reach the wire as §2 says they should: a FLOOD_WAIT is its own 429 so the
    /// caller can back off, everything else is a 502 carrying Telegram's own code and message.
    static func from(_ error: Swift.Error) -> ConnectorError {
        if let connector = error as? ConnectorError { return connector }
        // `TDFailure(_:)` only unwraps a raw `TDLibKit.Error`; handed an already-normalised
        // `TDFailure` — which is what the repositories and `AppModel.perform` actually throw — it
        // would re-wrap it as code -1 with the description as the message, and Telegram's real
        // code would never reach the wire.
        let failure = (error as? TDFailure) ?? TDFailure(error)
        if let seconds = failure.floodWaitSeconds, seconds > 0 { return .floodWait(seconds: seconds) }
        return .telegram(code: failure.code, message: failure.message)
    }
}

// MARK: - Request / response

struct ConnectorRequest: Sendable, Equatable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    /// `GET /feed` — the audit log's tool column and §7's tool name.
    var tool: String { method + " " + path }

    var authorization: String? { headers["authorization"] }

    /// Path components with the leading slash dropped: `/feed/tgs_ana` → `["feed", "tgs_ana"]`.
    var segments: [String] {
        path.split(separator: "/").map(String.init)
    }

    func intQuery(_ name: String, default fallback: Int, max cap: Int) -> Int {
        guard let raw = query[name], let value = Int(raw) else { return fallback }
        return Swift.min(Swift.max(value, 1), cap)
    }

    func dateQuery(_ name: String) -> Date? {
        guard let raw = query[name] else { return nil }
        return ConnectorJSON.date(from: raw)
    }
}

struct ConnectorResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func json(_ status: Int, _ object: Any) -> ConnectorResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]))
            ?? Data(#"{"error":"internal"}"#.utf8)
        return ConnectorResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    static func error(_ error: ConnectorError) -> ConnectorResponse {
        json(error.status, error.body)
    }

    static func bytes(_ data: Data, contentType: String) -> ConnectorResponse {
        ConnectorResponse(status: 200, headers: ["Content-Type": contentType], body: data)
    }

    var statusText: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Content Too Large"
        case 429: return "Too Many Requests"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }

    /// HTTP/1.1 with `Connection: close`: one request per connection. Keep-alive would buy
    /// nothing on loopback and would need idle-timeout bookkeeping that could hold a socket open
    /// after the user flips the bridge off — which §2 says must not happen.
    func serialised() -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        // The bridge is not a browser target, but a stray page that guessed the port should never
        // be able to read a response out of it.
        all["X-Content-Type-Options"] = "nosniff"
        all["Cache-Control"] = "no-store"
        for key in all.keys.sorted() { head += "\(key): \(all[key]!)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

// MARK: - Parsing

enum ConnectorHTTP {
    /// Anything larger than this is not a request this bridge serves; §4's bodies are a feed name
    /// and some text. The cap exists so a local process cannot make the app allocate without bound.
    static let maxBodyBytes = 1 << 20
    static let maxHeadBytes = 64 * 1024

    enum ParseResult {
        /// The head has not arrived yet, or the body is short of `Content-Length`.
        case incomplete
        case request(ConnectorRequest)
        case malformed(String)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headEnd = range(of: Data("\r\n\r\n".utf8), in: buffer) else {
            if buffer.count > maxHeadBytes { return .malformed("headers too large") }
            return .incomplete
        }
        let headData = buffer[buffer.startIndex..<headEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return .malformed("headers are not UTF-8") }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed("no request line") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestLine.count >= 2 else { return .malformed("bad request line") }
        let method = requestLine[0].uppercased()
        let target = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared >= 0, declared <= maxBodyBytes else { return .malformed("body too large") }
        let bodyStart = headEnd.upperBound
        let available = buffer.count - buffer.distance(from: buffer.startIndex, to: bodyStart)
        guard available >= declared else { return .incomplete }
        let bodyEnd = buffer.index(bodyStart, offsetBy: declared)
        let body = Data(buffer[bodyStart..<bodyEnd])

        let (path, query) = splitTarget(target)
        // The target is percent-decoded above, so `/feed%0d%0a…` arrives here carrying a real
        // CRLF. No path this bridge serves contains a control character, and the path is written
        // to the audit log (§6) on the way out of the 401 branch — before any token is checked.
        // Refusing the request outright is cheaper than trusting the log's own escaping, and it
        // means the forged line is never even offered to the sink.
        guard !hasControlCharacters(path) else { return .malformed("control characters in the request target") }
        return .request(ConnectorRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    /// C0, DEL and C1 — everything that can terminate a line in a log, a header or a terminal.
    static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value) }
    }

    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let rawPath = parts.first ?? "/"
        let path = rawPath.removingPercentEncoding ?? rawPath
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let name = kv.first, !name.isEmpty else { continue }
                let raw = kv.count == 2 ? kv[1] : ""
                let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
                query[name.removingPercentEncoding ?? name] = decoded
            }
        }
        return (path, query)
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        haystack.range(of: needle)
    }
}

// MARK: - JSON helpers

enum ConnectorJSON {
    /// CONNECTOR.md §2: "Timestamps are ISO-8601."
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func string(fromUnix seconds: Int) -> String { string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) }

    static func date(from string: String) -> Date? {
        if let d = formatter.date(from: string) { return d }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string)
    }

    /// `null` for an absent value, so every key in every §4 body is always present.
    static func optional(_ value: String?) -> Any { value ?? NSNull() }
    static func optional(_ value: Int?) -> Any { value ?? NSNull() }
}

// MARK: - Request bodies (§4 Write)

struct ConnectorPostBody: Decodable {
    var feed: String
    var text: String
}

struct ConnectorCommentBody: Decodable {
    var target: String
    var text: String
}

struct ConnectorCardBody: Decodable {
    var name: String?
    var bio: String?
    var link: String?
}

extension ConnectorRequest {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard !body.isEmpty else { throw ConnectorError.badRequest("empty body") }
        do { return try JSONDecoder().decode(T.self, from: body) }
        catch { throw ConnectorError.badRequest("body does not match the endpoint") }
    }
}

#endif
