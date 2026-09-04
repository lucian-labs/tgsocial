// Unit tests — what the modal card does when its content is taller than the phone
// (COMPONENTS "HPModal", PRODUCT §2.15, §5).
//
// The claim under test is not "there is a ScrollView" — that would pass with the report confirm
// truncated. It is that the card stays inside the window it is given and that everything below the
// fold is still *there* to be scrolled to: §2.15's report confirm is the only route to report
// anything, its `Send Report` and `Cancel` are its last two rows, and the confirm is taller than an
// iPhone SE at default Dynamic Type before anyone touches the type-size slider. So the tests measure
// the shipped views: the confirm's ideal height at the width HPModal gives it, and then the card's
// laid-out frame and scrollable content inside a real 375×667 window.

import SwiftUI
import UIKit
import XCTest
@testable import tgsocial

@MainActor
private enum ModalFixture {
    /// The smallest phone the app ships to (PRODUCT §5: "iPhone and iPad"): an iPhone SE, which
    /// runs iOS 17 and is 375×667 in points.
    static let phone = CGSize(width: 375, height: 667)

    /// The width HPModal gives its card: the column, capped at `columnMax`, less `columnSide` a side.
    static func cardWidth(_ screen: CGFloat) -> CGFloat {
        min(screen, HPTokens.Space.columnMax) - 2 * HPTokens.Space.columnSide
    }

    /// The shipped confirm — `ReportModal`'s whole body — with its two actions stubbed out.
    static func reportConfirm() -> some View {
        ReportConfirm(subject: ReportSubject(post: MediaFixture.post()), onSend: { _ in }, onCancel: {})
    }

