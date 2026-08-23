// House Pour kit — HPMedia (COMPONENTS.md "Controls").
// Full width, media radius, bg2 placeholder while loading. No border, no shadow.

import SwiftUI

public struct HPMedia: View {
    let image: UIImage?
    let aspect: CGFloat
    let overlayLabel: String?

    /// `aspect` is width / height of the media; used for the placeholder and to reserve layout.
    public init(image: UIImage?, aspect: CGFloat, overlayLabel: String? = nil) {
        self.image = image; self.aspect = max(aspect, 0.2); self.overlayLabel = overlayLabel
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous)
        ZStack(alignment: .bottomTrailing) {
            shape.fill(HPTokens.Colors.bg2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            if let overlayLabel {
                HPPill(overlayLabel, tone: .neutral)
                    .padding(HPTokens.Space.rowGap)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .animation(HPMotion.color, value: image == nil)
        .accessibilityLabel(overlayLabel ?? "Media")
    }
}
