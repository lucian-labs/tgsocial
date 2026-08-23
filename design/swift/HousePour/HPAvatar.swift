// House Pour kit — HPAvatar (COMPONENTS.md "Controls").
// Circle, bg2 fill, hairline ring; the initial set in the display serif when there is no image.

import SwiftUI

public struct HPAvatar: View {
    let image: UIImage?
    let size: CGFloat
    let fallbackInitial: String

    public init(image: UIImage?, size: CGFloat = HPTokens.Space.avatarRow, fallbackInitial: String) {
        self.image = image; self.size = size; self.fallbackInitial = fallbackInitial
    }

    public var body: some View {
        ZStack {
            Circle().fill(HPTokens.Colors.bg2)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(fallbackInitial.prefix(1)).uppercased())
                    .hpStyle(size >= HPTokens.Space.avatarProfile ? HPType.h1 : HPType.h2,
                             color: HPTokens.Colors.muted)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(HPTokens.Colors.line, lineWidth: HPTokens.borderWidth))
        .accessibilityHidden(true)
    }
}