    /// A confirm that fits, for the control: two lines and a button, the shape of §2.16's block
    /// modal, built from the kit so the claim stays a claim about `HPModal`.
    static func shortConfirm() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Block")
            HPH2("Block @tgs_ana?")
            HPMuted("Their posts and their comments disappear from your feed.")
                .padding(.top, HPTokens.Space.rowGap)
            HPButton("Cancel", style: .ghost) {}
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// The card as `HPModal` builds it, hosted in a window of `size` and laid out. `scrolls` is
    /// what the kit put on screen: empty when the card fits, one scroll view when it does not.
    static func present(_ content: some View,
                        in size: CGSize) -> (window: UIWindow, host: UIViewController, scrolls: [UIScrollView]) {
        let probe = Color.clear.hpModal(isPresented: .constant(true)) { content }
        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        var scrolls: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { scrolls.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(host.view)
        return (window, host, scrolls)
    }

    /// The height a modal actually has to live in: the window, less the safe area, less the
    /// `columnSide` inset the card keeps on every edge.
    static func available(_ window: UIWindow, _ host: UIViewController) -> CGFloat {
        window.bounds.height - host.view.safeAreaInsets.top - host.view.safeAreaInsets.bottom
            - 2 * HPTokens.Space.columnSide
    }

    /// The whole card at that width: the confirm plus the card padding HPModal wraps it in.
    static func naturalCardHeight(_ view: some View, width: CGFloat) -> CGFloat {
        ideal(view, width: width - 2 * HPTokens.Space.cardPad) + 2 * HPTokens.Space.cardPad
    }

    static func ideal(_ view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}

@MainActor
final class ModalLayoutTests: XCTestCase {

    /// Why the bound exists, kept as a measurement rather than a claim: the report confirm does not
    /// fit an iPhone SE at *default* Dynamic Type, so nothing about "it only breaks at 1.4×" would
    /// save `Send Report` and `Cancel` from being off-window without a scroller.
    func testTheReportConfirmIsTallerThanTheSmallestPhone() {
        let width = ModalFixture.cardWidth(ModalFixture.phone.width)
        let ideal = ModalFixture.ideal(ModalFixture.reportConfirm(), width: width)
        print("[modal] report ideal=\(ideal) at width=\(width) phone=\(ModalFixture.phone.height)")
        XCTAssertGreaterThan(ideal, ModalFixture.phone.height)
    }

    /// The fix, measured where it matters: on the smallest phone the card is wholly inside the
    /// window — its bottom edge included, which is where `Cancel` sits — and the content that does
    /// not fit is still in the scroll view's `contentSize` rather than cut off.
    func testTheReportConfirmIsBoundedByTheWindowAndScrolls() throws {
        let (window, _, scrolls) = ModalFixture.present(ModalFixture.reportConfirm(), in: ModalFixture.phone)
        defer { window.isHidden = true; window.rootViewController = nil }

        let scroll = try XCTUnwrap(scrolls.first, "a modal taller than the phone has to scroll")
        let card = scroll.convert(scroll.bounds, to: window)
        print("[modal] card=\(card) content=\(scroll.contentSize.height) window=\(window.bounds)")

        XCTAssertTrue(window.bounds.contains(card), "the card runs off the window: \(card)")
        // The `columnSide` inset the sides carry, now on the top and bottom too.
        XCTAssertLessThanOrEqual(card.height, window.bounds.height - 2 * HPTokens.Space.columnSide)
        // Nothing was dropped to make it fit: everything past the fold is scrollable to.
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let ideal = ModalFixture.ideal(ModalFixture.reportConfirm(), width: ModalFixture.cardWidth(ModalFixture.phone.width))
        XCTAssertGreaterThanOrEqual(scroll.contentSize.height, ideal)
    }

    /// The invariant, over every screen the app ships to (PRODUCT §5) and the roomy ones in
    /// between: the confirm either fits the space it was given, or it scrolls with all of itself
    /// still in the scroll view. Never the third case, which is what shipped — taller than the
    /// window and not scrollable, with `Cancel` past the bottom edge.
    func testTheConfirmEitherFitsOrScrollsOnEveryScreen() {
        for screen in [ModalFixture.phone, CGSize(width: 390, height: 844),
                       CGSize(width: 430, height: 932), CGSize(width: 744, height: 1133)] {
            let (window, host, scrolls) = ModalFixture.present(ModalFixture.reportConfirm(), in: screen)
            defer { window.isHidden = true; window.rootViewController = nil }
            let available = ModalFixture.available(window, host)
            let natural = ModalFixture.naturalCardHeight(ModalFixture.reportConfirm(),
                                                         width: ModalFixture.cardWidth(screen.width))
            print("[modal] screen=\(screen) natural=\(natural) available=\(available) scrolls=\(scrolls.count)")
            if let scroll = scrolls.first {
                let card = scroll.convert(scroll.bounds, to: window)
                XCTAssertTrue(window.bounds.contains(card), "\(screen): the card runs off the window: \(card)")
                XCTAssertGreaterThanOrEqual(scroll.contentSize.height, natural - 1,
                                            "\(screen): the scroller is shorter than the confirm it holds")
            } else {
                XCTAssertLessThanOrEqual(natural, available + 1,
                                         "\(screen): \(natural)pt of confirm in \(available)pt, and nothing scrolls")
            }
        }
    }

    /// And the bound changes nothing for a confirm that already fits: the block modal (§2.16) is
    /// still a content-sized card centred in the window, with no scroller and no stretch.
    func testAShortConfirmIsStillItsOwnHeight() {
        let block = ModalFixture.shortConfirm()
        let (window, host, scrolls) = ModalFixture.present(block, in: ModalFixture.phone)
        defer { window.isHidden = true; window.rootViewController = nil }
        let natural = ModalFixture.naturalCardHeight(block, width: ModalFixture.cardWidth(ModalFixture.phone.width))
        print("[modal] block natural=\(natural) available=\(ModalFixture.available(window, host)) scrolls=\(scrolls.count)")
        XCTAssertLessThan(natural, ModalFixture.available(window, host))
        XCTAssertTrue(scrolls.isEmpty, "a modal that fits must not become a scroll view")
    }
}
