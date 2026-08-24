// Screens — Setup (PRODUCT.md §2.2): make your node, pick your feeds. The feeds card is reused by You → Manage.

import SwiftUI

struct SetupScreen: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var check: NodeRepository.UsernameCheck?
    @State private var checking = false
    @State private var creating = false
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Screen {
            if model.myNode == nil {
                nodeCard
            } else {
                HPCard {
                    HPSectionMark("Your node")
                    HPBody(model.myTitle.isEmpty ? model.myCard?.name ?? "" : model.myTitle, strong: true)
                    HPMonoSmall("@" + (model.myNode?.username ?? ""))
                }
                FeedsCard(primaryLabel: "Save Feeds") { model.skipSetup() }
            }
            HPButton("Skip for now", style: .ghost) { model.skipSetup() }
        }
        .onAppear {
            if username.isEmpty { username = model.suggestedUsername }
            scheduleCheck()
        }
        .onChange(of: username) { _, _ in scheduleCheck() }
        .onChange(of: model.me?.id) { _, _ in if username.isEmpty { username = model.suggestedUsername; scheduleCheck() } }
    }

    private var nodeCard: some View {
        HPCard {
            HPSectionMark("Your node")
            HPH2("Make your node.")
            HPMuted("A public channel that holds your feeds and who you follow. It lives on Telegram, and anyone can read it there.")
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HStack(alignment: .bottom, spacing: HPTokens.Space.rowGap) {
                HPTextField("Node name", text: $username, placeholder: "tgs_you", kind: .text)
                availabilityPill.padding(.bottom, HPTokens.Space.inputBottom + HPTokens.Space.inputY)
            }
            HPButton("Create Node", style: .primary, enabled: !creating && check == .available) {
                guard !creating, let name = Username.normalise(username) else { return }
                creating = true
                Task {
                    _ = await model.createNode(username: name)
                    creating = false
                }
            }
            HPButton("I already have one", style: .ghost) { Task { await model.findExistingNode() } }
                .padding(.top, HPTokens.Space.rowGap)
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
        guard let name = Username.normalise(username) else { check = username.isEmpty ? nil : .invalid; return }
        checking = true
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result = try? await model.nodes.checkUsername(name)
            guard !Task.isCancelled else { return }
            check = result
            checking = false
        }
    }
}

/// "Your feeds": candidate channels with toggles, the inline verify prompt, and one primary action.
struct FeedsCard: View {
    @Environment(AppModel.self) private var model
    let primaryLabel: String
    let onSaved: () -> Void
    @State private var selected: Set<String> = []
    @State private var verifyPrompt: Set<String> = []
    @State private var saving = false
    @State private var seeded = false

    var body: some View {
        HPCard {
            HPSectionMark("Your feeds")
            HPMuted("Pick the channels that post as you.")
                .padding(.bottom, HPTokens.Space.rowGap)
            if model.candidatesLoading, model.candidates.isEmpty {
                HPMuted("Looking through your channels.")
            } else if model.candidates.isEmpty {
                HPMuted("No channels you can post to. Make one in Telegram and come back.")
            }
            VStack(spacing: 0) {
                ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, c in
                    candidateRow(c, isLast: index == model.candidates.count - 1)
                }
            }
            HPButton(primaryLabel, style: .primary, enabled: !saving) {
                saving = true
                Task {
                    let ordered = model.candidates.compactMap(\.username).filter { selected.contains(Username.key($0)) }
                    if await model.saveFeeds(ordered) { onSaved() }
                    saving = false
                }
            }
            .padding(.top, HPTokens.Space.rowPad)
        }
        // PRODUCT §2.2: the cached list and the saved selection paint immediately, then the card
        // always re-queries live — a channel made public in Telegram a minute ago must show up.
        .task {
            if !seeded {
                selected = Set((model.myCard?.feeds ?? []).map(Username.key))
                seeded = true
            }
            await model.loadCandidates()
        }
        // While this card is on screen, candidacy-changing TDLib updates re-query on their own.
        // The selection is @State, so a background refresh never disturbs an unsaved edit.
        .onAppear { model.feedsSurfaceAppeared() }
        .onDisappear { model.feedsSurfaceDisappeared() }
    }

    @ViewBuilder private func candidateRow(_ c: FeedCandidate, isLast: Bool) -> some View {
        let key = c.username.map(Username.key) ?? ""
        let isOn = Binding<Bool>(
            get: { selected.contains(key) },
            set: { on in
                guard let username = c.username else { return }
                if on {
                    selected.insert(key)
                    if let node = model.myNode, !Backlink.verifies(description: c.description, node: node.username) {
                        verifyPrompt.insert(Username.key(username))
                    }
                } else {
                    selected.remove(key)
                    verifyPrompt.remove(key)
                }
            }
        )
        VStack(alignment: .leading, spacing: 0) {
            HPListItem(isLast: isLast && !verifyPrompt.contains(key)) {
                VStack(alignment: .leading, spacing: 0) {
                    HPBody(c.title).lineLimit(1)
                        .opacity(c.isPublic ? 1 : HPAlpha.disabled)
                    if let u = c.username {
                        HStack(spacing: HPTokens.Space.rowGap) {
                            HPMonoSmall("@" + u).lineLimit(1)
                            if let node = model.myNode, Backlink.verifies(description: c.description, node: node.username) {
                                HPPill("Verified", tone: .gold)
                            }
                        }
                    } else {
                        HPMonoSmall("Needs a public link", color: HPTokens.Colors.faint)
                    }
                }
            } trailing: {
                HPToggle(isOn: isOn, label: "Use \(c.title) as a feed", enabled: c.isPublic)
            }
            if verifyPrompt.contains(key) {
                VStack(alignment: .leading, spacing: 0) {
                    HPMuted("Add a line to this channel's description so readers can verify it's yours?")
                    HStack(spacing: HPTokens.Space.btnRowGap) {
                        HPButton("Verify", style: .neutral, size: .small) {
                            Task {
                                if await model.verifyFeed(c) { verifyPrompt.remove(key) }
                            }
                        }
                        HPButton("Skip", style: .ghost, size: .small) { verifyPrompt.remove(key) }
                    }
                    .padding(.top, HPTokens.Space.rowGap)
                }
                .padding(.vertical, HPTokens.Space.rowPad)
                .overlay(alignment: .bottom) {
                    if !isLast { Rectangle().fill(HPTokens.Colors.line).frame(height: HPTokens.borderWidth) }
                }
            }
        }
    }
}
