// Screens — the work surface (PRODUCT.md §2.23–§2.25, PROTOCOL.md §10).
//
// Work is a LAYER on the network, not a second network: no fifth tab, no separate sign-in, no
// parallel profile. A person who never fills a work key never sees any of it, and their profile
// looks exactly as it does today — the UI is additive because the protocol is, and every view here
// is absent rather than empty when the node carries no work keys.
//
// `Verified` appears nowhere below. It means one checkable thing (a feed backlink, PROTOCOL §3) and
// nothing on a work card is checkable (§10.8).

import SwiftUI

// MARK: - The work card on a profile (§2.23)

/// Absent entirely when the node has no work keys — no empty section, no "not set up yet", nothing.
struct WorkCardSection: View {
    @Environment(AppModel.self) private var model
    let node: NodeInfo

    private var work: Work? { model.work(of: node.username) }

    var body: some View {
        if let work {
            let rows = model.workTagRows(for: node.username)
            VStack(alignment: .leading, spacing: 0) {
                HPSectionMark("Work")
                // The role is body text, undecorated. It is a self-claim exactly like the bio two
                // lines above it, and it must not borrow the visual language of the `Verified`
                // pill (§10.8) — no pill, no tick, no badge.
                if let role = work.role, !role.isEmpty { HPBody(role) }
                intent
                if !rows.claimed.isEmpty {
                    tagCard(rows.claimed).padding(.top, HPTokens.Space.rowGap)
                }
                emptyNote(rows)
                if !rows.unclaimed.isEmpty {
                    // §10.4: a vouch's tag need not appear in the subject's `work.does`, because the
                    // subject must not be able to edit somebody else's sentence by editing their own
                    // card. This heading is how a person finds out what they are known for.
                    HPSectionMark("Vouched, not claimed").padding(.top, HPTokens.Space.cardPad)
                    tagCard(rows.unclaimed)
                }
                if !model.isMe(node.username), !model.isBlocked(node.username) {
                    HPButton("Vouch for \(firstName)", style: .neutral, size: .small) {
                        model.modal = .vouch(node: node.username)
                    }
                    .padding(.top, HPTokens.Space.rowPad)
                }
            }
            .padding(.bottom, HPTokens.Space.cardGap)
        }
    }

    /// The one gold thing in this card, and only while the intent is current (§10.3). Expired or
    /// over the horizon, the pill and the date are simply not drawn — not greyed, not "was open
    /// until".
    @ViewBuilder private var intent: some View {
        if let open = model.currentOpen(of: node.username) {
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                HPPill(open.intent.label, tone: .gold)
                if let until = WorkDate.short(open.until) {
                    HPMonoSmall("until " + until, color: HPTokens.Colors.faint)
                }
            }
            .padding(.top, HPTokens.Space.rowGap)
            .accessibilityElement(children: .combine)
        }
    }

    private func tagCard(_ rows: [WorkTagRow]) -> some View {
        HPListCard {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                WorkTagRowView(node: node, row: row, isLast: i == rows.count - 1)
            }
        }
    }

    /// §2.23's two empty states. The second line of the second one is uncomfortable and it is true
    /// (§10.5): a client that omits it implies a completeness it does not have.
    @ViewBuilder private func emptyNote(_ rows: (claimed: [WorkTagRow], unclaimed: [WorkTagRow])) -> some View {
        let anyVouches = rows.claimed.contains { $0.count > 0 } || !rows.unclaimed.isEmpty
        if !rows.claimed.isEmpty, !anyVouches {
            VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                if model.isMe(node.username) {
                    HPMuted("No vouches from your network yet.")
                    HPSmall("Someone may have vouched for you outside it. You'd only see it if you can reach them.",
                            color: HPTokens.Colors.faint)
                } else {
                    HPMuted("No vouches from your network.")
                }
            }
            .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// The modal's label uses the subject's name, not a pronoun the app does not know (§2.25).
    private var firstName: String {
        node.displayName.split(separator: " ").first.map(String.init) ?? node.displayName
    }
}

