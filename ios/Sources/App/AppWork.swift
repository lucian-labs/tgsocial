// App — the work surface (PRODUCT.md §2.23–§2.25, PROTOCOL.md §10).
//
// Every derivation here reads the cards the app already fetched. There is no new fetch, no index,
// no directory and no server — that is §10's third checkable property, and the shape of this file
// is what makes it checkable: nothing below calls TDLib.

import Foundation
import SwiftUI

/// Feed's two modes (PRODUCT §2.24). A mode, not a tab: a tab would say there are two networks and
/// there is one — the same nodes, the same follows, the same cards, read two ways.
enum FeedMode: String, Codable, CaseIterable, Hashable {
    case all, work

    var label: String {
        switch self {
        case .all: return "All"
        case .work: return "Work"
        }
    }
}

/// One row of `OPEN NOW` (PRODUCT §2.24).
struct OpenNowEntry: Identifiable, Equatable {
    var node: NodeInfo
    var open: WorkOpen
    var does: [String]
    /// Reached at +1 rather than through a follow. Included here and nowhere else in Work mode:
    /// intent is a small structured line on a card the client already fetched for Explore and
    /// Graph, so one more hop is free, while walking +1 feed history is a fetch per channel.
    var isPlusOne: Bool
    var isMine: Bool

    var id: String { node.id }
}

/// One `WHAT THEY DO` row (PRODUCT §2.24), drawn there as
/// `@tgs_ana · live sound · Followed by 3 of yours`. `hits` is the middle term and it is the whole
/// reason the section is not `NEARBY` with a different heading: a list of people with no capability
/// on it does not say why any of them is in it.
struct CapabilityMatch: Identifiable, Equatable {
    var node: NodeInfo
    /// The node's own `work.does` entries the query matched, in card order.
    var hits: [String]
    var followedByCount: Int
    var id: String { node.id }
}

/// One tag row on a work card (PRODUCT §2.23). `claimed` separates the node's own `work.does` from
/// the tags only somebody else has named — which is how a person finds out what they are known for.
struct WorkTagRow: Identifiable, Equatable {
    var tag: String
    var count: Int
    var claimed: Bool
    var id: String { tag }
}

/// What `saveCard` did, so the modal can say it in §2.23's words rather than inventing a wording.
enum WorkSaveResult: Equatable {
    case saved
    case refused(String)
    /// Saved, but the write dropped something the writer typed. Each string is a §2.23 refusal.
    case savedWithNotes([String])
}

extension AppModel {

    // MARK: Reading work off cards (§10.2)

    /// A node's work card — mine from `myWork`, anyone else's from the card this app already read.
    /// Nil is the ordinary answer: every card written before §10 existed has none.
    func work(of username: String) -> Work? {
        if isMe(username) { return myWork }
        return node(username)?.work
    }

    /// Today, UTC — the one clock every §10.3 expiry check reads. Taken once per render rather than
    /// per row so a list cannot straddle midnight halfway down.
    var workToday: String { WorkCodec.today() }

    /// A node's intent, but only while it is a statement about now (§10.3). Expired or past the
    /// 180-day horizon it is simply not there — not greyed, not "was open until".
    func currentOpen(of username: String) -> WorkOpen? {
        guard let open = work(of: username)?.open, WorkCodec.isCurrent(open, today: workToday) else { return nil }
        return open
    }

    // MARK: The mode control (§2.24)

    /// §2.24: "The control appears only when at least one node in my `follows:`, or I, carry a
    /// `work.feeds` entry." A reader whose network has no work in it sees Feed exactly as it is
    /// today — the surface is additive or it is not additive.
    var workModeAvailable: Bool {
        if !(myWork?.feeds.isEmpty ?? true) { return true }
        for username in myCard?.follows ?? [] where !(work(of: username)?.feeds.isEmpty ?? true) { return true }
        return false
    }

    /// The channels me and my follows marked as work, as comparison keys. Not my +1's: §2.24 admits
    /// +1 to `OPEN NOW` and to nothing else.
    var workFeedKeys: Set<String> {
        var keys = Set<String>()
        for feed in myWork?.feeds ?? [] { keys.insert(Username.key(feed)) }
        for username in myCard?.follows ?? [] {
            for feed in work(of: username)?.feeds ?? [] { keys.insert(Username.key(feed)) }
        }
        return keys
    }

