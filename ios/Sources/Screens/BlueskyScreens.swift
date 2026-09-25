// Screens — Bluesky (PRODUCT.md §2.35–§2.40). The Settings card, the sheets, the post card.
//
// Nothing here is reachable at first launch, on Sign in, in Setup, on You, or in the demo (§2.35,
// §2.40): the Settings card is the only door, and a reader who never opens it sees the app exactly
// as before — except that a node they follow may now carry Bluesky posts, which renders below.

import SwiftUI

// MARK: - Images from Bluesky's CDN

/// Bluesky media arrives as https URLs (the AppView's CDN), not TDLib files, so it has its own small
/// loader: decoded once, downsampled to the width it draws at, held in an NSCache the system can
/// purge. Kept apart from `ImageMemoryCache` on purpose — that budget is TDLib's renditions.
enum BlueskyImages {
    static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    static func load(_ url: String, maxPoints: CGFloat) async -> UIImage? {
        let key = "\(url)#\(Int(maxPoints))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let u = URL(string: url), let (data, _) = try? await URLSession.shared.data(from: u) else { return nil }
        let image: UIImage? = await Task.detached(priority: .utility) {
            guard let full = UIImage(data: data) else { return nil }
            let scale = await UIScreen.main.scale
            let target = maxPoints * scale
            let longest = max(full.size.width, full.size.height)
            guard longest > target, longest > 0 else { return full }
            let f = target / longest
            return full.preparingThumbnail(of: CGSize(width: full.size.width * f, height: full.size.height * f)) ?? full
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        }
        return image
    }
}

struct BlueskyAvatar: View {
    let url: String?
    let size: CGFloat
    let initial: String
    @State private var image: UIImage?

    var body: some View {
        HPAvatar(image: image, size: size, fallbackInitial: initial)
            .task(id: url) {
                guard let url else { image = nil; return }
                image = await BlueskyImages.load(url, maxPoints: size)
            }
    }
}

struct BlueskyRemoteImage: View {
    let url: String
    let aspect: CGFloat
    let alt: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.bg2)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
        .task(id: url) { image = await BlueskyImages.load(url, maxPoints: HPTokens.Space.columnMax) }
    }
}

// MARK: - The post card (§2.36)

/// §2.36: the same §2.3 card, with the channel subheading replaced by the account's handle and a
/// neutral `Bluesky` pill — same header, same body, same place in the merge. The footer is
/// `N likes · N replies` with no Comment button: tgsocial comments point at t.me posts.
struct BlueskyPostCard: View {
    @Environment(AppModel.self) private var model
    let post: Post

    var body: some View {
        if let b = post.bluesky {
            HPCard {
                header(b).postHeaderBottomBand()
                if !post.text.isEmpty {
                    // Tapping the text opens the post on Bluesky, where its replies are.
                    PostTextBlock(text: post.text, forwardedFrom: nil, label: BlueskyCopy.openOn,
                                  onOpen: { model.open(b.webURL) },
                                  onDetails: { model.modal = .postSheet(post) })
                }
                BlueskyMediaBlock(post: b)
                HPMonoSmall(Self.footer(b), color: HPTokens.Colors.faint)
                    .lineLimit(1)
                    .padding(.top, HPTokens.Space.rowGap)
                    .accessibilityLabel(Self.footer(b))
            }
            .onLongPressGesture { model.modal = .postSheet(post) }
        }
    }

    /// `12 likes · 3 replies` — `compactCount` like reactions.
    static func footer(_ b: BlueskyPost) -> String {
        "\(CompactCount.format(b.likeCount)) like\(b.likeCount == 1 ? "" : "s") \u{00B7} \(CompactCount.format(b.replyCount)) repl\(b.replyCount == 1 ? "y" : "ies")"
    }

