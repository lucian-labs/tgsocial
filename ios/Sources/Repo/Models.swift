// Repo — app-level models. Serialisable (PROTOCOL.md §6), independent of TDLib types so caches survive restarts.

import Foundation

/// The local pointer to my node (PROTOCOL §4.2).
struct MyNode: Codable, Equatable {
    var chatId: Int64
    var supergroupId: Int64
    var username: String
    var pinnedMessageId: Int64
}

enum CardState: String, Codable, Equatable {
    case ok, newerVersion, notANode
}

/// A node as read from Telegram: chat + parsed card, cached with `fetchedAt` (PROTOCOL §4.5).
struct NodeInfo: Codable, Equatable, Identifiable {
    var username: String
    var chatId: Int64
    var title: String
    var card: Card?
    var state: CardState
    var photo: PhotoRef?
    var fetchedAt: Date

    var id: String { Username.key(username) }
    var key: String { Username.key(username) }
    var displayName: String { (card?.name?.isEmpty == false ? card?.name : nil) ?? title }
    var initial: String { String(displayName.prefix(1)) }
    var feedCount: Int { card?.feeds.count ?? 0 }
}

/// A feed channel: public channel with a username.
struct FeedInfo: Codable, Equatable, Identifiable {
    var username: String
    var chatId: Int64
    var title: String
    var description: String
    var photo: PhotoRef?
    var fetchedAt: Date

    var id: String { Username.key(username) }
    var key: String { Username.key(username) }
    func isVerified(for node: String) -> Bool { Backlink.verifies(description: description, node: node) }
}

/// A channel I administer with post rights — a candidate feed (PROTOCOL §4.7).
struct FeedCandidate: Codable, Equatable, Identifiable {
    var chatId: Int64
    var supergroupId: Int64
    var title: String
    var username: String?
    var description: String
    var id: Int64 { chatId }
    var isPublic: Bool { username != nil }
}

/// A TDLib file reference that can be re-resolved later (cache key is `uniqueId`).
struct PhotoRef: Codable, Equatable, Hashable {
    var fileId: Int
    var uniqueId: String
    var width: Int
    var height: Int
    var minithumbnail: Data?
}

enum PostMedia: Codable, Equatable {
    case photo(PhotoRef)
    case video(thumbnail: PhotoRef?, duration: Int)
    case animation(thumbnail: PhotoRef?, duration: Int)
    case document(fileName: String, thumbnail: PhotoRef?)
    case audio(title: String, performer: String, duration: Int)
}

/// A run of styled text derived from TDLib text entities.
struct RichSpan: Codable, Equatable {
    enum Kind: String, Codable { case plain, bold, italic, code, link, mention }
    var text: String
    var kind: Kind
    var url: String?
}

struct RichText: Codable, Equatable {
    var spans: [RichSpan]
    var plain: String { spans.map(\.text).joined() }
    static let empty = RichText(spans: [])
    var isEmpty: Bool { plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct Reaction: Codable, Equatable {
    var emoji: String
    var count: Int
}

/// One post in a feed (PRODUCT §2.3).
struct Post: Codable, Equatable, Identifiable, FeedEntry {
    var messageId: Int64
    var chatId: Int64
    var sourceKey: String
    var sourceUsername: String
    var sourceTitle: String
    var sourcePhoto: PhotoRef?
    var date: Int
    var text: RichText
    var media: PostMedia?
    var views: Int
    var reactions: [Reaction]
    var forwardedFrom: String?
    var forwardedChatId: Int64?
    var forwardedUserId: Int64?
    /// Optimistic sends that have not been confirmed by Telegram yet.
    var isPending: Bool = false

    var id: String { "\(chatId):\(messageId)" }
    var deepLink: String { DeepLink.post(username: sourceUsername, messageId: messageId) }
}

/// One row in Explore / Graph (PROTOCOL §5).
struct DirectoryEntry: Equatable, Identifiable {
    var node: NodeInfo
    /// +1 results: how many of my follows list this node.
    var followedByCount: Int
    var id: String { node.id }
}

enum StatusKind: Equatable {
    case synced, syncing, offline, signedOut
    var label: String {
        switch self {
        case .synced: return "Synced"
        case .syncing: return "Syncing"
        case .offline: return "Offline"
        case .signedOut: return "Signed out"
        }
    }
}