    /// The work column (§2.24): §4.8's merge unchanged, §2.3's post card unchanged, filtered to the
    /// feeds their owners marked as work. That filter is the entire feature — no scoring, no
    /// promotion, no "relevant to you" — and it is why a client that never heard of §10 still shows
    /// every one of these posts, in All, correctly attributed, today.
    var workPosts: [Post] {
        let keys = workFeedKeys
        guard !keys.isEmpty else { return [] }
        return visiblePosts.filter { keys.contains($0.sourceKey) }
    }

    /// The mode Feed actually paints in, which is not always the one stored.
    ///
    /// §2.24: "the control is visible in both modes, so it is never a state someone is stuck in."
    /// The stored mode outlives the network that justified it — unfollow the last node carrying
    /// `work.feeds`, or cold-launch before their card is read, and `workModeAvailable` goes false
    /// while the preference still says `.work`. Painting the work column with no control on screen
    /// would be exactly the trap that sentence forbids, so availability decides what is rendered.
    /// The preference itself is kept rather than cleared: a network that regains a work feed puts
    /// the reader back where they were.
    var renderedFeedMode: FeedMode { workModeAvailable ? feedMode : .all }

    /// Feed's list for the current mode. One property, so the two modes cannot drift apart in what
    /// they filter for safety (§2.18), and so the fallback above cannot leave the list in one mode
    /// while the screen is in the other.
    var feedPosts: [Post] { renderedFeedMode == .work ? workPosts : visiblePosts }

    /// `OPEN NOW` (§2.24): current intent from me, my follows, and my +1, ordered by end date
    /// ascending — soonest first — ties broken by username ascending.
    ///
    /// The order is specified rather than left to each platform because "what expires first" is the
    /// only ranking this app has ever needed, and it is derived from the data rather than scored.
    var openNow: [OpenNowEntry] {
        let today = workToday
        var seen = Set<String>()
        var out: [OpenNowEntry] = []

        func add(_ info: NodeInfo?, work: Work?, isPlusOne: Bool, isMine: Bool) {
            guard let info, let work, let open = work.open else { return }
            guard WorkCodec.isCurrent(open, today: today) else { return }
            // §2.24: "a blocked node is absent from OPEN NOW … and leaves no gap and no residue."
            guard !isBlocked(info.username), seen.insert(info.key).inserted else { return }
            out.append(OpenNowEntry(node: info, open: open, does: work.does, isPlusOne: isPlusOne, isMine: isMine))
        }

        if let node = myNode { add(self.node(node.username) ?? myNodeInfo, work: myWork, isPlusOne: false, isMine: true) }
        for username in myCard?.follows ?? [] {
            add(node(username), work: work(of: username), isPlusOne: false, isMine: false)
        }
        for entry in nearby {
            add(entry.node, work: entry.node.work, isPlusOne: true, isMine: false)
        }
        return out.sorted {
            $0.open.until != $1.open.until
                ? $0.open.until < $1.open.until
                : Username.key($0.node.username) < Username.key($1.node.username)
        }
    }

    /// A `NodeInfo` for me when the node cache has not got one yet — the first launch after a
    /// setup, where my own intent should still be the first row of my own `OPEN NOW`.
    var myNodeInfo: NodeInfo? {
        guard let node = myNode else { return nil }
        return NodeInfo(username: node.username, chatId: node.chatId,
                        title: myTitle, card: myCard, work: myWork, state: myCardState,
                        photo: myPhoto, fetchedAt: myCardFetchedAt ?? Date())
    }

    // MARK: Reading vouches (§10.5)

    /// Every vouch about a node that this reader's network wrote, newest first, through the safety
    /// filter. Network-scoped, and it says so wherever it is rendered: a node with two hundred
    /// vouches shows zero to a reader who follows nobody, and there is no reverse index anywhere
    /// that could say otherwise.
    func vouches(for username: String) -> [Vouch] {
        let found = demo.map { CommentRepository.vouches(for: username, in: $0.vouchIndex) }
            ?? comments.vouches(for: username)
        return moderation.lists.filtered(vouches: found)
    }

    func vouches(for username: String, tag: String) -> [Vouch] {
        let key = tag.lowercased()
        return vouches(for: username).filter { $0.tagKey == key }
    }

