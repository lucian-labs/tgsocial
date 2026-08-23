// Screens — Thread (PRODUCT.md §2.12, PROTOCOL.md §6): the post at the top, then the indented
// reply tree from the comment index, the comment composer, and delete-own-comment. Comments are
// network-scoped by design: what you see is comments from your network.

import PhotosUI
import SwiftUI

struct ThreadScreen: View {
    @Environment(AppModel.self) private var model
    let post: Post

    private var thread: [Comment] { model.threadComments(for: post) }

    /// The tree, flattened for rendering: depth capped at 5, deeper replies shown flat (§6.2).
    private var rows: [(comment: Comment, depth: Int)] {
        let all = thread
        let rootKeys = Set(model.commentTargets(for: post).compactMap(CommentCodec.targetKey))
        var out: [(Comment, Int)] = []
        var seen = Set<String>()
        func walk(_ c: Comment, depth: Int) {
            guard seen.insert(c.id).inserted else { return }
            out.append((c, min(depth, CommentCodec.maxDepth - 1)))
            guard let key = CommentCodec.targetKey(c.link) else { return }
            for child in all where child.targetKey == key { walk(child, depth: depth + 1) }
        }
        for c in all where c.targetKey.map(rootKeys.contains) ?? false { walk(c, depth: 0) }
        // Anything whose parent never rendered (deleted, out of scan range) shows flat at the top level.
        for c in all { walk(c, depth: 0) }
        return out
    }

    var body: some View {
        Screen(back: true, refresh: { await model.refreshComments(for: post) }) {
            PostCard(post: post, inThread: true) { username in
                model.path.append(.feedChannel(username: username))
            }
            HPSectionMark("Comments", count: thread.count)
            if rows.isEmpty {
                HPMuted("No comments from your network yet.")
                    .padding(.bottom, HPTokens.Space.cardGap)
            } else {
                HPListCard {
                    ForEach(Array(rows.enumerated()), id: \.element.comment.id) { i, row in
                        CommentRow(comment: row.comment, depth: row.depth,
                                   replyCount: replyCount(of: row.comment),
                                   isLast: i == rows.count - 1)
                    }
                }
            }
            HPButton("Comment", style: .primary) { model.startComment(on: post) }
                .padding(.top, HPTokens.Space.rowGap)
        }
        // §6.3: the thread refreshes its comment index for the visible target when opened,
        // deepening the scan of channels that have not yet reached this post's date.
        .task(id: post.id) { await model.refreshComments(for: post) }
    }

    private func replyCount(of comment: Comment) -> Int {
        guard let key = CommentCodec.targetKey(comment.link) else { return 0 }
        return thread.filter { $0.targetKey == key }.count
    }
}

/// One comment in the tree. Replies indent one level (12pt) behind a hairline gutter.
struct CommentRow: View {
    @Environment(AppModel.self) private var model
    let comment: Comment
    let depth: Int
    let replyCount: Int
    let isLast: Bool

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
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(HPTokens.Colors.line).frame(height: HPTokens.borderWidth) }
        }
        .onLongPressGesture {
            guard comment.isMine, !comment.isPending else { return }
            model.modal = .deleteComment(comment)
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
                    HPButton("Reply", style: .ghost, size: .small) { model.startReply(to: comment) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// The comment composer (PRODUCT §2.12): the Compose card with a muted quote line of the target.
/// The first comment ever shows the comments-channel card first.
struct CommentComposerModal: View {
    @Environment(AppModel.self) private var model
    let target: CommentTarget
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoPath: String?
    @State private var posting = false

    // Channel creation (first comment ever).
    @State private var channelName = ""
    @State private var check: NodeRepository.UsernameCheck?
    @State private var checking = false
    @State private var creating = false
    @State private var checkTask: Task<Void, Never>?

    private var needsChannel: Bool { model.myCard?.replies == nil }

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

    private var quoteLine: String {
        var quote = target.quoteText.replacingOccurrences(of: "\n", with: " ")
        if quote.count > 80 { quote = String(quote.prefix(80)) + "\u{2026}" }
        let head = "re: \(target.quoteTitle)"
        return quote.isEmpty ? head : head + " \u{2014} '\(quote)'"
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPMuted(quoteLine)
                .lineLimit(2)
                .padding(.bottom, HPTokens.Space.rowPad)
            HPTextField(nil, text: $text, placeholder: "Say it.", kind: .multiline(rows: HPMetric.composeRows))
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
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("tgsocial-\(UUID().uuidString).jpg")
                if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    try? jpeg.write(to: url)
                } else {
                    try? data.write(to: url)
                }
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
        model.modal = nil
        Task { _ = await model.postComment(text: body, photoPath: photo, target: target) }
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
