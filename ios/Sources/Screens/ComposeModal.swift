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

    private var feeds: [String] { model.myCard?.feeds ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Post to")
            if feeds.isEmpty {
                HPMuted("No feeds to post to. Manage your feeds first.")
                    .padding(.bottom, HPTokens.Space.rowPad)
            } else {
                HPTabs(items: feeds, selected: $feed) { name in model.nodes.cachedFeed(name)?.title ?? name }
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
        !posting && !feed.isEmpty && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photoPath != nil)
    }

    private func submit() {
        guard canPost else { return }
        posting = true
        Task {
            let ok = await model.post(text: text.trimmingCharacters(in: .whitespacesAndNewlines), photoPath: photoPath, to: feed)
            posting = false
            if ok { model.modal = nil }
        }
    }
}