    /// The tag rows of a node's work card (§2.23): the tags they claim, in card order, then the
    /// tags only somebody else has named.
    ///
    /// §10.4: the tag does not have to appear in the subject's `work.does`, because a vouch is the
    /// voucher's sentence and the subject must not be able to edit it by editing their own card.
    /// So the unclaimed ones get their own heading rather than being dropped.
    func workTagRows(for username: String) -> (claimed: [WorkTagRow], unclaimed: [WorkTagRow]) {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for v in vouches(for: username) {
            if counts[v.tagKey] == nil { order.append(v.does) }
            counts[v.tagKey, default: 0] += 1
        }
        let claimedTags = work(of: username)?.does ?? []
        let claimedKeys = Set(claimedTags.map { $0.lowercased() })
        let claimed = claimedTags.map { WorkTagRow(tag: $0, count: counts[$0.lowercased()] ?? 0, claimed: true) }
        let unclaimed = order
            .filter { !claimedKeys.contains($0.lowercased()) }
            .map { WorkTagRow(tag: $0, count: counts[$0.lowercased()] ?? 0, claimed: false) }
        return (claimed, unclaimed)
    }

    /// §2.25: "Already vouched them for that thing" — the chip reads `Vouched` and is not
    /// selectable. A second identical vouch is noise, and the count it would inflate is not a count
    /// anyone should trust anyway.
    func hasVouched(node username: String, tag: String) -> Bool {
        let key = WorkCodec.tag(tag)?.lowercased() ?? tag.lowercased()
        return vouches(for: username).contains { $0.isMine && $0.tagKey == key }
    }

    // MARK: Discovery by capability (§10.7)

    /// Explore's `WHAT THEY DO` (§2.24): a local filter over the cards this client has already
    /// read — my follows, my +1, and the directory. It is not search, and the screen says so in a
    /// permanent line rather than a footnote, because `searchPublicChats` indexes usernames and
    /// titles and will never return a node because of a tag inside its pinned message (§10.7.2).
    func capabilityMatches(_ query: String) -> [CapabilityMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= 2 else { return [] }
        var seen = Set<String>()
        var out: [CapabilityMatch] = []

        func consider(_ info: NodeInfo, followedBy: Int) {
            guard !isBlocked(info.username), !isMe(info.username) else { return }
            let hits = (info.work?.does ?? []).filter { $0.contains(needle) }
            guard !hits.isEmpty else { return }
            guard seen.insert(info.key).inserted else { return }
            out.append(CapabilityMatch(node: info, hits: hits, followedByCount: followedBy))
        }

        for username in myCard?.follows ?? [] {
            if let info = node(username) { consider(info, followedBy: 0) }
        }
        for entry in nearby { consider(entry.node, followedBy: entry.followedByCount) }
        for entry in directory { consider(entry.node, followedBy: entry.followedByCount) }
        return out.sorted { $0.node.displayName.lowercased() < $1.node.displayName.lowercased() }
    }

    // MARK: The expiry reminder (§2.23)

    /// `Your Open to contract ends in 3 days.` / `… has ended.` — the only nag in this section.
    /// Nil when there is nothing to say, which is the ordinary case.
    ///
    /// It reads `myWork.open` directly rather than `currentOpen`, because the whole point is the
    /// window where the reader-side rule has already dropped the intent and the writer has not
    /// noticed: a person who forgets is invisible without being told.
    var openExpiryNotice: String? {
        guard myNode != nil, myCardState == .ok, let open = myWork?.open else { return nil }
        guard let days = WorkCodec.daysBetween(workToday, open.until) else { return nil }
        if days < 0 { return "Your \(open.intent.label) has ended." }
        guard days <= 7 else { return nil }
        if days == 0 { return "Your \(open.intent.label) ends today." }
        return "Your \(open.intent.label) ends in \(days) day\(days == 1 ? "" : "s")."
    }

    /// What Edit Card's `FOR` control opens on (§2.23).
    ///
    /// A card carries `work.open`'s end DATE and never the horizon that minted it, so reopening the
    /// modal has to recover one. Defaulting to the first tab instead would be a control describing
    /// a date the card does not carry — and, because Save writes whatever it shows, an edit to the
    /// bio alone would move the expiry §10.3 makes every reader enforce.
    var editCardHorizon: Int {
        guard let until = myWork?.open?.until, let left = WorkCodec.daysBetween(workToday, until) else {
            return WorkCodec.openHorizons[0]
        }
        return WorkCodec.horizon(remainingDays: left)
    }

