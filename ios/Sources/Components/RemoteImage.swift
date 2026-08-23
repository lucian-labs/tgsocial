// Components — images from TDLib local files via MediaLoader (no AsyncImage; there are no URLs).

import SwiftUI

struct NodeAvatar: View {
    @Environment(AppModel.self) private var model
    let photo: PhotoRef?
    let size: CGFloat
    let initial: String
    @State private var image: UIImage?

    var body: some View {
        HPAvatar(image: image, size: size, fallbackInitial: initial)
            .task(id: photo?.uniqueId) { await load() }
    }

    private func load() async {
        guard let photo else { image = nil; return }
        if let hit = model.media.cached(photo) { image = hit; return }
        image = model.media.minithumbnail(photo)
        if let full = await model.media.image(for: photo) { image = full }
    }
}

struct PostMediaView: View {
    @Environment(AppModel.self) private var model
    let media: PostMedia
    @State private var image: UIImage?

    private var ref: PhotoRef? {
        switch media {
        case .photo(let r): return r
        case .video(let t, _), .animation(let t, _), .document(_, let t): return t
        case .audio: return nil
        }
    }

    private var label: String? {
        switch media {
        case .photo: return nil
        case .video(_, let d): return PostTime.duration(seconds: d)
        case .animation(_, let d): return "GIF " + PostTime.duration(seconds: d)
        case .document(let name, _): return name
        case .audio(let title, let performer, let d):
            let who = [performer, title].filter { !$0.isEmpty }.joined(separator: " \u{2014} ")
            return (who.isEmpty ? "Audio" : who) + " \u{00B7} " + PostTime.duration(seconds: d)
        }
    }

    var body: some View {
        Group {
            if let ref {
                HPMedia(image: image, aspect: ref.height > 0 ? CGFloat(ref.width) / CGFloat(ref.height) : 1.5, overlayLabel: label)
                    .task(id: ref.uniqueId) { await load(ref) }
            } else if let label {
                HStack(spacing: HPTokens.Space.rowGap) {
                    HPMonoSmall(label)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, HPTokens.Space.inputY)
                .padding(.horizontal, HPTokens.Space.inputX)
                .background(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.bg2))
            }
        }
        .padding(.top, HPTokens.Space.rowGap)
    }

    private func load(_ ref: PhotoRef) async {
        if let hit = model.media.cached(ref) { image = hit; return }
        image = model.media.minithumbnail(ref)
        if let full = await model.media.image(for: ref) { image = full }
    }
}
