// Repo — TDLib types → app models. The only place that knows both shapes.

import Foundation
import TDLibKit

enum Mapping {
    static func photoRef(_ info: ChatPhotoInfo?) -> PhotoRef? {
        guard let info else { return nil }
        return PhotoRef(fileId: info.small.id, uniqueId: info.small.remote.uniqueId,
                        width: info.minithumbnail?.width ?? 0, height: info.minithumbnail?.height ?? 0,
                        minithumbnail: info.minithumbnail?.data)
    }

    /// Smallest photo size whose width is ≥ `minWidth`; falls back to the largest (PROTOCOL §4.10).
    static func photoRef(_ photo: Photo, minWidth: Int) -> PhotoRef? {
        let sorted = photo.sizes.sorted { $0.width < $1.width }
        guard let pick = sorted.first(where: { $0.width >= minWidth }) ?? sorted.last else { return nil }
        return PhotoRef(fileId: pick.photo.id, uniqueId: pick.photo.remote.uniqueId,
                        width: pick.width, height: pick.height, minithumbnail: photo.minithumbnail?.data)
    }

    static func photoRef(_ thumb: Thumbnail?, minithumbnail: Minithumbnail?) -> PhotoRef? {
        guard let thumb else { return nil }
        return PhotoRef(fileId: thumb.file.id, uniqueId: thumb.file.remote.uniqueId,
                        width: thumb.width, height: thumb.height, minithumbnail: minithumbnail?.data)
    }

    static func username(of chat: Chat, supergroup: Supergroup?) -> String? {
        guard let sg = supergroup, let names = sg.usernames else { return nil }
        if !names.editableUsername.isEmpty { return names.editableUsername }
        return names.activeUsernames.first
    }

    static func supergroupId(of chat: Chat) -> Int64? {
        if case .chatTypeSupergroup(let sg) = chat.type { return sg.supergroupId }
        return nil
    }

    static func isChannel(_ chat: Chat) -> Bool { isChannel(chat.type) }

    /// A chat type is a channel only as a supergroup flagged `isChannel`: a private chat, a basic
    /// group, a secret chat and an ordinary supergroup are all not one.
    static func isChannel(_ type: ChatType) -> Bool {
        if case .chatTypeSupergroup(let sg) = type { return sg.isChannel }
        return false
    }

    // MARK: Rich text

    static func richText(_ formatted: FormattedText) -> RichText {
        let utf16 = Array(formatted.text.utf16)
        guard !utf16.isEmpty else { return .empty }
        // TDLib offsets are UTF-16 code units. Build a per-unit style map, then coalesce.
        var kinds = [RichSpan.Kind](repeating: .plain, count: utf16.count)
        var urls = [String?](repeating: nil, count: utf16.count)
        for e in formatted.entities {
            let lo = max(0, e.offset), hi = min(utf16.count, e.offset + e.length)
            guard lo < hi else { continue }
            let kind: RichSpan.Kind?
            var url: String?
            switch e.type {
            case .textEntityTypeBold: kind = .bold
            case .textEntityTypeItalic: kind = .italic
            case .textEntityTypeCode, .textEntityTypePre, .textEntityTypePreCode: kind = .code
            case .textEntityTypeUrl:
                kind = .link
                url = String(utf16CodeUnits: Array(utf16[lo..<hi]), count: hi - lo)
            case .textEntityTypeTextUrl(let t): kind = .link; url = t.url
            case .textEntityTypeMention:
                kind = .mention
                let raw = String(utf16CodeUnits: Array(utf16[lo..<hi]), count: hi - lo)
                url = Username.normalise(raw).map { DeepLink.chat(username: $0) }
            default: kind = nil
            }
            guard let kind else { continue }
            for i in lo..<hi where kinds[i] == .plain || kind == .link || kind == .mention {
                kinds[i] = kind
                if let url { urls[i] = url }
            }
        }
        var spans: [RichSpan] = []
        var start = 0
        for i in 1...utf16.count {
            if i == utf16.count || kinds[i] != kinds[start] || urls[i] != urls[start] {
                let text = String(utf16CodeUnits: Array(utf16[start..<i]), count: i - start)
                spans.append(RichSpan(text: text, kind: kinds[start], url: urls[start]))
                start = i
            }
        }
        return RichText(spans: spans)
    }

    // MARK: Posts

    static let feedPhotoMinWidth = 540

    static func fileRef(_ file: File, mimeType: String, fileName: String, streamable: Bool = false) -> FileRef {
        FileRef(fileId: file.id, uniqueId: file.remote.uniqueId,
                size: file.size > 0 ? file.size : file.expectedSize,
                mimeType: mimeType, fileName: fileName, streamable: streamable)
    }

