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

/// What a comment points at, carried into the composer (PRODUCT §2.12). `link` is what becomes the
/// `re: ` line (PROTOCOL §6.2); the other two are only what the quote line shows.
struct CommentTarget: Equatable, Hashable {
    var link: String
    var quoteTitle: String
    var quoteText: String

    /// The muted quote line above the composer: `re: <title> — 'body…'` (PRODUCT §2.12).
    var quoteLine: String {
        var quote = quoteText.replacingOccurrences(of: "\n", with: " ")
        if quote.count > CommentTarget.quoteMax { quote = String(quote.prefix(CommentTarget.quoteMax)) + "\u{2026}" }
        let head = "re: \(quoteTitle)"
        return quote.isEmpty ? head : head + " \u{2014} '\(quote)'"
    }

    /// Characters of the target's own body the quote line shows before it elides.
    static let quoteMax = 80
}

/// Where a comment being written will point (PRODUCT §2.12, PROTOCOL §6.2).
///
/// Two links, never one. `post` is the item the thread is about — on the carousel that is the album
/// item you are looking at, which is why paging re-targets. `reply` is the comment a tap selected,
/// and while it is set it WINS: "the target is whatever you tapped". Clearing it — tapping the same
/// comment again, or the quote's × — drops back to `post`, and the `re:` line follows, because the
/// `re:` line is written from `active.link` and from nothing else.
///
/// Flat rather than recursive on purpose: a target that could nest inside a target is a chain the
/// composer would have to walk, and §6.2's chain lives in the messages, not in this value.
struct CommentTargeting: Equatable, Hashable {
    var post: CommentTarget
    var reply: CommentTarget?

    var active: CommentTarget { reply ?? post }
    var isReply: Bool { reply != nil }

    init(post: CommentTarget, reply: CommentTarget? = nil) {
        self.post = post; self.reply = reply
    }

    /// The composer's placeholder: `Reply to <name>.` while a comment is selected, `Say it.`
    /// otherwise (PRODUCT §2.12).
    var placeholder: String {
        guard let reply else { return "Say it." }
        return "Reply to \(reply.quoteTitle)."
    }

    /// The message this would write (PROTOCOL §6.2): `re: ` + the ACTIVE target's own t.me link,
    /// then the body. The same serialiser `CommentRepository.post` runs, from the same link — which
    /// is the whole of "the target is whatever you tapped".
    func message(body: String) -> String {
        CommentCodec.serialise(target: active.link, body: body)
    }

    /// Where a comment written now would point. `itemLink` is the album item the carousel is
    /// showing (PRODUCT §2.12: "paging … re-targets the thread to that item's post"); without one
    /// it is the post's own link. `reply` is the comment a tap selected, and it wins.
    static func make(post: Post, itemLink: String? = nil, reply: Comment? = nil) -> CommentTargeting {
        let quote = post.text.plain.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = CommentTarget(link: itemLink ?? post.deepLink,
                                 quoteTitle: post.sourceTitle, quoteText: quote)
        return CommentTargeting(post: base, reply: reply.map {
            CommentTarget(link: $0.link, quoteTitle: $0.ownerTitle, quoteText: $0.body)
        })
    }
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
    /// The post the media came from. The carousel's `Comments` control (PRODUCT §2.12) needs it;
    /// media inside a comment has none, and carries no Comments control.
    var post: Post?
    /// The `t.me` link of each item's own message, parallel to `items`. An album item is its own
    /// message, so paging the carousel re-targets the thread to the item you are looking at.
    var itemLinks: [String]
    /// Identity of *this opening*, not of what is being opened. `ViewerOverlay` keeps the page, the
    /// drag and the comments toggle in `@State`, which SwiftUI preserves across a request → request
    /// change because the view keeps its structural identity — and PRODUCT §2.12 makes that change
    /// reachable, since a comment inside the open viewer's thread renders its own media and tapping
    /// it assigns `model.viewer` again with no nil in between. Without a new identity the second
    /// viewer opens on the first one's page, so §2.11.3's "tapping tile N opens the carousel at
    /// index N" quietly stops holding. `RootView` hangs `.id(openingID)` off this.
    let openingID = UUID()

    init(items: [ViewerItem], index: Int, caption: String,
         post: Post? = nil, itemLinks: [String] = []) {
        self.items = items; self.index = index; self.caption = caption
        self.post = post; self.itemLinks = itemLinks
    }

    /// The link of the item at `index`, falling back to the post's own — which is the right answer
    /// for a post that is not an album, where every item shares one message.
    func link(at index: Int) -> String? {
        if itemLinks.indices.contains(index) { return itemLinks[index] }
        return post?.deepLink
    }

    /// The viewable items of one post, in album order, with the media list index that opens each.
    static func from(_ post: Post, tappedMediaIndex: Int) -> ViewerRequest? {
        guard var request = from(media: post.media, caption: post.text.plain,
                                 tappedMediaIndex: tappedMediaIndex) else { return nil }
        request.post = post
        request.itemLinks = links(of: post)
        return request
    }

    /// One `t.me` link per VIEWABLE item, in the same order as `items`. `albumMessageIds` runs
    /// parallel to `media` only when the post really is an album (`Mapping.merged` builds them
    /// together); anything else is one message, so every item points at it.
    static func links(of post: Post) -> [String] {
        let album = post.albumMessageIds.count == post.media.count
        var out: [String] = []
        for (i, media) in post.media.enumerated() {
            guard isViewable(media) else { continue }
            let messageId = album ? post.albumMessageIds[i] : post.messageId
            out.append(DeepLink.post(username: post.sourceUsername, messageId: messageId))
        }
        return out
    }

    private static func isViewable(_ media: PostMedia) -> Bool { item(for: media) != nil }

    private static func item(for media: PostMedia) -> ViewerItem? {
        switch media {
        case .photo(let preview, let full): return .photo(preview: preview, full: full)
        case .video(let file, let thumbnail, let duration, _, _): return .video(file: file, thumbnail: thumbnail, duration: duration)
        case .animation(let file, let thumbnail, _, _, _): return .animation(file: file, thumbnail: thumbnail)
        case .videoNote(let file, let thumbnail, let duration): return .video(file: file, thumbnail: thumbnail, duration: duration)
        case .document(let file, let thumbnail):
            let kind = DocumentKind.of(mimeType: file.mimeType, fileName: file.fileName)
            return kind.isViewable ? .document(file: file, kind: kind, thumbnail: thumbnail) : nil
        case .audio, .voice, .sticker, .linkPreview, .summary: return nil
        }
    }

    static func from(media list: [PostMedia], caption: String, tappedMediaIndex: Int) -> ViewerRequest? {
        var items: [ViewerItem] = []
        var openIndex = 0
        for (i, media) in list.enumerated() {
            guard let item = item(for: media) else { continue }
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
