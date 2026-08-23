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

    static func isChannel(_ chat: Chat) -> Bool {
        if case .chatTypeSupergroup(let sg) = chat.type { return sg.isChannel }
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

    /// nil for service messages, the card itself, and unsupported content (PROTOCOL §4.8).
    static func post(_ m: Message, source: FeedInfo) -> Post? {
        var text = RichText.empty
        var media: PostMedia?
        switch m.content {
        case .messageText(let t):
            if CardCodec.isCard(t.text.text) { return nil }
            text = richText(t.text)
        case .messagePhoto(let p):
            text = richText(p.caption)
            media = photoRef(p.photo, minWidth: feedPhotoMinWidth).map { .photo($0) }
        case .messageVideo(let v):
            text = richText(v.caption)
            media = .video(thumbnail: photoRef(v.video.thumbnail, minithumbnail: v.video.minithumbnail), duration: v.video.duration)
        case .messageAnimation(let a):
            text = richText(a.caption)
            media = .animation(thumbnail: photoRef(a.animation.thumbnail, minithumbnail: a.animation.minithumbnail), duration: a.animation.duration)
        case .messageDocument(let d):
            text = richText(d.caption)
            media = .document(fileName: d.document.fileName, thumbnail: photoRef(d.document.thumbnail, minithumbnail: d.document.minithumbnail))
        case .messageAudio(let a):
            text = richText(a.caption)
            media = .audio(title: a.audio.title, performer: a.audio.performer, duration: a.audio.duration)
        default:
            return nil
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
                    views: views, reactions: reactions, forwardedFrom: forwarded, forwardedChatId: forwardedChatId,
                    forwardedUserId: forwardedUserId, isPending: isPending)
    }
}
