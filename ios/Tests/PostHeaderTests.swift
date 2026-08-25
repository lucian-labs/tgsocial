// Unit tests — the post card header (PRODUCT §2.3 "The avatar is the source channel" and
// "Header metrics"). Three claims, all checked by measurement rather than by eye:
//
//  · the avatar fallback chain — source channel photo → node photo → the initial — as pure logic;
//  · the header's laid-out height against the tokens it is built from;
//  · the hit region every control in it actually holds, measured *inside a real card* against the
//    neighbours that share the space with it. A region measured on a bare header is the region the
//    overlay drew, not the region a finger gets — the two differ exactly where this matters.

import SwiftUI
import UIKit
import XCTest
@testable import tgsocial

// MARK: - The avatar is the source channel (PRODUCT §2.3)

final class PostAvatarFallbackTests: XCTestCase {
    private func photo(_ uniqueId: String) -> PhotoRef {
        PhotoRef(fileId: 7, uniqueId: uniqueId, width: 160, height: 160, minithumbnail: nil)
    }

    /// A node is an aggregate of a person's channels, so the avatar says which channel the post
    /// came from: the source channel's photo outranks the person's.
    func testTheSourceChannelPhotoWins() {
        let channel = photo("channel"), node = photo("node")
        XCTAssertEqual(Attribution.avatarPhoto(sourcePhoto: channel, nodePhoto: node), channel)
    }

    func testFallsBackToTheNodePhotoWhenTheChannelHasNone() {
        let node = photo("node")
        XCTAssertEqual(Attribution.avatarPhoto(sourcePhoto: nil, nodePhoto: node), node)
    }

    /// Third rung: nil, and the card draws the initial in the display serif.
    func testFallsThroughToTheInitialWhenNeitherHasAPhoto() {
        XCTAssertNil(Attribution.avatarPhoto(sourcePhoto: nil, nodePhoto: nil))
    }

    /// Telegram's generated letter avatar is not a photo. The public page has to detect it (a
    /// `data:image/svg+xml` image on a `bgcolorN` element); the app never sees one, because TDLib
    /// reports `chat.photo` as null for an unphotographed channel and `Mapping.photoRef` maps that
    /// null straight through. Without this, `sourcePhoto` would carry Telegram's letter and every
    /// unphotographed channel would render it instead of ours.
    func testAChannelWithNoPhotoArrivesAsNil() {
        XCTAssertNil(Mapping.photoRef(nil))
        // …and the chain then falls through to the node, exactly as if the field were absent.
        let node = photo("node")
        XCTAssertEqual(Attribution.avatarPhoto(sourcePhoto: Mapping.photoRef(nil), nodePhoto: node), node)
    }
}

// MARK: - The header the app ships, at the width a post card gives it

@MainActor
private enum Fixture {
    /// The width a post card's header actually gets: the column, less its side padding, less the
    /// card's own padding on both sides.
    static let contentWidth = HPTokens.Space.columnMax
        - 2 * HPTokens.Space.columnSide - 2 * HPTokens.Space.cardPad
    /// The card itself, before its padding.
    static let cardWidth = HPTokens.Space.columnMax - 2 * HPTokens.Space.columnSide

    static let name = "Ana Iliovic"
    static let channel = "WaveLoop devlog"
    static let body = RichText(spans: [
        RichSpan(text: "Cut the sample at the transient and let the tail ring under the next bar.",
                 kind: .plain, url: nil)
    ])

    static func measure(_ view: some View) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
    }

    static func header(name: String = Fixture.name, channel: String? = Fixture.channel) -> some View {
        PostHeader(name: name,
                   channel: channel,
                   date: 1_787_500_920,
                   shareURL: DeepLink.url(DeepLink.post(username: "waveloop_devlog", messageId: 144 << 20)),
                   onOpenName: {},
                   onOpenChannel: {}) {
            // The app passes NodeAvatar, which needs an AppModel to load its image; the kit view
            // underneath it is what occupies the space, and it occupies exactly avatarRow.
            HPAvatar(image: nil, size: HPTokens.Space.avatarRow, fallbackInitial: "A")
        }
    }
}

// MARK: - Header metrics (PRODUCT §2.3)

@MainActor
final class PostHeaderMetricsTests: XCTestCase {
    private func measure(_ view: some View) -> CGSize { Fixture.measure(view) }

