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
        // An avatar is `size` points wide; decoding a 1000 px profile photo for a 36 pt circle is
        // ~770× the pixels it will draw.
        let rendition = ImageRendition.points(size)
        if let hit = model.media.cached(photo, rendition) { image = hit; return }
        image = model.media.minithumbnail(photo)
        if let full = await model.media.image(for: photo, rendition: rendition) { image = full }
    }
}
