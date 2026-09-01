// Screens — Thread (PRODUCT.md §2.12, PROTOCOL.md §6): the post at the top, then the indented
// reply tree from the comment index, the comment composer, and delete-own-comment. Comments are
// network-scoped by design: what you see is comments from your network.
//
// The thread is split into three pieces so the carousel (§2.12 "Comments in the carousel") can host
// the same ones over the media instead of growing a second implementation:
//
//   `CommentTree`       the flattening rule — pure, no views, no model.
//   `CommentThreadList` the section mark, the tree, the reply quote line and the composer's action.
//   `CommentComposerModal` the composer itself, opened against a `CommentTargeting`.
//
// Reply-target selection lives in `AppModel.replySelection` rather than in either host, because it
// is one selection: the same tap has to mean the same thing on the Thread screen and in the
// carousel, and the composer has to read it from wherever it was made.

import PhotosUI
import SwiftUI

/// The `re:` chain (PROTOCOL §6.2) flattened for rendering: depth capped at 5, deeper replies shown
/// flat. Pure, so `CommentThreadTests` can state the shape of a tree without a screen.
enum CommentTree {
    static func rows(comments: [Comment], roots: [String]) -> [(comment: Comment, depth: Int)] {
        let rootKeys = Set(roots.compactMap(CommentCodec.targetKey))
        var out: [(Comment, Int)] = []
        var seen = Set<String>()
        func walk(_ c: Comment, depth: Int) {
            guard seen.insert(c.id).inserted else { return }
            out.append((c, min(depth, CommentCodec.maxDepth - 1)))
            guard let key = CommentCodec.targetKey(c.link) else { return }
            for child in comments where child.targetKey == key { walk(child, depth: depth + 1) }
        }
        for c in comments where c.targetKey.map(rootKeys.contains) ?? false { walk(c, depth: 0) }
        // Anything whose parent never rendered (deleted, out of scan range) shows flat at the top level.
        for c in comments { walk(c, depth: 0) }
        return out.map { (comment: $0.0, depth: $0.1) }
    }

    static func replyCount(of comment: Comment, in comments: [Comment]) -> Int {
        guard let key = CommentCodec.targetKey(comment.link) else { return 0 }
        return comments.filter { $0.targetKey == key }.count
    }
}

struct ThreadScreen: View {
    @Environment(AppModel.self) private var model
    let post: Post

    var body: some View {
        Screen(back: true, refresh: { await model.refreshComments(for: post) }) {
            PostCard(post: post, inThread: true) { username in
                model.path.append(.feedChannel(username: username))
            }
            CommentThreadList(post: post, roots: model.commentTargets(for: post))
        }
        // §6.3: the thread refreshes its comment index for the visible target when opened,
        // deepening the scan of channels that have not yet reached this post's date.
        .task(id: post.id) { await model.refreshComments(for: post) }
        // A selection belongs to the thread it was made in; leaving takes it with you.
        .onDisappear { model.clearReply() }
    }
}

/// The thread body: `COMMENTS · n`, the tree, the reply quote line, and the gold action. Shared by
/// the Thread screen and by the carousel's comment sheet (§2.12) — the carousel just hosts it over
/// the media.
struct CommentThreadList: View {
    @Environment(AppModel.self) private var model
    let post: Post
    /// The links this thread is about: every album item on the Thread screen, and just the item the
    /// carousel is showing when the carousel hosts it.
    let roots: [String]

    private var thread: [Comment] { model.threadComments(targets: roots) }
    private var rows: [(comment: Comment, depth: Int)] { CommentTree.rows(comments: thread, roots: roots) }

    var body: some View {
        HPSectionMark("Comments", count: thread.count)
        if rows.isEmpty {
            HPMuted("No comments from your network yet.")
                .padding(.bottom, HPTokens.Space.cardGap)
        } else {
            HPListCard {
                ForEach(Array(rows.enumerated()), id: \.element.comment.id) { i, row in
                    CommentRow(comment: row.comment, depth: row.depth,
                               replyCount: CommentTree.replyCount(of: row.comment, in: thread),
                               isLast: i == rows.count - 1,
                               isSelected: model.replySelection?.id == row.comment.id,
                               onSelect: { model.selectReply(row.comment) },
                               onReply: { model.startReply(to: row.comment, on: post) })
                }
            }
        }
        // §2.12: the selected comment "lifts into a quoted line above the composer".
        ReplyQuoteBar(target: model.replySelection.map {
            CommentTarget(link: $0.link, quoteTitle: $0.ownerTitle, quoteText: $0.body)
        }, onClear: { model.clearReply() })
        HPButton("Comment", style: .primary) {
            model.startComment(on: post, itemLink: roots.first)
        }
        .padding(.top, HPTokens.Space.rowGap)
    }
}

