// Screens — Compose (PRODUCT.md §2.9): a House Pour modal; post text (and one photo) into one of my feeds.

import PhotosUI
import SwiftUI

struct ComposeModal: View {
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