/// One capability row. A row with vouches taps through; a row with none is not a control — no
/// chevron, no hit target, no press state (§2.23).
struct WorkTagRowView: View {
    @Environment(AppModel.self) private var model
    let node: NodeInfo
    let row: WorkTagRow
    let isLast: Bool

    var body: some View {
        HPListItem(isLast: isLast) {
            if row.count > 0 {
                Button { model.path.append(.vouches(node: node.username, tag: row.tag)) } label: {
                    HPBody(row.tag)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(row.tag). \(countLabel). Opens the vouches.")
            } else {
                HPBody(row.tag)
            }
        } trailing: {
            if row.count > 0 {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    // §10.5: a figure is allowed only when the reader can resolve it into names in
                    // one step and it is labelled with its scope. `Vouched by 2` describes what
                    // THIS reader can see; `2 endorsements` would be a claim about a world that
                    // does not exist here.
                    HPSmall(countLabel)
                    Text("\u{203A}").hpStyle(HPType.h2, color: HPTokens.Colors.faint)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var countLabel: String { "Vouched by \(row.count)" }
}

// MARK: - The vouches screen (§2.25)

struct VouchesScreen: View {
    @Environment(AppModel.self) private var model
    let node: String
    let tag: String

    var body: some View {
        Screen(back: true, refresh: { await model.refreshComments() }) {
            let vouches = model.vouches(for: node, tag: tag)
            // The tag as written, then who it is about.
            HPH1(tag)
            HPMono(model.node(node)?.displayName ?? "@" + node)
                .padding(.bottom, HPTokens.Space.cardGap)
            if vouches.isEmpty {
                EmptyCard("No vouches from your network.",
                          message: "You see vouches written by people you can reach \u{2014} you, who you follow, and theirs.")
            } else {
                HPSectionMark("Vouches", count: vouches.count)
                HPListCard {
                    ForEach(Array(vouches.enumerated()), id: \.element.id) { i, vouch in
                        VouchRow(vouch: vouch, isLast: i == vouches.count - 1)
                    }
                }
                HPSmall("Vouches from your network \u{2014} you, who you follow, and theirs.",
                        color: HPTokens.Colors.faint)
                    .padding(.top, HPTokens.Space.rowGap)
            }
        }
        .task { await model.refreshComments() }
    }
}

struct VouchRow: View {
    @Environment(AppModel.self) private var model
    let vouch: Vouch
    let isLast: Bool

    var body: some View {
        HPListItem(isLast: isLast) {
            VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    Button { model.path.append(.profile(username: vouch.ownerUsername)) } label: {
                        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                            NodeAvatar(photo: vouch.ownerPhoto, size: HPTokens.Space.avatarRow,
                                       initial: String(vouch.ownerTitle.prefix(1)))
                            HPBody(vouch.ownerTitle, strong: true).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(vouch.ownerTitle)")
                    if vouch.isPlusOne { HPPill("+1", tone: .neutral) }
                    Spacer(minLength: HPTokens.Space.rowGap)
                    // §2.25: a month and a year, not a relative time. Everywhere else in this app
                    // time is relative because a post's recency is what matters; a vouch is the
                    // opposite, and `2y ago` buries what the reader is weighing.
                    HPMonoSmall(vouch.isPending ? "Posting\u{2026}" : WorkDate.monthYear(unix: vouch.date),
                                color: HPTokens.Colors.faint)
                }
                if !vouch.body.isEmpty { HPBody(vouch.body) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onLongPressGesture {
                guard !vouch.isPending else { return }
                model.modal = .vouchSheet(vouch)
            }
        }
    }
}

/// §2.25: §2.12's comment sheet with two strings changed — `Feed` names the voucher's comments
/// channel, and `SAFETY` reads `Report Vouch` and `Block @tgs_bob`. No `Mute`: mute is about a
/// channel's posts and a vouch is not one.
///
/// On my own work card it also carries the line that is the honest cost of the guarantee: a vouch
/// someone wrote about me is in THEIR channel and I cannot reach it (PROTOCOL §10.4). It belongs
/// here rather than on the screen because this is where the question gets asked — the person
/// long-pressing looking for `Delete` finds the answer above the two controls it redirects them to.
struct VouchSheetModal: View {
    @Environment(AppModel.self) private var model
    let vouch: Vouch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Vouch")
            row("Posted", PostTime.exact(unix: vouch.date))
            row("From", "@" + vouch.ownerUsername)
            row("About", "@" + vouch.node)
            row("Channel", "@" + vouch.channelUsername, isLast: true)
            HPButton("Open in Telegram", style: .neutral) {
                model.modal = nil
                model.openInTelegram(vouch.link)
            }
            .padding(.top, HPTokens.Space.rowPad)
            if model.isMe(vouch.node), !vouch.isMine {
                HPMuted("You can't remove a vouch someone wrote. Report it or block them.")
                    .padding(.top, HPTokens.Space.cardPad)
            }
            SafetyBlock(primary: primary, block: blockRow, mute: nil)
            HPButton("Close", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    private var primary: (label: String, danger: Bool, run: () -> Void) {
        if vouch.isMine { return ("Delete", true, { model.modal = .deleteVouch(vouch) }) }
        let subject = ReportSubject(vouch: vouch)
        return (subject.buttonLabel, true, { model.modal = .report(subject) })
    }

    private var blockRow: (label: String, run: () -> Void)? {
        guard !model.isMe(vouch.ownerUsername) else { return nil }
        let username = vouch.ownerUsername
        return ("Block @\(username)", { model.modal = .block(username: username) })
    }

    private func row(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        HPListItem(isLast: isLast) {
            HPBody(label)
        } trailing: {
            HPMono(value, small: true)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("\(label): \(value)")
        }
    }
}

struct DeleteVouchModal: View {
    @Environment(AppModel.self) private var model
    let vouch: Vouch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPH2("Delete this vouch?")
            HPMuted("It disappears from your comments channel.")
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Delete", style: .danger) { Task { await model.deleteVouch(vouch) } }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}

// MARK: - Writing a vouch (§2.25)

/// One capability, one message. Both lines of §10.4 are mandatory, so this modal cannot post
/// without a tag — a bare "I vouch for this person" asserts nothing anyone can weigh.
struct VouchModal: View {
    @Environment(AppModel.self) private var model
    let node: String
    @State private var picked: String?
    @State private var custom = ""
    @State private var showCustom = false
    @State private var why = ""
    @State private var posting = false

    private var info: NodeInfo? { model.node(node) }
    /// The subject's first name, from the node's `name` — nil when the card carries none. `name:`
    /// is optional in PROTOCOL §2, so that is an ordinary card, and every sentence built from this
    /// has a second wording for it: the app knows no pronoun for anybody, and a username is not
    /// one either.
    private var name: String? {
        guard let info, let card = info.card, let n = card.name, !n.isEmpty else { return nil }
        return n.split(separator: " ").first.map(String.init) ?? n
    }
    /// The chips are the subject's own `work.does`, in card order, plus `Something else`. A node
    /// with no `work.does` shows only `Something else` with the input already revealed — you can
    /// vouch for someone who has claimed nothing.
    private var chips: [String] { model.work(of: node)?.does ?? [] }
    private var tag: String? { showCustom ? WorkCodec.tag(custom) : picked }
    /// §2.25's refusal, judged on the tag that would actually be POSTED. An already-vouched chip is
    /// inert, so the only route to a duplicate is `Something else` — and §10.4 expects vouches for
    /// tags the subject never claimed, which are exactly the ones with no chip to be inert. A guard
    /// that only reads the chip row leaves open the one path that needs guarding.
    private var duplicate: String? {
        guard let tag, model.hasVouched(node: node, tag: tag) else { return nil }
        return tag
    }
    /// What the faint line names: the refused tag, or — with nothing selected — the thing the inert
    /// `Vouched` chip is about. The chip says what happened; this says which one.
    private var alreadyVouched: String? { duplicate ?? chips.first { model.hasVouched(node: node, tag: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Vouch")
            // §2.25: reached by deep link on my own profile, the modal does not open.
            if model.isMe(node) {
                HPH2("You can't vouch for yourself.")
                HPButton("Close", style: .ghost) { model.modal = nil }
                    .padding(.top, HPTokens.Space.cardPad)
            } else if model.myCard?.replies == nil {
                // §2.25: it is the SAME channel §2.12 makes (§10.4), so it is the same card, not a
                // second one that says nearly the same thing.
                CommentsChannelCard()
            } else {
                composer
            }
        }
        .onAppear { showCustom = chips.isEmpty }
    }

    @ViewBuilder private var composer: some View {
        HPH2(name.map { "Say one thing \($0) does." } ?? "Say one thing they do.")
        HPMuted("This goes in your comments channel, under your name. \(name ?? "They") can't edit it or take it down.")
            .padding(.top, HPTokens.Space.rowGap)
            .padding(.bottom, HPTokens.Space.cardPad)
        HPFieldLabel(fieldLabel)
        chipRow
        if showCustom {
            HPTextField(nil, text: $custom, placeholder: "", kind: .text)
            if !custom.trimmingCharacters(in: .whitespaces).isEmpty, WorkCodec.tag(custom) == nil {
                HPSmall("Letters, numbers, spaces, and + # . - only.", color: HPTokens.Colors.faint)
                    .padding(.bottom, HPTokens.Space.rowGap)
            }
        }
        HPTextField(nil, text: $why, placeholder: "Why.", kind: .multiline(rows: 4))
        HPButtonRow {
            HPButton("Post Vouch", style: .primary, enabled: tag != nil && duplicate == nil && !posting) { post() }
        } b: {
            HPButton("Cancel", style: .ghost) { model.modal = nil }
        }
        VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
            if tag == nil, !showCustom || custom.trimmingCharacters(in: .whitespaces).isEmpty {
                HPSmall("Pick one thing.", color: HPTokens.Colors.faint)
            }
            if let already = alreadyVouched {
                HPSmall("You already vouched \(name ?? "them") for \(already).", color: HPTokens.Colors.faint)
            }
            HPSmall("People who follow you will see it, and the people who follow them.",
                    color: HPTokens.Colors.faint)
        }
        .padding(.top, HPTokens.Space.rowGap)
    }

    /// `WHAT ANA DOES`, from the node's `name`; `WHAT THEY DO` when the card has no name.
    private var fieldLabel: String { name.map { "What \($0) does" } ?? "What they do" }

    private var chipRow: some View {
        HPFlowRow(spacing: HPTokens.Space.rowGap) {
            ForEach(chips, id: \.self) { chip in
                let vouched = model.hasVouched(node: node, tag: chip)
                Button {
                    guard !vouched else { return }
                    picked = picked == chip ? nil : chip
                    showCustom = false
                } label: {
                    HPPill(vouched ? "Vouched" : chip, tone: picked == chip && !showCustom ? .gold : .neutral)
                        .hpTouchTarget()
                }
                .buttonStyle(.plain)
                .disabled(vouched)
                .opacity(vouched ? HPAlpha.disabled : 1)
                .accessibilityLabel(vouched ? "Already vouched for \(chip)" : chip)
                .accessibilityAddTraits(picked == chip && !showCustom ? [.isButton, .isSelected] : .isButton)
            }
            Button {
                showCustom = true
                picked = nil
            } label: {
                HPPill("Something else", tone: showCustom ? .gold : .neutral)
                    .hpTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Something else")
            .accessibilityAddTraits(showCustom ? [.isButton, .isSelected] : .isButton)
        }
        .padding(.bottom, HPTokens.Space.rowGap)
    }

    private func post() {
        guard let tag, duplicate == nil, !posting else { return }
        posting = true
        Task {
            if await model.postVouch(node: node, does: tag, body: why.trimmingCharacters(in: .whitespacesAndNewlines)) {
                model.modal = nil
            }
            posting = false
        }
    }
}

/// A wrapping row of pills. SwiftUI has no flow layout below iOS 16's `Layout`, and the chip set is
/// a subject's `work.does` — up to twelve tags of up to 24 characters, which will not fit one line.
struct HPFlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int]; var width: CGFloat; var height: CGFloat }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row(indices: [], width: 0, height: 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row(indices: [], width: 0, height: 0)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Work mode on Feed (§2.24)

/// `OPEN NOW`, then the work column. In this order, and the first is the reason the mode exists:
/// the work feed's distinguishing feature is not the filter, it is expiring intent.
struct WorkModeView: View {
    @Environment(AppModel.self) private var model
    let posts: [Post]
    /// False while Feed still has pages to read: an empty window of §4.8's merge is not the same
    /// claim as "your network has no work in it", and only one of the two is worth a screen.
    let showEmptyColumn: Bool
    let onOpenFeed: (String) -> Void

    var body: some View {
        let open = model.openNow
        HPSectionMark("Open now", count: open.isEmpty ? nil : open.count)
        if open.isEmpty {
            VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                HPCard { HPMuted("Nobody in your network is open right now.") }
                smallNetworkNote
            }
            .padding(.bottom, HPTokens.Space.cardGap)
        } else {
            VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                HPListCard {
                    ForEach(Array(open.enumerated()), id: \.element.id) { i, entry in
                        OpenNowRow(entry: entry, isLast: i == open.count - 1)
                    }
                }
                smallNetworkNote
            }
            .padding(.bottom, HPTokens.Space.cardGap)
        }

        if posts.isEmpty {
            if showEmptyColumn {
                EmptyCard("No work posts yet.",
                          message: "Mark one of your feeds as work, or follow someone who has.",
                          action: ("Edit Card", { model.modal = .editCard }))
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(posts) { post in
                    PostCard(post: post, onOpenFeed: onOpenFeed)
                }
            }
        }
    }

    /// §2.24: one more faint line when I follow fewer than five, because a thin `OPEN NOW` is more
    /// often a small network than a quiet one.
    @ViewBuilder private var smallNetworkNote: some View {
        if (model.myCard?.follows.count ?? 0) < 5 {
            HPSmall("Your network is small. This reads the people you follow, and theirs.",
                    color: HPTokens.Colors.faint)
        }
    }
}

struct OpenNowRow: View {
    @Environment(AppModel.self) private var model
    let entry: OpenNowEntry
    let isLast: Bool

    /// `until 1 Dec · live sound, swift` — the date derived (§2.23), then the first three tags. One
    /// line, not two: they are the same sentence, and a wrap between them reads as two facts.
    private var subline: String {
        var parts: [String] = []
        if let until = WorkDate.short(entry.open.until) { parts.append("until " + until) }
        if !entry.does.isEmpty { parts.append(entry.does.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        HPListItem(isLast: isLast) {
            Button { model.path.append(.profile(username: entry.node.username)) } label: {
                // Two candidates, and the reason is that BOTH halves of this row are unelidable
                // for different reasons: the intent pill's four strings are copy (§2.23) and the
                // name is the row's subject. On a narrow phone `Open to collaborate` plus a `+1`
                // leaves a long name nothing at all, so the row drops the pills to a second line
                // rather than truncating either into meaninglessness.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                        identity
                        Spacer(minLength: HPTokens.Space.rowGap)
                        intentPills
                        chevron
                    }
                    VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                        // The chevron stays on the row's right edge either way — dropped under the
                        // pills it would read as a control on the pill rather than on the row.
                        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                            identity
                            Spacer(minLength: HPTokens.Space.rowGap)
                            chevron
                        }
                        intentPills.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.node.displayName). \(entry.open.intent.label). \(subline).")
        }
    }

    private var identity: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            NodeAvatar(photo: entry.node.photo, size: HPTokens.Space.avatarRow, initial: entry.node.initial)
            VStack(alignment: .leading, spacing: 0) {
                HPBody(entry.node.displayName, strong: true).lineLimit(1)
                HPMonoSmall(subline, color: HPTokens.Colors.faint).lineLimit(1)
            }
        }
    }

    /// The intent pill is the one gold thing in this row, and its four strings are copy (§2.23):
    /// it never elides, which is why the row has a second candidate above.
    private var intentPills: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            HPPill(entry.open.intent.label, tone: .gold)
            if entry.isPlusOne { HPPill("+1", tone: .neutral) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var chevron: some View {
        Text("\u{203A}").hpStyle(HPType.h2, color: HPTokens.Colors.faint)
            .accessibilityHidden(true)
    }
}