/// The selected reply target, quoted above the composer's action, with the × that clears it
/// (PRODUCT §2.12). Nothing when the reply goes to the post.
///
/// It takes the target and the clear action rather than reading `AppModel`, so `ReplyTargetRegionTests`
/// can measure the shipped bar against the shipped `Comment` button underneath it.
struct ReplyQuoteBar: View {
    let target: CommentTarget?
    let onClear: () -> Void
    /// Reported under `hpMeasureTouchTargets` so the assembled-thread test can name the regions.
    static let quoteRegion = "reply quote"
    static let clearRegion = "clear reply"

    var body: some View {
        if let target {
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                HPMonoSmall(target.quoteLine)
                    .lineLimit(2)
                Spacer(minLength: HPTokens.Space.rowGap)
                Button(action: onClear) {
                    Text("\u{00D7}")
                        .hpStyle(HPType.totals, color: HPTokens.Colors.muted)
                        .hpTouchTarget()
                        .hpTouchRegion(Self.clearRegion)
                }
                .buttonStyle(HPPressStyle())
                .accessibilityLabel("Clear reply target")
            }
            .padding(.horizontal, HPTokens.Space.rowPad)
            .padding(.vertical, HPTokens.Space.pillY)
            .background(RoundedRectangle(cornerRadius: HPTokens.Radius.input, style: .continuous)
                .fill(HPTokens.Colors.accentSoft))
            .hpTouchRegion(Self.quoteRegion)
            .padding(.top, HPTokens.Space.rowGap)
            .animation(HPMotion.color, value: target)
        }
    }
}

/// One comment in the tree. Replies indent one level (12pt) behind a hairline gutter. Tapping the
/// row selects it as the reply target (§2.12); tapping it again clears it.
struct CommentRow: View {
    @Environment(AppModel.self) private var model
    let comment: Comment
    let depth: Int
    let replyCount: Int
    let isLast: Bool
    var isSelected: Bool = false
    var onSelect: (() -> Void)?
    var onReply: (() -> Void)?

