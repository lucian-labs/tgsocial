// Screens — Compose (PRODUCT.md §2.9): a House Pour modal; post text (and one photo) into one of my
// feeds — or, signed in to Bluesky alone, straight to Bluesky.

import PhotosUI
import SwiftUI

struct ComposeModal: View {
    @Environment(AppModel.self) private var model
    let preselected: String?

    var body: some View {
        // PRODUCT §2.9, Bluesky only: there is no Telegram post for it to follow, so the sheet
        // posts to Bluesky directly (PROTOCOL §12.8).
        if model.session.kind == .blueskyOnly {
            BlueskyComposeModal()
        } else {
            TelegramComposeModal(preselected: preselected)
        }
    }
}

/// PRODUCT §2.9, Bluesky only: `POST TO` names the one destination in the tabs' place, the §2.38
/// counter is always on, one photo at most. Too long disables `Post` and says so; the app never
/// cuts the sentence.
struct BlueskyComposeModal: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoPath: String?
    @State private var posting = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Post to")
            HPMonoSmall(SessionCopy.postTo(model.bluesky?.account?.handleLabel ?? ""))
                .lineLimit(1)
                .padding(.bottom, HPTokens.Space.rowPad)
            HPTextField(nil, text: $text, placeholder: "Say it.", kind: .multiline(rows: HPMetric.composeRows))
            let fits = BlueskyText.fits(trimmed)
            HPMonoSmall("\(BlueskyText.graphemes(trimmed)) / \(BlueskyText.maxGraphemes)",
                        color: fits ? HPTokens.Colors.faint : HPTokens.Colors.bad)
            if !fits {
                HPSmall(BlueskyText.tooLong, color: HPTokens.Colors.bad)
                    .padding(.top, HPTokens.Space.tabsGap)
            }
            ComposePhotoPicker(pickerItem: $pickerItem, photoPath: $photoPath)
                .padding(.top, HPTokens.Space.rowGap)
            HPButtonRow {
                HPButton("Post", style: .primary, enabled: !posting && fits && (!trimmed.isEmpty || photoPath != nil)) { submit() }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }

    private func submit() {
        guard !posting, BlueskyText.fits(trimmed), !trimmed.isEmpty || photoPath != nil else { return }
        posting = true
        Task {
            let ok = await model.postToBluesky(text: trimmed, photoPath: photoPath)
            posting = false
            if ok { model.modal = nil }
        }
    }
}

/// `Add Photo`, shared by both sheets: the picked photo is written to a temporary JPEG off the
/// main actor and handed over as a path.
struct ComposePhotoPicker: View {
    @Binding var pickerItem: PhotosPickerItem?
    @Binding var photoPath: String?

    var body: some View {
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
}

struct TelegramComposeModal: View {
    @Environment(AppModel.self) private var model
    let preselected: String?
    @State private var feed = ""
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var photoPath: String?
    @State private var posting = false
    /// PRODUCT §2.38: per post, never remembered — false every time the sheet opens.
    @State private var alsoBluesky = false

    /// PRODUCT §2.28: my public feeds, then my private channels — each private tab says so.
    private var feeds: [String] { model.composeTargets }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Post to")
            if feeds.isEmpty {
                HPMuted("No feeds yet.")
                    .padding(.bottom, HPTokens.Space.rowPad)
            } else {
                HPTabs(items: feeds, selected: $feed) { name in model.composeLabel(name) }
                // A person posting sees where it is going (§2.28).
                if model.isPrivateTarget(feed) {
                    HPPill("Private", tone: .neutral).padding(.bottom, HPTokens.Space.rowGap)
                }
            }
            HPTextField(nil, text: $text, placeholder: "Say it.", kind: .multiline(rows: HPMetric.composeRows))
            ComposePhotoPicker(pickerItem: $pickerItem, photoPath: $photoPath)
                .padding(.bottom, HPTokens.Space.rowGap)
            if let handle = blueskyHandle {
                BlueskyComposeRow(isOn: $alsoBluesky, text: text.trimmingCharacters(in: .whitespacesAndNewlines), handle: handle)
            }
            HPButtonRow {
                HPButton("Post", style: .primary, enabled: canPost) { submit() }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
        .onAppear {
            feed = preselected.flatMap { p in feeds.first { Username.key($0) == Username.key(p) } } ?? feeds.first ?? ""
        }
    }

    private var canPost: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // §2.38: past 300 graphemes `Post` disables while the toggle is on — never truncated.
        if showsBluesky, alsoBluesky, !BlueskyText.fits(trimmed) { return false }
        return !posting && !feed.isEmpty && (!trimmed.isEmpty || photoPath != nil)
    }

    /// §2.38: absent on a private tab, in the demo, and while signed out of Bluesky.
    private var showsBluesky: Bool {
        !model.isDemo && !feed.isEmpty && !model.isPrivateTarget(feed) && model.bluesky?.isSignedIn == true
    }

    private var blueskyHandle: String? { showsBluesky ? model.bluesky?.account?.handleLabel : nil }

    private func submit() {
        guard canPost else { return }
        posting = true
        Task {
            let ok = await model.post(text: text.trimmingCharacters(in: .whitespacesAndNewlines), photoPath: photoPath, to: feed,
                                      alsoBluesky: showsBluesky && alsoBluesky)
            posting = false
            if ok { model.modal = nil }
        }
    }
}
