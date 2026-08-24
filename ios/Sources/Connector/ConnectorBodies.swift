// Connector — the §4 response bodies. Mac only.
//
// One file holds every shape the bridge emits, built from the app's own models, so the wire
// contract can be read (and tested) without reading the router. Media is *described* here and
// never carried: §5 is explicit that bytes come from `GET /media/{postId}/{index}` and nowhere
// else, so an assistant can reason about a post without pulling megabytes through a tool call.

#if targetEnvironment(macCatalyst)

import Foundation

enum ConnectorBodies {

    // MARK: Status (§4)

    static func status(signedIn: Bool, account: String?, node: String?, scope: ScopeResolution,
                       writes: ConnectorWrites, tdlib: String, app: String) -> [String: Any] {
        [
            "signedIn": signedIn,
            "account": ConnectorJSON.optional(account),
            "node": ConnectorJSON.optional(node),
            "scope": ["preset": scope.preset.rawValue, "sources": scope.count],
            "writes": ["post": writes.post, "comment": writes.comment, "card": writes.card],
            "tdlib": tdlib,
            "app": app,
        ]
    }

    /// §3: the preset and the resolved username list. There is no endpoint that changes it.
    static func scope(_ scope: ScopeResolution) -> [String: Any] {
        [
            "preset": scope.preset.rawValue,
            "sources": scope.sources.map { ["username": $0.username, "kind": $0.kind.rawValue] },
            "count": scope.count,
        ]
    }

    // MARK: Posts (§4, §5)

    static func media(_ item: PostMedia, index: Int, postCaption: String) -> [String: Any] {
        var kind = "other"
        var caption: String?
        var duration: Int?
        var width: Int?
        var height: Int?
        var fileName: String?
        var bytes: Int64?

        switch item {
        case .photo(_, let full):
            kind = "photo"; width = full.width; height = full.height
        case .video(let file, _, let seconds, let w, let h):
            kind = "video"; duration = seconds; width = w; height = h
            fileName = file.fileName; bytes = file.size
        case .animation(let file, _, let seconds, let w, let h):
            kind = "animation"; duration = seconds; width = w; height = h
            fileName = file.fileName; bytes = file.size
        case .audio(let file, let title, let performer, let seconds):
            kind = "audio"; duration = seconds; bytes = file.size; fileName = file.fileName
            let label = [title, performer].filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
            caption = label.isEmpty ? nil : label
        case .voice(let file, let seconds, _):
            kind = "voice"; duration = seconds; bytes = file.size
        case .videoNote(let file, _, let seconds):
            kind = "videoNote"; duration = seconds; bytes = file.size
        case .document(let file, _):
            kind = "document"; fileName = file.fileName; bytes = file.size
            caption = file.fileName.isEmpty ? nil : file.fileName
        case .sticker(let file, _, let w, let h, _, let emoji):
            kind = "sticker"; width = w; height = h; bytes = file.size
            caption = emoji.isEmpty ? nil : emoji
        case .linkPreview(let url, let siteName, let title, _, _):
            kind = "linkPreview"
            caption = [title, siteName, url].first { !$0.isEmpty }
        case .summary(let text):
            kind = "summary"; caption = text
        }

        // Telegram's caption *is* the message text, and the message text is already `text` on the
        // post — so it is attached to the first item only, and kinds that carry a label of their
        // own (a track title, a file name) keep theirs.
        if caption == nil, index == 0, !postCaption.isEmpty { caption = postCaption }

        return [
            "index": index,
            "kind": kind,
            "caption": ConnectorJSON.optional(caption),
            "durationSeconds": ConnectorJSON.optional(duration),
            "width": ConnectorJSON.optional(width),
            "height": ConnectorJSON.optional(height),
            "fileName": ConnectorJSON.optional(fileName),
            "bytes": bytes.map { Int($0) } ?? NSNull(),
        ]
    }

    static func post(_ post: Post, comments: Int) -> [String: Any] {
        let text = post.text.plain
        return [
            "id": post.id,
            "date": ConnectorJSON.string(fromUnix: post.date),
            "node": ConnectorJSON.optional(post.authorUsername),
            "nodeName": ConnectorJSON.optional(post.authorName),
            "feed": post.sourceUsername,
            "feedTitle": post.sourceTitle,
            "text": text,
            "media": post.media.enumerated().map { media($0.element, index: $0.offset, postCaption: text) },
            "views": post.views,
            "reactions": post.reactions.reduce(0) { $0 + $1.count },
            "comments": comments,
            "link": post.deepLink,
        ]
    }

    static func posts(_ posts: [Post], comments: (Post) -> Int, nextBefore: Date?) -> [String: Any] {
        [
            "posts": posts.map { post($0, comments: comments($0)) },
            "nextBefore": nextBefore.map(ConnectorJSON.string(from:)) ?? NSNull(),
        ]
    }

    // MARK: Feeds and nodes (§4)

    static func feeds(_ feeds: [(info: FeedInfo?, username: String, verified: Bool)]) -> [String: Any] {
        ["feeds": feeds.map { entry in
            [
                "username": entry.username,
                "title": ConnectorJSON.optional(entry.info?.title),
                "verified": entry.verified,
            ] as [String: Any]
        }]
    }

    static func node(_ info: NodeInfo, following: Bool) -> [String: Any] {
        let card = info.card
        return [
            "username": info.username,
            "name": info.displayName,
            "bio": ConnectorJSON.optional(card?.bio),
            "link": ConnectorJSON.optional(card?.link),
            "feeds": card?.feeds ?? [],
            "follows": card?.follows ?? [],
            "public": card?.isPublic ?? false,
            "following": following,
        ]
    }

    static func graph(nodes: [(username: String, name: String?, following: Bool)],
                      edges: [(from: String, to: String)]) -> [String: Any] {
        [
            "nodes": nodes.map { ["username": $0.username, "name": ConnectorJSON.optional($0.name), "following": $0.following] },
            "edges": edges.map { [$0.from, $0.to] },
        ]
    }

    // MARK: Threads (§4, PROTOCOL §6.3)

    static func comment(_ comment: Comment, replies: [[String: Any]]) -> [String: Any] {
        [
            "id": comment.id,
            "link": comment.link,
            "date": ConnectorJSON.string(fromUnix: comment.date),
            "node": comment.ownerUsername,
            "nodeName": comment.ownerTitle,
            "channel": comment.channelUsername,
            "text": comment.body,
            "media": comment.media.enumerated().map { media($0.element, index: $0.offset, postCaption: "") },
            "plusOne": comment.isPlusOne,
            "mine": comment.isMine,
            "replies": replies,
        ]
    }

    static func thread(post body: [String: Any], comments: [[String: Any]]) -> [String: Any] {
        ["post": body, "comments": comments]
    }

    // MARK: Audit (§6)

    static func audit(_ entries: [AuditEntry]) -> [String: Any] {
        ["entries": entries.map { entry in
            [
                "at": ConnectorJSON.string(from: entry.at),
                "tool": entry.tool,
                "decision": entry.decision,
                "outcome": entry.outcome.column,
                "detail": entry.detailColumn,
                "line": entry.line,
            ] as [String: Any]
        }]
    }
}

#endif