    static let indent: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(HPTokens.Colors.line)
                    .frame(width: HPTokens.borderWidth)
                    .padding(.trailing, Self.indent - HPTokens.borderWidth)
            }
            content
        }
        .padding(.vertical, HPTokens.Space.rowPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? HPTokens.Colors.accentSoft : .clear)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(HPTokens.Colors.line).frame(height: HPTokens.borderWidth) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onLongPressGesture {
            guard comment.isMine, !comment.isPending else { return }
            model.modal = .deleteComment(comment)
        }
        .animation(HPMotion.color, value: isSelected)
        .accessibilityAction(named: isSelected ? "Clear reply target" : "Reply to \(comment.ownerTitle)") {
            onSelect?()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: same row as a post card. Avatar and name open the commenter's profile.
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                Button { model.path.append(.profile(username: comment.ownerUsername)) } label: {
                    HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                        NodeAvatar(photo: comment.ownerPhoto, size: HPTokens.Space.avatarRow,
                                   initial: String(comment.ownerTitle.prefix(1)))
                        HPBody(comment.ownerTitle, strong: true).lineLimit(1)
                        if comment.isPlusOne { HPPill("+1", tone: .neutral) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(comment.ownerTitle)")
                Spacer(minLength: HPTokens.Space.rowGap)
                HPMonoSmall(PostTime.format(unix: comment.date), color: HPTokens.Colors.faint)
            }
            if !comment.body.isEmpty {
                HPBody(comment.body)
                    .padding(.top, HPTokens.Space.tabsPad)
            }
            PostMediaList(ownerId: comment.id, media: comment.media, caption: comment.body)
            HStack(alignment: .center, spacing: HPTokens.Space.pillX) {
                if comment.isPending {
                    HPMonoSmall("Posting\u{2026}", color: HPTokens.Colors.faint)
                } else {
                    if replyCount > 0 {
                        HPMonoSmall("\(replyCount) repl\(replyCount == 1 ? "y" : "ies")", color: HPTokens.Colors.faint)
                    }
                    if let onReply {
                        HPButton("Reply", style: .ghost, size: .small, action: onReply)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// The comment composer (PRODUCT §2.12): the Compose card with a muted quote line of the target.
/// The first comment ever shows the comments-channel card first.
///
/// It takes a `CommentTargeting` and not a target, so the quote's × can drop the reply here — the
/// composer stays open, the placeholder goes back to `Say it.`, and the `re:` line is rewritten
/// from the post's link, all without reopening anything.
struct CommentComposerModal: View {
    @Environment(AppModel.self) private var model
    let targeting: CommentTargeting
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoPath: String?
    @State private var posting = false
    /// Cleared in place by the quote's ×; starts from whatever was selected when this opened.
    @State private var replyCleared = false

    // Channel creation (first comment ever).
    @State private var channelName = ""
    @State private var check: NodeRepository.UsernameCheck?
    @State private var checking = false
    @State private var creating = false
    @State private var checkTask: Task<Void, Never>?

    private var needsChannel: Bool { model.myCard?.replies == nil }

    /// What the comment will point at right now — and the only thing the `re:` line is written from.
    private var live: CommentTargeting {
        replyCleared ? CommentTargeting(post: targeting.post) : targeting
    }
    private var target: CommentTarget { live.active }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if needsChannel { channelCard } else { composer }
        }
        .onAppear {
            if channelName.isEmpty { channelName = model.suggestedRepliesUsername }
            if needsChannel { scheduleCheck() }
        }
        .onChange(of: channelName) { _, _ in if needsChannel { scheduleCheck() } }
    }

    // MARK: First comment ever — make the comments channel (§6.1, §6.4)

    private var channelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Your comments channel")
            HPMuted("Your comments live in a public channel you own. Anyone can read it on Telegram; you can edit or delete anything there.")
                .padding(.bottom, HPTokens.Space.cardPad)
            HStack(alignment: .bottom, spacing: HPTokens.Space.rowGap) {
                HPTextField(nil, text: $channelName, placeholder: model.suggestedRepliesUsername, kind: .text)
                availabilityPill.padding(.bottom, HPTokens.Space.inputBottom + HPTokens.Space.inputY)
            }
            HPButtonRow {
                HPButton("Make Channel", style: .primary, enabled: !creating && check == .available) {
                    guard !creating, let name = Username.normalise(channelName) else { return }
                    creating = true
                    Task {
                        _ = await model.makeCommentsChannel(username: name)
                        creating = false
                    }
                }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }

    @ViewBuilder private var availabilityPill: some View {
        switch check {
        case .available: HPPill("Available", tone: .gold)
        case .taken: HPPill("Taken", tone: .bad)
        case .invalid: HPPill("Invalid", tone: .bad)
        case .tooMany: HPPill("Too many", tone: .bad)
        case .unavailable: HPPill("Unavailable", tone: .bad)
        case nil: if checking { HPPill("Checking") }
        }
    }

    private func scheduleCheck() {
        checkTask?.cancel()
        check = nil
        guard let name = Username.normalise(channelName) else { check = channelName.isEmpty ? nil : .invalid; return }
        checking = true
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            var result = try? await model.nodes.checkUsername(name)
            // A channel I already own (left over from an attempt whose card write failed) is not
            // Taken: Make Channel stays enabled and proceeds straight to the card write.
            if result == .taken, await model.nodes.ownedPublicChannel(username: name) != nil {
                result = .available
            }
            guard !Task.isCancelled else { return }
            check = result
            checking = false
        }
    }

    // MARK: The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                HPMuted(target.quoteLine)
                    .lineLimit(2)
                if live.isReply {
                    Spacer(minLength: HPTokens.Space.rowGap)
                    Button {
                        replyCleared = true
                        model.clearReply()
                    } label: {
                        Text("\u{00D7}")
                            .hpStyle(HPType.totals, color: HPTokens.Colors.muted)
                            .hpTouchTarget()
                    }
                    .buttonStyle(HPPressStyle())
                    .accessibilityLabel("Clear reply target")
                }
            }
            .padding(.bottom, HPTokens.Space.rowPad)
            HPTextField(nil, text: $text, placeholder: live.placeholder, kind: .multiline(rows: HPMetric.composeRows))
            HStack(spacing: HPTokens.Space.rowGap) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text(photoPath == nil ? "Add Photo" : "Photo added")
                        .hpStyle(HPType.buttonSm, color: HPTokens.Colors.muted)
                        .padding(.vertical, HPTokens.Space.buttonSmY)
                        .padding(.horizontal, HPTokens.Space.buttonSmX)
                        .frame(minHeight: HPTokens.Space.touchMin)
                        .contentShape(Capsule())
                }
                .buttonStyle(HPPressStyle())
                .accessibilityLabel("Add Photo")
                if photoPath != nil {
                    HPButton("Remove", style: .ghost, size: .small) { photoPath = nil; pickerItem = nil }
                }
            }
            .padding(.bottom, HPTokens.Space.rowGap)
            HPButtonRow {
                HPButton("Post", style: .primary, enabled: canPost) { submit() }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
        .animation(HPMotion.color, value: replyCleared)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tgsocial-\(UUID().uuidString).jpg")
                // Off the main actor: a picked photo is full sensor resolution, so decoding it and
                // re-encoding to JPEG is tens of MB and hundreds of milliseconds of main-thread stall.
                await Task.detached(priority: .userInitiated) {
                    if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                        try? jpeg.write(to: url)
                    } else {
                        try? data.write(to: url)
                    }
                }.value
                photoPath = url.path
            }
        }
    }

    private var canPost: Bool {
        !posting && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoPath != nil)
    }

    private func submit() {
        guard canPost else { return }
        posting = true
        // Optimistic (PRODUCT §2.12): the modal closes as the pending comment appears in the thread.
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = photoPath
        let sendTo = target
        model.modal = nil
        model.clearReply()
        Task { _ = await model.postComment(text: body, photoPath: photo, target: sendTo) }
        posting = false
    }
}

struct DeleteCommentModal: View {
    @Environment(AppModel.self) private var model
    let comment: Comment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPH2("Delete this comment?")
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Delete", style: .danger) { Task { await model.deleteComment(comment) } }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}
