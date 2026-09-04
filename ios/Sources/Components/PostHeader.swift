// Components — the post card header (PRODUCT.md §2.3 "Header metrics").
//
// One row: the avatar, then the name/channel stack, then the time and Share. The stack is *tight* —
// the name at the body line height, the channel directly under it at the mono-small line height, no
// extra leading — and the avatar is centred against that stack, not pinned above it. The whole
// header measures about one avatar tall; a header appreciably taller than its own avatar means
// something in it has been inflated.
//
// So nothing here reaches its hit target (COMPONENTS.md rule 6) by growing a line box. Every control
// wears a clear overlay instead, one that extends past the painted bounds and leaves the laid-out
// height alone. The two stacked labels anchor their overlays to the edge they share, so the name
// grows its region upwards and the channel grows its own downwards and neither covers the other's
// glyphs.
//
// A region is only real where the space around it is clear, and the channel's half hangs *below the
// header*: the header does not own all of its own hit targets. The card owes it `PostHeaderBottomGap`
// clear of anything tappable, exactly as on Android (`PostHeader.kt`, `PostHeaderBottomGap`) — and
// without that band the 40pt overlay is a comment rather than a target, because the post body is laid
// out after the header and takes every point the two share. `PostHeaderHitRegionTests` measures the
// regions inside a real card and fails if any of them reaches into a neighbour's tap surface.
//
// Generic over the avatar so `PostHeaderMetricsTests` can measure the real layout without an
// AppModel; the app always passes `NodeAvatar`.

import SwiftUI

/// The band the card holds clear of tap surfaces **under** the header (COMPONENTS.md rule 6, the
/// tiling half). The channel subheading is one mono-small line box and takes the rest of its
/// `touchMin` as an overlay hanging below itself, so that much of the card's next gap belongs to the
/// channel, not to whatever follows: SwiftUI hit-tests later siblings first, and one that starts
/// inside the band swallows it — the target measures 40pt and lives at 14pt, its bottom 26pt opening
/// the thread instead of the feed. `rowGap` is the rhythm; rule 6 is the floor. Mirrors Android's
/// `PostHeaderBottomGap` (there the ramp's explicit line height makes it 20.8dp; SwiftUI paints a
/// shorter line box, so the overhang — and the band — is larger here).
let PostHeaderBottomGap: CGFloat = max(HPTokens.Space.rowGap, hpHitBandBelow(HPType.monoSmall.hpLineBox))

extension View {
    /// Holds `PostHeaderBottomGap` clear under a post header, less the `rowGap` the element below it
    /// carries as its own whitespace — the smallest gap any of them carries, so every card shape
    /// (text at `rowPad`, media and the footer at `rowGap`) keeps at least the band. Whitespace
    /// counts: what the band may not contain is a *tap surface*, which is why `PostTextBlock` keeps
    /// its padding outside its content shape.
    ///
    /// One modifier so the card and `PostHeaderHitRegionTests` cannot drift: the test asserts the
    /// band on the same views the card ships, arranged the way the card arranges them.
    func postHeaderBottomBand() -> some View {
        padding(.bottom, max(0, PostHeaderBottomGap - HPTokens.Space.rowGap))
    }
}

/// Labels the post card's hit regions report under `hpMeasureTouchTargets` (`HPTouchProbe`), so a
/// test names a region instead of counting tree order.
enum PostCardRegion {
    static let avatar = "avatar"
    static let name = "name"
    static let channel = "channel"
    static let share = "share"
    static let text = "post text"
    /// The audio player's spectrogram strip (PRODUCT §2.11.1). Its painted shape is taller than
    /// `touchMin`, so unlike the header's controls it needs no overlay — but it still reports, so
    /// the assembled-card test can prove the region is really there.
    static let strip = "spectrogram strip"
}

