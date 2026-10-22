#if targetEnvironment(macCatalyst)
import Foundation

struct ConnectorHistoryPage {
    var posts: [Post]
    var nextCursor: String?
    var exhausted: Bool
}

/// Exclusive message-id cursor. Dates cannot distinguish posts in the same second.
enum ConnectorHistoryCursor {
    static func encode(source: String, before: Int64) -> String {
        Data("1:\(Username.key(source)):\(before)".utf8).base64EncodedString()
    }

    static func decode(_ cursor: String?, source: String) throws -> Int64 {
        guard let cursor else { return 0 }
        guard cursor.count <= 256, let bytes = Data(base64Encoded: cursor),
              let value = String(data: bytes, encoding: .utf8) else {
            throw ConnectorError.badRequest("invalid history cursor")
        }
        let parts = value.split(separator: ":")
        guard parts.count == 3, parts[0] == "1", parts[1] == Username.key(source),
              let before = Int64(parts[2]), before > 1 else {
            throw ConnectorError.badRequest("invalid history cursor")
        }
        return before
    }
}
#endif
