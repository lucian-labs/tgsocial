// Components — your own avatar, wherever the app draws "me" (PRODUCT.md §1, §2.8).
//
// One fallback chain for the tab and You's header: your node's photo; your Bluesky avatar
// (§2.35); the initial of your name in the display serif — §2.3's last fallback. Computed once, on
// the model (`AppModel.tabAvatar`), so the tab and the header cannot disagree about who you are.

import SwiftUI

/// The picture, at any size.
struct MyAvatarImage: View {
    @Environment(AppModel.self) private var model
    let avatar: TabAvatar
    let size: CGFloat

    var body: some View {
        switch avatar {
        case .nodePhoto(let photo):
            NodeAvatar(photo: photo, size: size, initial: model.myInitial)
        case .blueskyAvatar(let url):
            BlueskyAvatar(url: url, size: size, initial: model.myInitial)
        case .initial(let letter):
            HPAvatar(image: nil, size: size, fallbackInitial: letter)
        }
    }
}

/// PRODUCT §1: the last tab. A 24pt circle in the item's slot — the segment around it is the 40pt
/// target, and `HPTabs` lays it over the hidden words so the bar keeps its height. Selected, the
/// segment takes the `.tabs` selected fill like the other items and the circle an `accent` ring.
/// Its label, `You`, is the segment's (`Tab.you.label`); the picture itself is hidden from
/// VoiceOver so it is not read twice.
struct TabAvatarView: View {
    let avatar: TabAvatar
    let selected: Bool

    /// Two hairlines: one would vanish against a photo at this size.
    static let ringWidth: CGFloat = HPTokens.borderWidth * 2

    /// The circle reports its own frame under `hpMeasureTouchTargets` — not a target (the segment
    /// is), but the only way a test can tell a bar that draws the avatar from one that draws the
    /// word: the segment's region and its hidden word exist either way.
    static let region = "tab avatar"

    var body: some View {
        MyAvatarImage(avatar: avatar, size: HPTokens.Space.avatarTab)
            .overlay(Circle().strokeBorder(selected ? HPTokens.Colors.accent : Color.clear, lineWidth: Self.ringWidth))
            .accessibilityHidden(true)
            .hpTouchRegion(Self.region)
    }
}