    /// The largest available size, for the full-screen viewer.
    static func fullPhotoRef(_ photo: Photo) -> PhotoRef? {
        guard let pick = photo.sizes.max(by: { $0.width < $1.width }) else { return nil }
        return PhotoRef(fileId: pick.photo.id, uniqueId: pick.photo.remote.uniqueId,
                        width: pick.width, height: pick.height, minithumbnail: photo.minithumbnail?.data)
    }

    /// Humanised summary for content the card renders as one muted line (PRODUCT §2.11).
    private static func summary(_ content: MessageContent) -> PostMedia? {
        switch content {
        case .messagePoll(let p):
            let n = p.poll.options.count
            return .summary("Poll \u{00B7} \(n) option\(n == 1 ? "" : "s")")
        case .messageLocation, .messageLiveLocation:
            return .summary("Location")
        case .messageVenue(let v):
            return .summary(v.venue.title.isEmpty ? "Location" : "Location \u{00B7} \(v.venue.title)")
        case .messageContact(let c):
            let name = [c.contact.firstName, c.contact.lastName].filter { !$0.isEmpty }.joined(separator: " ")
            return .summary(name.isEmpty ? "Contact" : "Contact \u{00B7} \(name)")
        case .messageDice: return .summary("Dice")
        case .messageGame: return .summary("Game")
        case .messageInvoice: return .summary("Invoice")
        case .messageStory: return .summary("Story")
        case .messageGiveaway, .messageGiveawayWinners: return .summary("Giveaway")
        case .messagePaidMedia: return .summary("Paid media")
        case .messageChecklist: return .summary("Checklist")
        case .messageExpiredPhoto, .messageExpiredVideo, .messageExpiredVideoNote, .messageExpiredVoiceNote:
            return .summary("Expired media")
        case .messageUnsupported: return .summary("Unsupported post")
        default: return nil
        }
    }

    /// nil for service messages and the card itself (PROTOCOL §4.8).
    static func post(_ m: Message, source: FeedInfo) -> Post? {
        var text = RichText.empty
        var media: [PostMedia] = []
        switch m.content {
        case .messageText(let t):
            if CardCodec.isCard(t.text.text) { return nil }
            text = richText(t.text)
            if let preview = linkPreview(t.linkPreview) { media.append(preview) }
        case .messagePhoto(let p):
            text = richText(p.caption)
            if let preview = photoRef(p.photo, minWidth: feedPhotoMinWidth), let full = fullPhotoRef(p.photo) {
                media.append(.photo(preview: preview, full: full))
            }
        case .messageVideo(let v):
            text = richText(v.caption)
            media.append(.video(file: fileRef(v.video.video, mimeType: v.video.mimeType, fileName: v.video.fileName, streamable: v.video.supportsStreaming),
                                thumbnail: photoRef(v.video.thumbnail, minithumbnail: v.video.minithumbnail),
                                duration: v.video.duration, width: v.video.width, height: v.video.height))
        case .messageAnimation(let a):
            text = richText(a.caption)
            media.append(.animation(file: fileRef(a.animation.animation, mimeType: a.animation.mimeType, fileName: a.animation.fileName, streamable: true),
                                    thumbnail: photoRef(a.animation.thumbnail, minithumbnail: a.animation.minithumbnail),
                                    duration: a.animation.duration, width: a.animation.width, height: a.animation.height))
        case .messageDocument(let d):
            text = richText(d.caption)
            media.append(.document(file: fileRef(d.document.document, mimeType: d.document.mimeType, fileName: d.document.fileName),
                                   thumbnail: photoRef(d.document.thumbnail, minithumbnail: d.document.minithumbnail)))
        case .messageAudio(let a):
            text = richText(a.caption)
            media.append(.audio(file: fileRef(a.audio.audio, mimeType: a.audio.mimeType, fileName: a.audio.fileName),
                                title: a.audio.title, performer: a.audio.performer, duration: a.audio.duration))
        case .messageVoiceNote(let v):
            text = richText(v.caption)
            media.append(.voice(file: fileRef(v.voiceNote.voice, mimeType: v.voiceNote.mimeType, fileName: ""),
                                duration: v.voiceNote.duration, waveform: v.voiceNote.waveform))
        case .messageVideoNote(let v):
            media.append(.videoNote(file: fileRef(v.videoNote.video, mimeType: "video/mp4", fileName: "", streamable: true),
                                    thumbnail: photoRef(v.videoNote.thumbnail, minithumbnail: v.videoNote.minithumbnail),
                                    duration: v.videoNote.duration))
        case .messageSticker(let s):
            let animated: Bool
            switch s.sticker.format {
            case .stickerFormatWebp: animated = false
            case .stickerFormatTgs, .stickerFormatWebm: animated = true
            }
            media.append(.sticker(file: fileRef(s.sticker.sticker, mimeType: "", fileName: ""),
                                  thumbnail: photoRef(s.sticker.thumbnail, minithumbnail: nil),
                                  width: s.sticker.width, height: s.sticker.height,
                                  animated: animated, emoji: s.sticker.emoji))
        case .messageAnimatedEmoji(let e):
            text = RichText(spans: [RichSpan(text: e.emoji, kind: .plain, url: nil)])
        default:
            guard let s = summary(m.content) else { return nil }
            media.append(s)
        }
        let views = m.interactionInfo?.viewCount ?? 0
        let reactions: [Reaction] = (m.interactionInfo?.reactions?.reactions ?? []).compactMap { r in
            if case .reactionTypeEmoji(let e) = r.type { return Reaction(emoji: e.emoji, count: r.totalCount) }
            return nil
        }
        var forwarded: String?
        var forwardedChatId: Int64?
        var forwardedUserId: Int64?
        if let f = m.forwardInfo {
            switch f.origin {
            case .messageOriginHiddenUser(let h): forwarded = h.senderName
            case .messageOriginUser(let u): forwardedUserId = u.senderUserId
            case .messageOriginChat(let c): forwardedChatId = c.senderChatId
            case .messageOriginChannel(let c): forwardedChatId = c.chatId
            }
        }
        var isPending = false
        if let state = m.sendingState, case .messageSendingStatePending = state { isPending = true }
        return Post(messageId: m.id, chatId: m.chatId, sourceKey: source.key, sourceUsername: source.username,
                    sourceTitle: source.title, sourcePhoto: source.photo, date: m.date, text: text, media: media,
                    albumId: m.mediaAlbumId.rawValue, albumMessageIds: [m.id],
                    views: views, reactions: reactions, forwardedFrom: forwarded, forwardedChatId: forwardedChatId,
                    forwardedUserId: forwardedUserId, isPending: isPending)
    }