    /// §2.3: the stack is tight — the name at the body line height, the channel directly under it
    /// at the mono-small line height, no extra leading — and the avatar is centred against it. So
    /// the row is whichever is taller: the avatar, or the two natural line boxes.
    func testTheHeaderIsOneAvatarTall() {
        let nameLine = measure(HPBody(Fixture.name, strong: true).lineLimit(1)).height
        let channelLine = measure(HPMonoSmall(Fixture.channel).lineLimit(1)).height
        let stack = nameLine + channelLine
        let measured = measure(Fixture.header()).height
        print("[header] name=\(nameLine) channel=\(channelLine) stack=\(stack) "
              + "avatar=\(HPTokens.Space.avatarRow) header=\(measured)")
        XCTAssertEqual(measured, max(HPTokens.Space.avatarRow, stack), accuracy: 1)
    }

    /// An unattributed post has no subheading, so the row is the avatar against one line.
    func testAnUnattributedHeaderIsTheAvatarAgainstOneLine() {
        let nameLine = measure(HPBody(Fixture.name, strong: true).lineLimit(1)).height
        let measured = measure(Fixture.header(channel: nil)).height
        print("[header] unattributed=\(measured)")
        XCTAssertEqual(measured, max(HPTokens.Space.avatarRow, nameLine), accuracy: 1)
    }

    /// The baseline this change removed: the 40pt hit targets implemented by inflating the layout
    /// boxes. Kept here, and nowhere else, so the fix has something to be measured against.
    func testTheInflatedHeaderWasTallerThanItsOwnAvatar() {
        let channelLine = measure(HPMonoSmall(Fixture.channel).lineLimit(1)).height
        let inflated = measure(InflatedHeader()).height
        let tight = measure(Fixture.header()).height
        print("[header] inflated=\(inflated) tight=\(tight) saved=\(inflated - tight)")
        // A 40pt box around the name, then the channel on its own line below it.
        XCTAssertEqual(inflated, HPTokens.Space.touchMin + channelLine, accuracy: 1)
        // Which is taller than the avatar it is supposed to be built around, and taller than the fix.
        XCTAssertGreaterThan(inflated, HPTokens.Space.avatarRow)
        XCTAssertGreaterThan(inflated, tight)
    }

    /// A name and a channel title too long for the row truncate; they never wrap the row taller and
    /// never squeeze the time out — the trailing group takes its width first.
    func testLongTextDoesNotGrowTheHeader() {
        let long = String(repeating: "Ana Iliovic of the WaveLoop devlog ", count: 4)
        let measured = measure(Fixture.header(name: long, channel: long)).height
        print("[header] longText=\(measured)")
        XCTAssertEqual(measured, measure(Fixture.header()).height, accuracy: 1)
    }

}

// MARK: - Hit regions (COMPONENTS.md rule 6), measured where they ship

/// A hit region is a claim about a *place*, so every assertion here is one region against another,
/// inside the card the header actually ships in: `HPCard` (VStack, spacing 0) holding the shipped
/// `PostHeader` and the shipped `PostTextBlock`.
///
/// The header on its own would pass every one of these while the app shipped a 13pt target: the
/// channel's overlay reached 26pt past the header into the post's body, the body block is laid out
/// after the header, and the later sibling takes the touch. Nothing about that is visible in an
/// overlay's own reported size — only in where it lands relative to its neighbours. So: no region
/// may reach into another's, and each must sit inside the clear space the card guarantees.
@MainActor
final class PostHeaderHitRegionTests: XCTestCase {
    private static let headerLabel = "header"

    /// The four controls in the header, by the labels they report under `hpMeasureTouchTargets`.
    private static let controls = [PostCardRegion.avatar, PostCardRegion.name,
                                   PostCardRegion.channel, PostCardRegion.share]

    // MARK: The regression: a region that lands on a neighbour is not a region

    func testNoControlsRegionReachesIntoAnothersTapSurface() throws {
        let regions = measureCard()
        let text = try XCTUnwrap(regions[PostCardRegion.text])
        for label in Self.controls {
            let rect = try XCTUnwrap(regions[label])
            XCTAssertFalse(rect.intersects(text),
                           "\(label) \(rect) reaches into the post text's tap surface \(text) — "
                           + "the text block is laid out after the header and takes every shared point")
        }
        // …and the controls tile with each other too: the name grows up, the channel grows down,
        // and the boundary between them is a line, not an overlap (rule 6).
        for (i, a) in Self.controls.enumerated() {
            for b in Self.controls.dropFirst(i + 1) {
                let ra = try XCTUnwrap(regions[a]), rb = try XCTUnwrap(regions[b])
                XCTAssertFalse(ra.intersects(rb), "\(a) \(ra) overlaps \(b) \(rb)")
            }
        }
    }