    private func header(_ b: BlueskyPost) -> some View {
        let name = post.authorName ?? b.name
        return PostHeader(name: name, channel: b.handleLabel, pill: BlueskyCopy.pill, date: post.date,
                          shareURL: URL(string: b.webURL),
                          onOpenName: {
                              // Attributed → the node's profile; else the account on Bluesky (§2.36).
                              if let node = post.authorUsername { model.path.append(.profile(username: node)) } else { model.open(b.profileURL) }
                          },
                          onOpenChannel: { model.open(b.profileURL) }) {
            // "The avatar is the source" (§2.3), and here the source is the account.
            BlueskyAvatar(url: b.avatar, size: HPTokens.Space.avatarRow, initial: String(name.drop(while: { $0 == "@" }).prefix(1)))
        }
    }
}

/// §2.36's media table for v1: images, link card, video still, quote row.
struct BlueskyMediaBlock: View {
    @Environment(AppModel.self) private var model
    let post: BlueskyPost

    var body: some View {
        VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
            if !post.images.isEmpty { images }
            if let ext = post.external { linkCard(ext) }
            if post.hasVideo { videoStill }
            if let handle = post.quoteHandle, let uri = post.quoteUri {
                Button { model.open(Atproto.bskyPostUrl(uri) ?? uri) } label: {
                    HPMonoSmall(BlueskyCopy.quoting(handle), color: HPTokens.Colors.faint)
                        .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, post.images.isEmpty && post.external == nil && !post.hasVideo && post.quoteUri == nil ? 0 : HPTokens.Space.rowGap)
    }

    @ViewBuilder private var images: some View {
        let list = Array(post.images.prefix(4))
        let columns = list.count == 1 ? 1 : 2
        let rows = stride(from: 0, to: list.count, by: columns).map { Array(list[$0..<min($0 + columns, list.count)]) }
        VStack(spacing: HPTokens.Space.tabsGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: HPTokens.Space.tabsGap) {
                    ForEach(row, id: \.thumb) { img in
                        Button { model.open(post.webURL) } label: {
                            BlueskyRemoteImage(url: img.thumb, aspect: Self.aspect(img, single: list.count == 1), alt: img.alt)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    static func aspect(_ img: BlueskyImage, single: Bool) -> CGFloat {
        guard single, let w = img.width, let h = img.height, w > 0, h > 0 else { return 1 }
        return min(max(CGFloat(w) / CGFloat(h), 0.5), 2)
    }

    private func linkCard(_ ext: BlueskyExternal) -> some View {
        Button { model.open(ext.uri) } label: {
            VStack(alignment: .leading, spacing: HPTokens.Space.tabsGap) {
                if let thumb = ext.thumb { BlueskyRemoteImage(url: thumb, aspect: 1.91, alt: ext.title) }
                if !ext.title.isEmpty { HPBody(ext.title, strong: true).lineLimit(2).multilineTextAlignment(.leading) }
                HPMonoSmall(ext.domain, color: HPTokens.Colors.faint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: HPTokens.Space.touchMin, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open link \(ext.title.isEmpty ? ext.domain : ext.title)")
    }

    /// §2.36: Bluesky serves HLS; playing it on some builds only would break the same-screens rule,
    /// so every build shows the still and says where it plays.
    private var videoStill: some View {
        Button { model.open(post.webURL) } label: {
            VStack(alignment: .leading, spacing: HPTokens.Space.tabsGap) {
                ZStack {
                    if let thumb = post.videoThumb {
                        BlueskyRemoteImage(url: thumb, aspect: 16.0 / 9.0, alt: "Video")
                    } else {
                        RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.bg2)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    }
                    HPPlayGlyph(playing: false)
                }
                HPMonoSmall(BlueskyCopy.playsOn, color: HPTokens.Colors.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(BlueskyCopy.playsOn)
    }
}

// MARK: - The post sheet (§2.36)

struct BlueskyPostSheet: View {
    @Environment(AppModel.self) private var model
    let post: Post

    var body: some View {
        if let b = post.bluesky {
            VStack(alignment: .leading, spacing: 0) {
                HPSectionMark("Post")
                row("Posted", PostTime.exact(unix: post.date))
                row("On", "Bluesky \u{00B7} \(b.handleLabel)")
                row("Likes", CompactCount.format(b.likeCount), isLast: true)
                HPButton(BlueskyCopy.openOn, style: .neutral) {
                    model.modal = nil
                    model.open(b.webURL)
                }
                .padding(.top, HPTokens.Space.rowPad)
                SafetyBlock(primary: (ReportSubject(post: post).buttonLabel, true, { model.modal = .report(ReportSubject(post: post)) }),
                            block: blockRow(b), mute: muteRow(b))
                HPButton("Close", style: .ghost) { model.modal = nil }
                    .padding(.top, HPTokens.Space.rowGap)
            }
        }
    }

    /// §2.40: on a linked account the button names the node; on any other it names the handle and
    /// blocks by DID.
    private func blockRow(_ b: BlueskyPost) -> (label: String, run: () -> Void)? {
        if let node = post.authorUsername {
            guard !model.isMe(node) else { return nil }
            return ("Block @\(node)", { model.modal = .block(username: node) })
        }
        return ("Block \(b.handleLabel)", { model.modal = .blockAccount(did: b.authorDid, handle: b.handleLabel) })
    }

    private func muteRow(_ b: BlueskyPost) -> (label: String, run: () -> Void)? {
        if model.moderation.lists.isMuted(sourceKey: b.authorDid) {
            return ("Unmute \(b.handleLabel)", { model.unmuteAccount(did: b.authorDid, handle: b.handleLabel) })
        }
        return ("Mute \(b.handleLabel)", { model.muteAccount(did: b.authorDid, handle: b.handleLabel) })
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

/// §2.40: `Block @ana.bsky.social?` for an account with no node.
struct BlockAccountModal: View {
    @Environment(AppModel.self) private var model
    let did: String
    let handle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Block")
            HPH2("Block \(handle)?")
            HPMuted(BlueskyCopy.blockBody)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Block", style: .danger) { model.blockAccount(did: did, handle: handle) }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}

/// PRODUCT §2.40's Settings row for a blocked or muted account: the handle in body, the DID in mono
/// muted beneath. An account is not a node, so no avatar and no profile push; the row opens the
/// account on Bluesky, as the node profile's Bluesky row does (§2.36). The handle is filled in
/// from the same one-time profile read that row uses; until it lands the DID stands in.
struct BlueskyAccountSafetyRow: View {
    @Environment(AppModel.self) private var model
    let did: String
    /// `Unblock` or `Unmute`.
    let action: String
    let isLast: Bool
    /// Handed the label the toast names: the handle, else the DID.
    let undo: (String) -> Void

    var body: some View {
        let handle = model.blueskyHandle(did: did)
        HPListItem(isLast: isLast) {
            Button { model.open(Atproto.bskyProfileUrl(did)) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HPBody(handle ?? "Bluesky account", strong: true).lineLimit(1)
                    HPMonoSmall(did).lineLimit(1)
                }
                .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(BlueskyCopy.openOn)
        } trailing: {
            HPButton(action, style: .ghost, size: .small) { undo(handle ?? did) }
        }
        .task(id: did) { if !model.isDemo, handle == nil { _ = await model.bluesky.profile(did) } }
    }
}

// MARK: - Settings (§2.35)

struct BlueskySettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let bsky = model.bluesky!
        HPSectionMark("Bluesky")
        if let acct = bsky.account {
            HPCard {
                Button { model.open(Atproto.bskyProfileUrl(acct.did)) } label: {
                    HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                        BlueskyAvatar(url: acct.avatar, size: HPTokens.Space.avatarRow,
                                      initial: String((acct.displayName ?? acct.handle).prefix(1)))
                        VStack(alignment: .leading, spacing: 0) {
                            HPBody(acct.displayName?.isEmpty == false ? acct.displayName! : acct.handleLabel, strong: true).lineLimit(1)
                            HPMonoSmall(acct.handleLabel).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: HPTokens.Space.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(acct.handleLabel) on Bluesky")
            }
            HPListCard {
                toggleRow(BlueskyCopy.followsRow, isOn: bsky.prefs.followsOn) { on in
                    bsky.prefs.followsOn = on
                    Task { await model.refreshFeed() }
                }
                toggleRow(BlueskyCopy.tagRow, isOn: bsky.prefs.tagOn, isLast: model.myNode == nil) { on in
                    bsky.prefs.tagOn = on
                    Task { await model.refreshFeed() }
                }
                if let node = model.myNode { linkRow(node: node.username, account: acct) }
            }
            HPButton(BlueskyCopy.signOut, style: .ghost) { model.modal = .blueskySignOut }
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardGap)
        } else {
            if let ended = bsky.endedHandle {
                // §2.39: the account row, `Signed out by Bluesky`, `Sign In Again` with the handle in.
                HPCard {
                    HPListItem(isLast: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            HPMonoSmall("@" + ended).lineLimit(1)
                            HPMuted(BlueskyCopy.endedByBluesky)
                        }
                    } trailing: {
                        HPButton(BlueskyCopy.signInAgain, style: .neutral, size: .small) { model.modal = .blueskySignIn(prefill: ended) }
                    }
                }
            } else {
                HPMuted(BlueskyCopy.intro)
                    .padding(.bottom, HPTokens.Space.rowGap)
                HPButton(BlueskyCopy.signIn, style: .neutral, size: .small) { model.modal = .blueskySignIn(prefill: nil) }
                    .padding(.bottom, HPTokens.Space.rowGap)
            }
            HPListCard {
                toggleRow(BlueskyCopy.tagRow, isOn: bsky.prefs.tagOn, isLast: true) { on in
                    bsky.prefs.tagOn = on
                    Task { await model.refreshFeed() }
                }
            }
            HPSmall(BlueskyCopy.tagNote, color: HPTokens.Colors.faint)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardGap)
        }
    }

    private func toggleRow(_ label: String, isOn: Bool, isLast: Bool = false, set: @escaping (Bool) -> Void) -> some View {
        HPListItem(isLast: isLast) {
            HPBody(label)
        } trailing: {
            HStack(spacing: HPTokens.Space.rowGap) {
                HPMonoSmall(isOn ? "On" : "Off")
                HPToggle(isOn: Binding(get: { isOn }, set: set), label: label)
            }
        }
    }

    /// §2.37's row: `( Link to My Node )` until linked, `Linked to @node [Verified]` with Unlink
    /// once it is, and the owner's two pending states. Only the owner ever sees a pending state.
    @ViewBuilder private func linkRow(node: String, account: BlueskyAccount) -> some View {
        let cardDid = model.myAtprotoDid
        let check = cardDid.flatMap { model.bluesky.linkCheck(node: node, did: $0) }
        HPListItem(isLast: true) {
            VStack(alignment: .leading, spacing: 0) {
                if cardDid == nil {
                    HPBody("Link to @\(node)")
                } else if cardDid != account.did {
                    HPMuted(BlueskyCopy.differentAccount)
                } else if check?.verified == false {
                    HPMuted(BlueskyCopy.pendingRecord(node))
                } else {
                    HStack(spacing: HPTokens.Space.rowGap) {
                        HPBody("Linked to @\(node)")
                        if check?.verified == true { HPPill("Verified", tone: .gold) }
                    }
                }
            }
        } trailing: {
            if cardDid == nil {
                HPButton(BlueskyCopy.linkButton, style: .neutral, size: .small) { model.modal = .blueskyLink }
            } else if cardDid != account.did {
                HPButton(BlueskyCopy.replace, style: .neutral, size: .small) { model.modal = .blueskyLink }
            } else if check?.verified == false {
                HPButton(BlueskyCopy.finishLinking, style: .neutral, size: .small) { model.modal = .blueskyLink }
            } else {
                HPButton("Unlink", style: .ghost, size: .small) { model.modal = .blueskyUnlink }
            }
        }
    }
}

// MARK: - Sign in / out (§2.35)

struct BlueskySignInModal: View {
    @Environment(AppModel.self) private var model
    let prefill: String?
    @State private var handle = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Bluesky")
            HPH2(BlueskyCopy.sheetTitle)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPTextField("Handle", text: $handle, placeholder: "elijah.bsky.social", kind: .mono) { submit() }
            // The scope list (§12.7) said in words, and the whole of it.
            HPMuted(BlueskyCopy.scopes)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButton(running ? "Continue\u{2026}" : "Continue", style: .primary,
                     enabled: !running && !handle.trimmingCharacters(in: .whitespaces).isEmpty) { submit() }
            HPButton("Cancel", style: .ghost, enabled: !running) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
        .onAppear { if handle.isEmpty, let prefill { handle = prefill } }
    }

    private func submit() {
        guard !running, !handle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        running = true
        Task {
            let outcome = await model.signInBluesky(handle)
            running = false
            // Success and a cancel on Bluesky's page both close the sheet; a failure keeps it, so a
            // mistyped handle can be fixed where it was typed.
            if outcome != .failed { model.modal = nil }
        }
    }
}

struct BlueskySignOutModal: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Bluesky")
            HPH2(BlueskyCopy.signOutTitle)
            HPMuted(body(linkedNode: linkedNode))
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButton("Sign Out", style: .danger) { Task { await model.signOutBluesky() } }
            HPButton("Cancel", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// The second sentence only when a link exists (§2.35).
    private var linkedNode: String? { model.myAtprotoDid == nil ? nil : model.myNode?.username }

    private func body(linkedNode: String?) -> String {
        guard let linkedNode else { return BlueskyCopy.signOutBody }
        return BlueskyCopy.signOutBody + " " + BlueskyCopy.signOutLink(linkedNode)
    }
}

// MARK: - Linking (§2.37)

struct BlueskyLinkModal: View {
    @Environment(AppModel.self) private var model
    @State private var step1: LinkStep = .idle
    @State private var step2: LinkStep = .idle
    @State private var step3: LinkStep = .idle
    @State private var message: String?
    @State private var running = false

    private var node: String { model.myNode?.username ?? "" }
    private var handle: String { model.bluesky.account?.handleLabel ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Link")
            HPH2(BlueskyCopy.linkTitle(handle, node))
            HPMuted(BlueskyCopy.linkBody)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPSectionMark(BlueskyCopy.twoLines)
            HPListCard {
                stepRow("1", "Your Bluesky account names", "@" + node, step1)
                stepRow("2", "Your card names", handle, step2)
                stepRow("3", BlueskyCopy.anyoneCanCheck, nil, step3, isLast: true)
            }
            HPSmall(BlueskyCopy.removeEither, color: HPTokens.Colors.faint)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            if let message {
                HPMuted(message).padding(.bottom, HPTokens.Space.rowPad)
            }
            HPButton(message == nil ? "Link" : "Try Again", style: .primary, enabled: !running) { run() }
            HPButton("Cancel", style: .ghost, enabled: !running) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// PROTOCOL §12.8's order: the record, then the card, then the check a stranger would run. A
    /// retry after step 1 succeeded re-runs from step 2 only (§2.37).
    private func run() {
        guard !running else { return }
        running = true
        message = nil
        model.modalLocked = true
        Task {
            defer { running = false; model.modalLocked = false }
            if step1 != .done {
                step1 = .writing
                if let error = await model.linkWriteRecord() {
                    step1 = .failed
                    message = "Bluesky said: \(error). Nothing was changed."
                    return
                }
                step1 = .done
            }
            if step2 != .done {
                step2 = .writing
                guard await model.linkWriteCard() else {
                    step2 = .failed
                    message = "Your Bluesky account names @\(node). Your card doesn't yet \u{2014} Telegram said: \(model.lastCardWriteError ?? "no answer")."
                    return
                }
                step2 = .done
            }
            step3 = .checking
            if await model.linkCheckAsStranger() == true {
                step3 = .verified
                model.modalLocked = false
                model.modal = nil
                model.showToast(BlueskyCopy.linked, tone: .good)
            } else {
                // Row 3 keeps `Checking` until the next refresh settles it.
                message = "Both lines are written. Couldn't check them yet."
            }
        }
    }

    private func stepRow(_ n: String, _ label: String, _ value: String?, _ step: LinkStep, isLast: Bool = false) -> some View {
        HPListItem(isLast: isLast) {
            HStack(alignment: .top, spacing: HPTokens.Space.rowGap) {
                HPMonoSmall(n)
                VStack(alignment: .leading, spacing: 0) {
                    HPBody(label)
                    if let value { HPMonoSmall(value).lineLimit(1) }
                }
            }
        } trailing: {
            HPPill(Self.pillText(step), tone: step == .verified ? .gold : step == .failed ? .bad : .neutral)
        }
    }

    static func pillText(_ step: LinkStep) -> String {
        switch step {
        case .idle: return "\u{2014}"
        case .writing: return "Writing"
        case .done: return "Done"
        case .failed: return "Failed"
        case .checking: return "Checking"
        case .verified: return "Verified"
        }
    }
}

struct BlueskyUnlinkModal: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Unlink")
            HPH2(BlueskyCopy.unlinkTitle(model.bluesky.account?.handleLabel ?? "Bluesky"))
            HPMuted(BlueskyCopy.unlinkBody)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButton("Unlink", style: .danger) { Task { await model.unlinkBluesky() } }
            HPButton("Cancel", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }
}

// MARK: - The node profile row (§2.36)

/// `Bluesky  @ana.bsky.social  Verified` at the top of FEEDS — only for a VERIFIED link. An
/// unverified one shows nothing at all, to everyone but the owner (PROTOCOL §12.3).
struct BlueskyProfileRow: View {
    @Environment(AppModel.self) private var model
    let did: String
    @State private var account: BlueskyAccount?

    var body: some View {
        HPListCard {
            HPListItem(isLast: true) {
                Button { model.open(Atproto.bskyProfileUrl(did)) } label: {
                    HStack(spacing: HPTokens.Space.rowGap) {
                        HPBody("Bluesky")
                        HPMonoSmall(account?.handleLabel ?? did).lineLimit(1)
                    }
                    .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open on Bluesky")
            } trailing: {
                HPPill("Verified", tone: .gold)
            }
        }
        .task(id: did) { account = await model.bluesky.profile(did) }
    }
}

// MARK: - Compose (§2.38)

/// The row between the textarea and the buttons, present only while signed in to Bluesky and never
/// on a private tab or in the demo. Off every time the sheet opens — the caller owns the state and
/// starts it false.
struct BlueskyComposeRow: View {
    @Binding var isOn: Bool
    let text: String
    let handle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPListItem(isLast: true) {
                HPBody(BlueskyCopy.alsoPost)
            } trailing: {
                HStack(spacing: HPTokens.Space.rowGap) {
                    HPMonoSmall(isOn ? "On" : "Off")
                    HPToggle(isOn: $isOn, label: BlueskyCopy.alsoPost)
                }
            }
            if isOn {
                let count = BlueskyText.graphemes(text)
                let fits = BlueskyText.fits(text)
                HPMonoSmall("\(count) / \(BlueskyText.maxGraphemes) \u{00B7} \(handle)",
                            color: fits ? HPTokens.Colors.faint : HPTokens.Colors.bad)
                if !fits {
                    HPSmall(BlueskyCopy.tooLong, color: HPTokens.Colors.bad)
                        .padding(.top, HPTokens.Space.tabsGap)
                }
                HPSmall(BlueskyCopy.deleteNote, color: HPTokens.Colors.faint)
                    .padding(.top, HPTokens.Space.tabsGap)
            }
        }
        .padding(.bottom, HPTokens.Space.rowGap)
    }
}