    /// `linkPreview` title/description/thumbnail as a bordered row (PRODUCT §2.11).
    static func linkPreview(_ lp: LinkPreview?) -> PostMedia? {
        guard let lp, !lp.url.isEmpty else { return nil }
        var thumbnail: PhotoRef?
        switch lp.type {
        case .linkPreviewTypeArticle(let a): thumbnail = a.photo.flatMap { photoRef($0, minWidth: 0) }
        case .linkPreviewTypePhoto(let p): thumbnail = photoRef(p.photo, minWidth: 0)
        case .linkPreviewTypeVideo(let v): thumbnail = v.cover.flatMap { photoRef($0, minWidth: 0) }
        case .linkPreviewTypeApp(let a): thumbnail = photoRef(a.photo, minWidth: 0)
        default: break
        }
        let site = lp.siteName.isEmpty ? lp.displayUrl : lp.siteName
        return .linkPreview(url: lp.url, siteName: site, title: lp.title,
                            text: lp.description.text, thumbnail: thumbnail)
    }

    /// Maps a page of messages, folding albums (`mediaAlbumId`) into single posts, newest first.
    static func posts(_ messages: [Message], source: FeedInfo) -> [Post] {
        var out: [Post] = []
        for m in messages {
            guard let p = post(m, source: source) else { continue }
            if p.albumId != 0, let i = out.firstIndex(where: { $0.chatId == p.chatId && $0.albumId == p.albumId }) {
                out[i] = merged(out[i], p)
            } else {
                out.append(p)
            }
        }
        return FeedOrder.sortedNewestFirst(out)
    }

    /// Folds two parts of one album. The representative keeps the smallest message id (where the
    /// t.me link points); media stays in posting order; the first non-empty caption wins.
    static func merged(_ a: Post, _ b: Post) -> Post {
        var head = a.messageId <= b.messageId ? a : b
        let tail = a.messageId <= b.messageId ? b : a
        var pairs = Array(zip(head.albumMessageIds, head.media)) + Array(zip(tail.albumMessageIds, tail.media))
        pairs.sort { $0.0 < $1.0 }
        var seen = Set<Int64>()
        pairs = pairs.filter { seen.insert($0.0).inserted }
        head.albumMessageIds = pairs.map(\.0)
        head.media = pairs.map(\.1)
        if head.text.isEmpty { head.text = tail.text }
        head.views = max(head.views, tail.views)
        if head.reactions.isEmpty { head.reactions = tail.reactions }
        head.isPending = head.isPending || tail.isPending
        return head
    }
}
