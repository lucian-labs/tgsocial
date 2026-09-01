// Test fixtures shared by the media and comment suites (PRODUCT §2.11.2, §2.11.3, §2.12).
//
// `ConnectorFixture` has builders of the same shape, but it lives behind
// `#if targetEnvironment(macCatalyst)` with the bridge it tests, so it is not in scope in
// `make test`. These are the same models built for the simulator run.

import Foundation
@testable import tgsocial

enum MediaFixture {
    static let feed = "waveloop_devlog"
    static let repliesChannel = "tgs_ana_r"

    /// TDLib message ids are `serverId << 20`, and `DeepLink.post` shifts back down — so a fixture
    /// that writes a raw 144 gets a t.me link ending in /0. Build them the way TDLib does.
    static func messageId(server: Int64) -> Int64 { server << 20 }

    static func post(messageId: Int64 = MediaFixture.messageId(server: 144),
                     text: String = "shipped the sequencer",
                     media: [PostMedia] = [],
                     albumMessageIds: [Int64]? = nil) -> Post {
        Post(messageId: messageId, chatId: -100_1, sourceKey: Username.key(feed),
             sourceUsername: feed, sourceTitle: "WaveLoop devlog", sourcePhoto: nil,
             date: 1_787_500_920, text: RichText(spans: [RichSpan(text: text, kind: .plain, url: nil)]),
             media: media, albumId: 0, albumMessageIds: albumMessageIds ?? [messageId],
             views: 1200, reactions: [], forwardedFrom: nil, forwardedChatId: nil,
             forwardedUserId: nil, isPending: false,
             authorUsername: "tgs_ana", authorName: "Ana Iliovic", authorPhoto: nil)
    }

    static func comment(target: String, body: String = "Nice one. The bass is huge.",
                        serverMessageId: Int64 = 9, owner: String = "Ana Iliovic") -> Comment {
        let messageId = MediaFixture.messageId(server: serverMessageId)
        return comment(target: target, body: body, messageId: messageId, owner: owner)
    }

    static func comment(target: String, body: String, messageId: Int64,
                        owner: String = "Ana Iliovic") -> Comment {
        Comment(channelUsername: repliesChannel, chatId: -100_4, messageId: messageId,
                date: 1_787_500_930, target: target, body: body, media: [],
                ownerUsername: "tgs_ana", ownerTitle: owner, ownerPhoto: nil,
                isPlusOne: false, isMine: false, isPending: false)
    }

    static func photoRef(_ n: Int, width: Int = 1200, height: Int = 800) -> PhotoRef {
        PhotoRef(fileId: n, uniqueId: "photo\(n)", width: width, height: height, minithumbnail: nil)
    }

    static func photo(_ n: Int, width: Int = 1200, height: Int = 800) -> PostMedia {
        let ref = photoRef(n, width: width, height: height)
        return .photo(preview: ref, full: ref)
    }

    static func photos(_ count: Int) -> [PostMedia] { (0..<count).map { photo($0) } }

    /// An album: `count` photos, `count` message ids, one post — the shape `Mapping.merged` builds.
    static func album(count: Int = 4, firstServerId: Int64 = 144) -> Post {
        let ids = (0..<count).map { messageId(server: firstServerId + Int64($0)) }
        return post(messageId: ids[0], media: photos(count), albumMessageIds: ids)
    }
}
