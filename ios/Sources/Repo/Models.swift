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

/// A downloadable TDLib file with the metadata the players need (PROTOCOL §4.10).
struct FileRef: Codable, Equatable, Hashable {
    var fileId: Int
    var uniqueId: String
    var size: Int64
    var mimeType: String
    var fileName: String
    /// TDLib `supportsStreaming`: playback may start from the downloaded prefix.
    var streamable: Bool

    init(fileId: Int, uniqueId: String, size: Int64, mimeType: String, fileName: String, streamable: Bool = false) {
        self.fileId = fileId; self.uniqueId = uniqueId; self.size = size
        self.mimeType = mimeType; self.fileName = fileName; self.streamable = streamable
    }
}

/// What a document opens as (PRODUCT §2.11): viewable types open in-app, the rest download
/// then offer Share.
enum DocumentKind: String, Codable {
    case pdf, image, text, audio, video, other

    static func of(mimeType: String, fileName: String) -> DocumentKind {
        let mime = mimeType.lowercased()
        let ext = (fileName as NSString).pathExtension.lowercased()
        if mime == "application/pdf" || ext == "pdf" { return .pdf }
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"].contains(ext) { return .image }
        if mime.hasPrefix("text/") || mime == "application/json"
            || ["txt", "md", "json", "csv", "log", "xml", "yml", "yaml"].contains(ext) { return .text }
        if mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "flac", "ogg", "aac"].contains(ext) { return .audio }
        if mime.hasPrefix("video/") || ["mp4", "mov", "m4v"].contains(ext) { return .video }
        return .other
    }

    var isViewable: Bool { self != .other }
}

enum PostMedia: Codable, Equatable, Hashable {
    case photo(preview: PhotoRef, full: PhotoRef)
    case video(file: FileRef, thumbnail: PhotoRef?, duration: Int, width: Int, height: Int)
    case animation(file: FileRef, thumbnail: PhotoRef?, duration: Int, width: Int, height: Int)
    case audio(file: FileRef, title: String, performer: String, duration: Int)
    case voice(file: FileRef, duration: Int, waveform: Data)
    case videoNote(file: FileRef, thumbnail: PhotoRef?, duration: Int)
    case document(file: FileRef, thumbnail: PhotoRef?)
    case sticker(file: FileRef, thumbnail: PhotoRef?, width: Int, height: Int, animated: Bool, emoji: String)
    case linkPreview(url: String, siteName: String, title: String, text: String, thumbnail: PhotoRef?)
    /// Poll, location, contact, other: a muted one-line summary; tap opens on Telegram.
    case summary(String)
}

/// A run of styled text derived from TDLib text entities.
struct RichSpan: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case plain, bold, italic, code, link, mention }
    var text: String
    var kind: Kind
    var url: String?
}

struct RichText: Codable, Equatable, Hashable {
    var spans: [RichSpan]
    var plain: String { spans.map(\.text).joined() }
    static let empty = RichText(spans: [])
    var isEmpty: Bool { plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct Reaction: Codable, Equatable, Hashable {
    var emoji: String
    var count: Int
}

/// One post in a feed (PRODUCT §2.3). An album (messages sharing `mediaAlbumId`) is one post:
/// `media` holds every item in posting order and `albumMessageIds` the message id behind each.
struct Post: Codable, Equatable, Hashable, Identifiable, FeedEntry {
    var messageId: Int64
    var chatId: Int64
    var sourceKey: String
    var sourceUsername: String
    var sourceTitle: String
    var sourcePhoto: PhotoRef?
    var date: Int
    var text: RichText
    var media: [PostMedia]
    var albumId: Int64
    var albumMessageIds: [Int64]
    var views: Int
    var reactions: [Reaction]
    var forwardedFrom: String?
    var forwardedChatId: Int64?
    var forwardedUserId: Int64?
    /// Optimistic sends that have not been confirmed by Telegram yet.
    var isPending: Bool = false
    /// Attribution (PRODUCT §2.3): the node the post reaches me through. Nil when no node
    /// attributes it — the card header falls back to the channel photo + title, no subheading.
    var authorUsername: String?
    /// The node card's `name`, falling back to `@username`.
    var authorName: String?
    var authorPhoto: PhotoRef?

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

/// One comment from a comments channel (PROTOCOL §6): a `re:` pointer plus a body, indexed by target.
struct Comment: Codable, Equatable, Hashable, Identifiable {
    var channelUsername: String
    var chatId: Int64
    var messageId: Int64
    var date: Int
    /// The `re:` link as written by the commenter.
    var target: String
    var body: String
    var media: [PostMedia]
    var ownerUsername: String
    var ownerTitle: String
    var ownerPhoto: PhotoRef?
    /// Found via a +1 node (distance 2) rather than a direct follow — shows the `+1` pill.
    var isPlusOne: Bool
    var isMine: Bool
    /// Optimistic send not yet confirmed by Telegram (`Posting…`).
    var isPending: Bool = false

    var id: String { "\(chatId):\(messageId)" }
    /// Every comment has its own t.me link — replying to it is a reply (PROTOCOL §6.2).
    var link: String { DeepLink.post(username: channelUsername, messageId: messageId) }
    var targetKey: String? { CommentCodec.targetKey(target) }
}

/// What a comment points at, carried into the composer (PRODUCT §2.12).
struct CommentTarget: Equatable, Hashable {
    var link: String
    var quoteTitle: String
    var quoteText: String
}

/// One page of the full-screen viewer (PRODUCT §2.11).
enum ViewerItem: Equatable {
    case photo(preview: PhotoRef, full: PhotoRef)
    case video(file: FileRef, thumbnail: PhotoRef?, duration: Int)
    case animation(file: FileRef, thumbnail: PhotoRef?)
    case document(file: FileRef, kind: DocumentKind, thumbnail: PhotoRef?)
}

/// A full-screen viewer request; non-nil hides the topbar and the floating tab bar.
struct ViewerRequest: Equatable {
    var items: [ViewerItem]
    var index: Int
    var caption: String

    /// The viewable items of one post, in album order, with the media list index that opens each.
    static func from(_ post: Post, tappedMediaIndex: Int) -> ViewerRequest? {
        from(media: post.media, caption: post.text.plain, tappedMediaIndex: tappedMediaIndex)
    }

    static func from(media list: [PostMedia], caption: String, tappedMediaIndex: Int) -> ViewerRequest? {
        var items: [ViewerItem] = []
        var openIndex = 0
        for (i, media) in list.enumerated() {
            let item: ViewerItem?
            switch media {
            case .photo(let preview, let full): item = .photo(preview: preview, full: full)
            case .video(let file, let thumbnail, let duration, _, _): item = .video(file: file, thumbnail: thumbnail, duration: duration)
            case .animation(let file, let thumbnail, _, _, _): item = .animation(file: file, thumbnail: thumbnail)
            case .videoNote(let file, let thumbnail, let duration): item = .video(file: file, thumbnail: thumbnail, duration: duration)
            case .document(let file, let thumbnail):
                let kind = DocumentKind.of(mimeType: file.mimeType, fileName: file.fileName)
                item = kind.isViewable ? .document(file: file, kind: kind, thumbnail: thumbnail) : nil
            case .audio, .voice, .sticker, .linkPreview, .summary: item = nil
            }
            guard let item else { continue }
            if i == tappedMediaIndex { openIndex = items.count }
            items.append(item)
        }
        guard !items.isEmpty else { return nil }
        return ViewerRequest(items: items, index: openIndex, caption: caption)
    }
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
