// Repo — the private layer's app models (PROTOCOL.md §7.2, §11.1). Serialisable where they are
// cached; independent of TDLib types so the record survives restarts.

import Foundation

/// My private node (PROTOCOL §11.1): a private channel I created, whose pinned message is my
/// private card. `invite` is the one join-approval link the app shows the owner (§11.4.1 step 3).
struct PrivateNodeRef: Codable, Equatable {
    var chatId: Int64
    var supergroupId: Int64
    var pinnedMessageId: Int64
    var invite: String?
}

/// One further private feed I own (§11.4.2), listed on my private card by its invite link.
struct PrivateFeedRef: Codable, Equatable, Identifiable {
    var chatId: Int64
    var supergroupId: Int64
    var invite: String?
    /// The channel title, cached for the rows; Telegram is the source of truth.
    var title: String

    var id: Int64 { chatId }
}

/// A request I made and Telegram does not hold for me (§11.4.7): keyed by the canonical invite
/// link, cleared when `checkChatInviteLink` answers with a chat id.
struct PendingRequest: Codable, Equatable, Identifiable {
    var invite: String
    var title: String
    /// ISO 8601 UTC.
    var askedAt: String
    /// The preview's photo, so the WAITING row can wear it. Not part of the shared wire shape.
    var photo: PhotoRef? = nil

    var id: String { invite }
}

/// The §7.2 record, exactly: every field but `pending` is recoverable from Telegram (§11.4.9).
struct PrivateRecord: Codable, Equatable {
    var v: Int = 1
    var privateNode: PrivateNodeRef?
    var privateFeeds: [PrivateFeedRef] = []
    var pending: [PendingRequest] = []

    init(v: Int = 1, privateNode: PrivateNodeRef? = nil, privateFeeds: [PrivateFeedRef] = [], pending: [PendingRequest] = []) {
        self.v = v; self.privateNode = privateNode; self.privateFeeds = privateFeeds; self.pending = pending
    }

    /// Every field defaulted, on §7.1's terms: a record written by a later build still yields what
    /// it does carry.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = ((try? c.decodeIfPresent(Int.self, forKey: .v)) ?? nil) ?? 1
        privateNode = (try? c.decodeIfPresent(PrivateNodeRef.self, forKey: .privateNode)) ?? nil
        privateFeeds = ((try? c.decodeIfPresent([PrivateFeedRef].self, forKey: .privateFeeds)) ?? nil) ?? []
        pending = ((try? c.decodeIfPresent([PendingRequest].self, forKey: .pending)) ?? nil) ?? []
    }

    var isEmpty: Bool { privateNode == nil && privateFeeds.isEmpty && pending.isEmpty }

    /// Adds or replaces the pending entry for a link — one entry per canonical link (§7.2).
    mutating func recordPending(invite: String, title: String, photo: PhotoRef?, at date: Date = Date()) {
        pending.removeAll { $0.invite == invite }
        pending.append(PendingRequest(invite: invite, title: title, askedAt: Moderation.iso8601(date), photo: photo))
    }

    mutating func clearPending(invite: String) {
        pending.removeAll { $0.invite == invite }
    }
}

/// A private node I am an approved member of (PROTOCOL §11.1 "private follow"), as the client
/// recovers it from its own chat list (§11.4.9). Never written to any card, by either side.
struct PrivateFollow: Codable, Equatable, Identifiable {
    var chatId: Int64
    var supergroupId: Int64
    var title: String
    var photo: PhotoRef?
    var pinnedMessageId: Int64
    /// The private card as read — the claim (§11.3).
    var card: PrivateCard
    /// §11.3's check, and nothing softer: the public card of `card.node` names `supergroupId`.
    var verified: Bool
    /// The owner's private feeds I am also a member of, resolved through their invite links.
    var feeds: [PrivateFollowFeed] = []

    var id: Int64 { chatId }
    var sourceKey: String { PrivateLink.sourceKey(supergroupId: supergroupId) }
    /// The node the posts are attributed to — only when verified (§11.5). Unverified posts are
    /// the channel's, and the channel's alone.
    var attributedNode: String? { verified ? card.node : nil }
}

/// A private feed of someone I follow privately, which I am also a member of.
struct PrivateFollowFeed: Codable, Equatable, Identifiable {
    var chatId: Int64
    var supergroupId: Int64
    var title: String
    var photo: PhotoRef?
    var invite: String

    var id: Int64 { chatId }
}

/// One pending join request on a channel I own (§11.4.5), as Telegram describes the requester.
/// `guessedNode` is §4.3's naming convention resolved, labelled a guess and never a fact
/// (PRODUCT §2.30).
struct JoinRequest: Equatable, Identifiable {
    var chatId: Int64
    var chatTitle: String
    var userId: Int64
    var name: String
    var username: String?
    var bio: String
    var date: Int
    var photo: PhotoRef?
    var guessedNode: String?
    /// Handed back to `getChatJoinRequests` as the paging offset.
    var raw: JoinRequestRaw

    var id: String { "\(chatId):\(userId)" }
}

/// The three fields of TDLib's `chatJoinRequest`, kept so paging can pass the last one back.
struct JoinRequestRaw: Equatable {
    var userId: Int64
    var date: Int
    var bio: String
}

/// One member of a channel I own (§11.4.10), as Telegram knows them: name, username, join date.
struct PrivateMember: Equatable, Identifiable {
    var userId: Int64
    var name: String
    var username: String?
    var joinedDate: Int
    var photo: PhotoRef?
    var isMe: Bool

    var id: Int64 { userId }
}

/// What `checkChatInviteLink` shows a non-member (§11.4.6 step 2): title, photo, member count, and
/// whether this is a join-approval link at all.
struct InvitePreview: Equatable {
    var invite: String
    var title: String
    var photo: PhotoRef?
    var memberCount: Int
    var isPublic: Bool
    var createsJoinRequest: Bool
    /// Non-zero when the reader already has access — a member, or a link that needs no approval.
    var chatId: Int64
}

/// How `joinChatByInviteLink` answered (§11.4.6 step 3).
enum AskResult: Equatable {
    /// `chatJoinResultRequestSent` — the normal case; recorded as pending.
    case requestSent
    /// `chatJoinResultSuccess` — a link that needed no approval; the reader is in.
    case joined(chatId: Int64)
    /// A guard bot, which nothing in §11 creates. The client stops here.
    case needsBot
}

/// One source for the feed merge (§4.8 as extended by §11.5): a private channel and the node its
/// posts are attributed to, or nil when the card is unverified — or when there is no card, which
/// is my own private feed, attributed to me.
struct PrivateSource: Equatable {
    var info: FeedInfo
    var owner: String?
    var isMine: Bool
    /// A feed reached through a link on somebody's private card rather than by a card of its own.
    /// §11.3 attributes a channel by ITS card; a listing never overrides that — a listed link can
    /// open onto another person's private node, and the merge keeps the node's own entry for the
    /// key (`FeedRepository.resolveSources`).
    var isListed: Bool = false
}