    /// The card's side of the same bargain: the band under the header stays clear of tap surfaces.
    /// Two things make that true, and both used to be false — the post text's own top gap is outside
    /// its content shape (`PostTextBlock`), and the header carries the rest of the band
    /// (`postHeaderBottomBand`). Media and the footer pad themselves by `rowGap`, which is the gap
    /// the band's arithmetic assumes, so this one card shape pins the arithmetic for all of them.
    func testTheCardHoldsTheBandTheHeaderHangsInto() throws {
        let regions = measureCard()
        let header = try XCTUnwrap(regions[Self.headerLabel])
        let text = try XCTUnwrap(regions[PostCardRegion.text])
        print("[regions] header=\(header) text=\(text) band=\(PostHeaderBottomGap) "
              + "clear=\(text.minY - header.maxY)")
        XCTAssertGreaterThanOrEqual(text.minY - header.maxY, PostHeaderBottomGap - 0.5,
                                    "the post's tap surface starts inside the header's hit band")
    }

    // MARK: The targets themselves

    /// All four keep a full `touchMin`, in both axes, in the assembled card: the avatar and Share
    /// centred in the 36pt row, the name grown upwards into `cardPad`, the channel grown downwards
    /// into `PostHeaderBottomGap`. The old test measured these four at 40pt while the channel's real
    /// target was its 13.7pt line box — the difference is the neighbours, which is why this one is
    /// measured here and not on a bare header.
    func testEveryControlKeepsAFull40ptRegion() throws {
        let regions = measureCard()
        let line = Fixture.measure(HPMonoSmall(Fixture.channel).lineLimit(1)).height
        print("[regions] channelLineBox=\(line) tokenLineBox=\(HPType.monoSmall.hpLineBox) "
              + "band=\(PostHeaderBottomGap)")
        for label in Self.controls {
            let rect = try XCTUnwrap(regions[label])
            print("[regions] \(label)=\(rect)")
            XCTAssertGreaterThanOrEqual(rect.width, HPTokens.Space.touchMin, "\(label) is \(rect.width)pt wide")
            XCTAssertGreaterThanOrEqual(rect.height, HPTokens.Space.touchMin, "\(label) is \(rect.height)pt tall")
        }
        // And the channel is still one painted line: the target is an overlay, not the line box.
        XCTAssertLessThan(line, HPTokens.Space.touchMin)
    }

    /// The invariant that holds for every card shape, not just this one: the card leaves `cardPad`
    /// above the header and `PostHeaderBottomGap` below it before anything starts taking touches.
    /// Any region outside that band is landing on something, whatever the post happens to contain.
    func testEveryRegionStaysInsideTheClearSpaceTheCardGuarantees() throws {
        let regions = measureCard()
        let header = try XCTUnwrap(regions[Self.headerLabel])
        let clear = CGRect(x: header.minX - HPTokens.Space.cardPad,
                           y: header.minY - HPTokens.Space.cardPad,
                           width: header.width + 2 * HPTokens.Space.cardPad,
                           height: header.height + HPTokens.Space.cardPad + PostHeaderBottomGap)
        for label in Self.controls {
            let rect = try XCTUnwrap(regions[label])
            XCTAssertTrue(clear.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                          "\(label) \(rect) leaves the card's clear space \(clear)")
        }
    }

    /// Rule 6's second half, asserted on the same assembled card: every control carries an
    /// accessibility label. (The time is exposed too, but it is a label, not a control — and it
    /// re-derives every minute, so only the four controls are named here.)
    func testEveryControlCarriesAnAccessibilityLabel() throws {
        let labels = Set(measureCard(labels: true).labels.map { $0.lowercased() })
        print("[regions] accessibility=\(labels.sorted())")
        // SwiftUI only builds UIKit accessibility elements when the process has an accessibility
        // client attached: true under XCUITest or on a simulator with accessibility switched on,
        // false in a plain `xcodebuild test`, where the hosting view vends no elements at all —
        // not one, not a wrong one, none. Assert wherever the runtime can answer and skip, loudly,
        // where it cannot; a green tick over an empty list would be the same lie this file exists
        // to stop telling.
        try XCTSkipIf(labels.isEmpty,
                      "no accessibility bridge in this run — the hosting view vends no elements at all")
        for expected in [Fixture.name, "Open \(Fixture.name)", "Open \(Fixture.channel)", "Share"] {
            XCTAssertTrue(labels.contains(expected.lowercased()), "missing accessibility label: \(expected)")
        }
    }