struct PostHeader<Avatar: View>: View {
    /// The person — the node the post reaches me through, or the channel title when unattributed.
    let name: String
    /// The source channel's title. Nil when nothing attributes the post and `name` *is* the channel.
    let channel: String?
    let date: Int
    let shareURL: URL?
    /// PRODUCT §2.22.3: in the demo `Share` stays where it is, stays tappable, and answers rather
    /// than presenting a share sheet — a system sheet would put an invented `t.me` link into
    /// someone's messages. Non-nil replaces the `ShareLink` with a button that runs this.
    let onShareRefused: (() -> Void)?
    let onOpenName: () -> Void
    let onOpenChannel: () -> Void
    let avatar: Avatar

    init(name: String, channel: String?, date: Int, shareURL: URL?,
         onShareRefused: (() -> Void)? = nil,
         onOpenName: @escaping () -> Void, onOpenChannel: @escaping () -> Void,
         @ViewBuilder avatar: () -> Avatar) {
        self.name = name; self.channel = channel; self.date = date; self.shareURL = shareURL
        self.onShareRefused = onShareRefused
        self.onOpenName = onOpenName; self.onOpenChannel = onOpenChannel; self.avatar = avatar()
    }

    var body: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            // The avatar is the source channel (§2.3) and shares the name's destination, as on
            // Android (PostCard.kt). 36pt painted, 40pt tappable.
            Button(action: onOpenName) {
                avatar.hpTouchOverlay(label: PostCardRegion.avatar)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)

            VStack(alignment: .leading, spacing: 0) {
                // The name is the person: body strong, tap → node profile.
                Button(action: onOpenName) {
                    HPBody(name, strong: true)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        // Upwards, into the card's own `cardPad` — clear space, so the full
                        // `touchMin` is real here.
                        .hpTouchOverlay(.bottomLeading, label: PostCardRegion.name)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(name)")

                // Subheading: the channel, mono small muted, tap → feed channel screen (§2.6).
                //
                // Downwards, past the header and into `PostHeaderBottomGap` — the band the card
                // holds clear for exactly this. See that constant.
                if let channel {
                    Button(action: onOpenChannel) {
                        HPMonoSmall(channel)
                            .lineLimit(1)
                            .hpTouchOverlay(.topLeading, label: PostCardRegion.channel)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(channel)")
                }
            }

            Spacer(minLength: HPTokens.Space.rowGap)

            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                // Relative time, mono faint, refreshed each minute while visible. Not a control:
                // the exact timestamp lives in the long-press sheet.
                TimelineView(.everyMinute) { context in
                    HPMonoSmall(PostTime.relative(unix: date, now: context.date), color: HPTokens.Colors.faint)
                }
                shareButton
            }
            // The trailing group takes its ideal width first; a long name or channel title is what
            // gives, never the time.
            .layoutPriority(1)
        }
    }

    /// Share — ghost small button right of the time (§2.3): the system share sheet with the post's
    /// t.me link. Its own padding keeps it under the avatar's height, so it never sets the row.
    @ViewBuilder private var shareButton: some View {
        // Same painted control and the same hit region either way, so `PostHeaderHitRegionTests`
        // measures one shape and §2.22.3's "nothing greyed out, nothing hidden" holds literally.
        if let onShareRefused {
            Button(action: onShareRefused) { shareLabel }
                .buttonStyle(HPPressStyle())
                .accessibilityLabel("Share")
        } else if let shareURL {
            ShareLink(item: shareURL) { shareLabel }
                .buttonStyle(HPPressStyle())
                .accessibilityLabel("Share")
        }
    }

    private var shareLabel: some View {
        Text("Share")
            .hpStyle(HPType.buttonSm, color: HPTokens.Colors.muted)
            .lineLimit(1)
            .padding(.vertical, HPTokens.Space.buttonSmY)
            .padding(.horizontal, HPTokens.Space.buttonSmX)
            .hpTouchOverlay(label: PostCardRegion.share)
    }
}