    // MARK: Writing the work card (§2.23)

    /// Saves Edit Card — both halves, in ONE card write. §2's fields and §10's lines live in the
    /// same pinned message, so writing them separately would be two `editMessageText` calls, two
    /// chances to fail, and a state where the bio landed and the work card did not.
    ///
    /// Returns what the write did in §2.23's own words: the caps and the grammar drop rather than
    /// refuse (§10.2), so a save can succeed and still have notes.
    ///
    /// `feeds` is intersected with the card's own `feeds:` before it is written, the same rule the
    /// parser applies on the way in — `feeds:` is the ownership claim, and a marking line has no
    /// business introducing a channel the owner never claimed.
    func saveCard(name: String, bio: String, link: String,
                  role: String, doesText: String, intent: WorkIntent?, horizonDays: Int,
                  feeds: [String]) async -> WorkSaveResult {
        guard var card = myCard ?? (myNode != nil ? Card() : nil) else {
            return .refused("Make your node first.")
        }
        card.name = name.isEmpty ? nil : name
        card.bio = bio.isEmpty ? nil : bio
        card.link = link.isEmpty ? nil : link
        var notes: [String] = []

        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRole.count > WorkCodec.roleMax { notes.append("Trimmed to 80.") }

        // Each typed tag is judged once, so the refusal can name the one that was dropped.
        var kept: [String] = []
        var seen = Set<String>()
        for raw in doesText.split(separator: ",", omittingEmptySubsequences: false) {
            let typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { continue }
            guard let tag = WorkCodec.tag(typed) else {
                notes.append("Dropped \"\(typed)\". Letters, numbers, spaces, and + # . - only.")
                continue
            }
            guard seen.insert(tag).inserted else { continue }
            kept.append(tag)
        }
        if kept.count > WorkCodec.doesMax {
            notes.append("Twelve at most. The rest were dropped.")
            kept = Array(kept.prefix(WorkCodec.doesMax))
        }

        var next = Work()
        next.role = WorkCodec.role(from: trimmedRole)
        next.does = kept
        if let intent, let until = WorkCodec.day(after: horizonDays) {
            next.open = WorkOpen(intent: intent, until: until)
        }
        next.feeds = feeds.filter { card.lists(feed: $0) }

        // `myWork` is set before the write because `writeCard` reads it — that is §10.6's round
        // trip, and it is also what makes this one write rather than two.
        let previous = myWork
        myWork = next.isEmpty ? nil : next
        if await writeCard(card) {
            store.save(myWork, LocalStore.myWork)
            return notes.isEmpty ? .saved : .savedWithNotes(notes)
        }
        myWork = previous
        // `writeCard` has already toasted the reason — offline, a newer card, a full card.
        return .refused("")
    }

    // MARK: Writing a vouch (§2.25)

    /// Posts one vouch into my comments channel. Optimistic in the subject's work card the same way
    /// a comment is, settling or rolling back.
    func postVouch(node username: String, does: String, body: String) async -> Bool {
        if refuseDemoWrite() { return false }
        guard let me = myNode else { showToast("Make your node first.", tone: .bad); return false }
        guard !isMe(username) else { showToast("You can't vouch for yourself.", tone: .bad); return false }
        guard let replies = myCard?.replies else { return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        do {
            try await activity.run("Posting") {
                try await self.perform {
                    try await self.comments.postVouch(
                        node: username, does: does, body: body, channelUsername: replies,
                        ownerUsername: me.username,
                        ownerTitle: (self.myCard?.name?.isEmpty == false ? self.myCard?.name : nil) ?? self.myTitle,
                        ownerPhoto: self.myPhoto)
                }
            }
            showToast("Vouched.", tone: .good)
            return true
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
    }

    /// Deletes my own vouch (§2.25). There is deliberately no path here for the SUBJECT: the
    /// message is in the voucher's channel, and that is the cost of the guarantee.
    func deleteVouch(_ vouch: Vouch) async {
        modal = nil
        if refuseDemoWrite() { return }
        if isOffline { showToast("You're offline.", tone: .bad); return }
        do {
            try await activity.run("Deleting your vouch") {
                try await self.perform { try await self.comments.delete(vouch) }
            }
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
        }
    }
}