    // MARK: Harness

    /// Lays out the shipped card and returns every region it reports, by label. Six of them: the
    /// header's own frame (measured by the harness), the four controls, and the post text's tap
    /// surface.
    private func measureCard() -> [String: CGRect] { measureCard(labels: false).regions }

    /// The card, hosted in a key window and laid out: the regions it reports, and — when asked —
    /// the accessibility labels its controls vend.
    private func measureCard(labels wantsLabels: Bool) -> (regions: [String: CGRect], labels: [String]) {
        let box = RegionBox()
        let reported = expectation(description: "hit regions reported")
        reported.assertForOverFulfill = false
        let probe = HPCard {
            Fixture.header().hpTouchRegion(Self.headerLabel).postHeaderBottomBand()
            PostTextBlock(text: Fixture.body, forwardedFrom: nil, label: "Open thread",
                          onOpen: {}, onDetails: {})
        }
        .frame(width: Fixture.cardWidth)
        .environment(\.hpMeasureTouchTargets, true)
        .hpTouchSpace()
        .onPreferenceChange(HPTouchTargetKey.self) { regions in
            guard !regions.isEmpty else { return }
            box.regions = regions
            reported.fulfill()
        }
        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: HPTokens.Space.columnMax, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        wait(for: [reported], timeout: 5)

        // SwiftUI builds its accessibility elements a run loop turn or two after the first layout,
        // so read them until they are there rather than once and hopefully.
        var labels: [String] = []
        if wantsLabels {
            let deadline = Foundation.Date().addingTimeInterval(5)
            repeat {
                labels = accessibilityLabels(of: host.view)
                if labels.contains(Fixture.name) { break }
                RunLoop.current.run(until: Foundation.Date().addingTimeInterval(0.05))
            } while Foundation.Date() < deadline
        }
        window.isHidden = true
        window.rootViewController = nil

        var out: [String: CGRect] = [:]
        for region in box.regions { out[region.label] = region.rect }
        XCTAssertEqual(out.count, Self.controls.count + 2, "regions reported: \(out.keys.sorted())")
        return (out, labels)
    }

    /// Every accessibility label the hosted card vends.
    private func accessibilityLabels(of root: NSObject) -> [String] {
        var out: [String] = []
        if let label = root.accessibilityLabel, !label.isEmpty { out.append(label) }
        let count = root.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for i in 0..<count {
                guard let child = root.accessibilityElement(at: i) as? NSObject else { continue }
                out += accessibilityLabels(of: child)
            }
        }
        if let view = root as? UIView {
            for sub in view.subviews { out += accessibilityLabels(of: sub) }
        }
        return out
    }
}

/// Collects the preference across the `@Sendable` boundary `onPreferenceChange` hands back.
private final class RegionBox: @unchecked Sendable {
    var regions: [HPTouchRegion] = []
}

/// The header as it stood before this change: the name in a `touchMin` frame (40pt of box for 24pt
/// of line), the channel a separate row underneath, the avatar pinned to the top of the result.
/// Verbatim, so the measurement above compares against what actually shipped.
private struct InflatedHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    HPAvatar(image: nil, size: HPTokens.Space.avatarRow, fallbackInitial: "A")
                    HPBody("Ana Iliovic", strong: true).lineLimit(1)
                }
                .frame(minHeight: HPTokens.Space.touchMin)
                Spacer(minLength: HPTokens.Space.rowGap)
                HPMonoSmall("2h ago", color: HPTokens.Colors.faint)
                Text("Share")
                    .hpStyle(HPType.buttonSm, color: HPTokens.Colors.muted)
                    .lineLimit(1)
                    .padding(.vertical, HPTokens.Space.buttonSmY)
                    .padding(.horizontal, HPTokens.Space.buttonSmX)
                    .frame(minHeight: HPTokens.Space.touchMin)
            }
            HPMonoSmall("WaveLoop devlog")
                .lineLimit(1)
                .padding(.leading, HPTokens.Space.avatarRow + HPTokens.Space.rowGap)
        }
    }
}
