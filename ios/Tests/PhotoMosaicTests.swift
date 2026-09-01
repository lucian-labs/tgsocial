// Unit tests — the photo mosaic (PRODUCT §2.11.3).
//
// §2.11.3 is a table, a ratio rule, a reflow rule and a tap rule, so this file is four suites:
//
//   `PhotoMosaicLayoutTests`   the table (2 / 3 / 4 / 5+), the `+N`, and the ratio — as arithmetic
//                              on the pure plan, not as screenshots.
//   `PhotoMosaicGroupingTests` more than one photo becomes ONE block, and a tile opens the carousel
//                              at that tile's index.
//   `MosaicRenditionTests`     the memory claim: a tile is a thumbnail, so it is decoded at tile
//                              size — four full-resolution decodes to draw a 2×2 is the bug this
//                              rules out.
//   `MosaicHitRegionTests`     every tile is a control, measured on an assembled card with a
//                              neighbour laid out after it (COMPONENTS.md rule 6).

import SwiftUI
import UIKit
import XCTest
@testable import tgsocial

@MainActor
private enum MosaicFixture {
    /// The width a post card's media actually gets: the column, less its side padding, less the
    /// card's own padding on both sides.
    static let contentWidth = HPTokens.Space.columnMax
        - 2 * HPTokens.Space.columnSide - 2 * HPTokens.Space.cardPad
    static let cardWidth = HPTokens.Space.columnMax - 2 * HPTokens.Space.columnSide

    static let square: CGFloat = 1
    static let landscape: CGFloat = 3.0 / 2.0
    static let portrait: CGFloat = 2.0 / 3.0

    static func photo(_ n: Int) -> PostMedia { MediaFixture.photo(n) }

    /// A plan read the way Android's `HPMosaic.AREAS` and web's `MOSAIC_AREAS` declare the same
    /// table: ROWS of tile ordinals, left to right then down, a row-spanning tile repeated down its
    /// rows. `MosaicLayout` places by column, so this is the transpose that lets the assertions
    /// below quote the siblings verbatim instead of restating them in another spelling.
    static func rows(_ columns: [[Int]]) -> [[Int]] {
        guard let rowCount = columns.map(\.count).max(), rowCount > 0 else { return [] }
        return (0..<rowCount).map { row in
            columns.map { column in column[row * column.count / rowCount] }
        }
    }

    /// The size of one cell in a plan laid out at `width` — the number a tile hands the image cache.
    static func cell(_ plan: PhotoMosaic, width: CGFloat, column: Int = 0) -> CGSize {
        let gutter = MosaicSpec.gutter
        let columnWidth = (width - gutter * CGFloat(plan.columns.count - 1)) / CGFloat(plan.columns.count)
        let rows = CGFloat(plan.columns[column].count)
        let height = width / plan.aspect
        return CGSize(width: columnWidth, height: (height - gutter * (rows - 1)) / rows)
    }
}

// MARK: - §2.11.3's table

@MainActor
final class PhotoMosaicLayoutTests: XCTestCase {
    private let width = MosaicFixture.contentWidth

    /// 2 → two tiles side by side, equal width.
    func testTwoPhotosSitSideBySideInEqualColumns() {
        let plan = PhotoMosaic.plan(aspects: [MosaicFixture.square, MosaicFixture.square], width: width)
        XCTAssertEqual(plan.columns, [[0], [1]])
        XCTAssertEqual(plan.overflow, 0)
        XCTAssertFalse(plan.reflowed)
        // Equal width is the layout's own rule — two columns of one tile each, so the cells match.
        XCTAssertEqual(MosaicFixture.cell(plan, width: width, column: 0).width,
                       MosaicFixture.cell(plan, width: width, column: 1).width, accuracy: 0.01)
    }

    /// 3 → one tall tile leading, two stacked beside it.
    func testThreePhotosAreOneTallTileLeadingAndTwoStackedBesideIt() {
        let plan = PhotoMosaic.plan(aspects: [CGFloat](repeating: MosaicFixture.square, count: 3), width: width)
        XCTAssertEqual(plan.columns, [[0], [1, 2]])
        XCTAssertEqual(plan.overflow, 0)
        let leading = MosaicFixture.cell(plan, width: width, column: 0)
        let stacked = MosaicFixture.cell(plan, width: width, column: 1)
        print("[mosaic] three: leading=\(leading) stacked=\(stacked) aspect=\(plan.aspect)")
        XCTAssertGreaterThan(leading.height, stacked.height, "the leading tile is the tall one")
        XCTAssertEqual(leading.width, stacked.width, accuracy: 0.01)
    }

    /// 4 → two by two.
    func testFourPhotosAreTwoByTwo() {
        let plan = PhotoMosaic.plan(aspects: [CGFloat](repeating: MosaicFixture.square, count: 4), width: width)
        XCTAssertEqual(plan.columns, [[0, 2], [1, 3]])
        XCTAssertEqual(plan.overflow, 0)
        XCTAssertEqual(plan.tileCount, 4)
        // Album order reads ACROSS first: photo 1 is the top-right tile, not the one under photo 0.
        XCTAssertEqual(MosaicFixture.rows(plan.columns), [[0, 1], [2, 3]])
        // Four squares in a 2×2 want a square block, and that is inside the clamp.
        XCTAssertEqual(plan.aspect, 1, accuracy: 0.01)
    }

    /// 5+ → two by two of the first four; the fourth carries `+N`.
    func testFivePlusIsTwoByTwoOfTheFirstFourWithACountOnTheFourth() {
        for count in [5, 6, 12] {
            let plan = PhotoMosaic.plan(aspects: [CGFloat](repeating: MosaicFixture.square, count: count),
                                        width: width)
            XCTAssertEqual(plan.columns, [[0, 2], [1, 3]], "\(count) photos")
            XCTAssertEqual(MosaicFixture.rows(plan.columns), [[0, 1], [2, 3]], "\(count) photos")
            XCTAssertEqual(plan.tileCount, MosaicSpec.maxTiles)
            XCTAssertEqual(plan.overflow, count - MosaicSpec.maxTiles)
            // The count lands on the LAST tile of the last column — the fourth.
            XCTAssertEqual(plan.columns.last?.last, 3)
        }
    }

    /// The rule is one rule, not four cases: every shape is N equal-width columns of equal-height
    /// tiles, and every photo that gets a tile gets exactly one.
    func testEveryShapeGivesEveryPhotoWithATileExactlyOne() {
        for count in 2...9 {
            let flat = PhotoMosaic.shape(count: count).flatMap { $0 }
            XCTAssertEqual(flat.sorted(), Array(0..<min(count, MosaicSpec.maxTiles)), "\(count) photos")
            XCTAssertEqual(Set(flat).count, flat.count, "a photo got two tiles: \(count) photos")
            XCTAssertLessThanOrEqual(PhotoMosaic.shape(count: count).count, MosaicSpec.maxColumns)
        }
    }

    /// And read as ROWS the shape is the table Android (`HPMosaic.AREAS`) and web (`MOSAIC_AREAS`)
    /// declare, ordinal for ordinal — the contract that stops the three builds disagreeing about
    /// which tile is where. This suite places by column, so the transpose is where a four-up's
    /// photos 1 and 2 would silently swap places against the siblings.
    func testTheTableIsTheOneAndroidAndWebDeclare() {
        // design/kotlin/housepour/HPMosaic.kt `AREAS`, web/js/mosaic.js `MOSAIC_AREAS`.
        let siblings: [Int: [[Int]]] = [
            2: [[0, 1]],
            3: [[0, 1], [0, 2]],
            4: [[0, 1], [2, 3]],
        ]
        for count in 2...9 {
            let expected = siblings[min(count, MosaicSpec.maxTiles)]
            XCTAssertEqual(MosaicFixture.rows(PhotoMosaic.shape(count: count)), expected, "\(count) photos")
        }
    }

    // MARK: The ratio

    /// The sentence this exists for: "the block keeps a sane overall ratio instead of letting one
    /// tall photo set the height", and `tokens.json`'s gloss on it — "one panorama among squares
    /// must not set the shape". The album's MEDIAN shape decides, so a lone outlier is outvoted by
    /// the photos around it rather than dragging the block onto its own aspect.
    func testOneTallPhotoDoesNotSetTheBlocksShape() {
        let allLandscape = PhotoMosaic.aspect(columns: [[0], [1, 2]],
                                              aspects: [CGFloat](repeating: MosaicFixture.landscape, count: 3))
        let oneTall = PhotoMosaic.aspect(columns: [[0], [1, 2]],
                                         aspects: [0.4, MosaicFixture.landscape, MosaicFixture.landscape])
        // What the block would be if the tall photo DID set the shape.
        let theTallPhotoWins = max(CGFloat(0.4), MosaicSpec.aspectMin)
        print("[mosaic] allLandscape=\(allLandscape) oneTall=\(oneTall) ifItSetTheShape=\(theTallPhotoWins)")
        XCTAssertEqual(oneTall, allLandscape, accuracy: 1e-6,
                       "the outlier moved the block instead of being outvoted")
        XCTAssertGreaterThan(oneTall, theTallPhotoWins,
                             "the tall photo set the shape instead of being outvoted")
        // The same album on Android and web: median 1.5, two columns over two rows, so `r` itself.
        XCTAssertEqual(oneTall, MosaicFixture.landscape, accuracy: 1e-6)
    }

    /// A panorama among squares is outvoted too — the mirror of the case above, and the assertion
    /// web/test/protocol.test.mjs makes against `mosaicRatio([1, 1, 8], 3, …)`.
    func testAPanoramaAmongSquaresIsOutvoted() {
        let squares = PhotoMosaic.aspect(columns: [[0], [1, 2]],
                                         aspects: [CGFloat](repeating: MosaicFixture.square, count: 3))
        let withPanorama = PhotoMosaic.aspect(columns: [[0], [1, 2]], aspects: [1, 1, 8])
        XCTAssertEqual(withPanorama, squares, accuracy: 1e-6)
        XCTAssertEqual(withPanorama, 1, accuracy: 1e-6)
    }

    /// Two tiles sit in one row, so a cell is half the block's width at its full height: the block
    /// wants twice the photos' shape. Three and four are two rows, so a cell IS the block again and
    /// it wants their shape unchanged. The derivation Android and web both spell out.
    func testTheBlockWantsTwiceTheShapeAtTwoTilesAndTheShapeItselfAtThreeOrFour() {
        // A gentle portrait: the clamp is [0.8, 1.9], so this is the rare shape that survives it
        // both at `r` and at `2 × r` — which is what lets the two cases be told apart at all.
        let r: CGFloat = 0.9
        XCTAssertEqual(PhotoMosaic.aspect(columns: [[0], [1]], aspects: [r, r]), 2 * r, accuracy: 1e-6)
        XCTAssertEqual(PhotoMosaic.aspect(columns: [[0], [1, 2]], aspects: [CGFloat](repeating: r, count: 3)),
                       r, accuracy: 1e-6)
        XCTAssertEqual(PhotoMosaic.aspect(columns: [[0, 2], [1, 3]], aspects: [CGFloat](repeating: r, count: 4)),
                       r, accuracy: 1e-6)
    }

    /// Both ends clamp, so no album can produce a letterbox slit or a block that runs off the card.
    func testTheBlocksRatioIsClampedAtBothEnds() {
        let veryWide = PhotoMosaic.plan(aspects: [16, 16], width: width)
        let veryTall = PhotoMosaic.plan(aspects: [CGFloat](repeating: 0.2, count: 4), width: width)
        XCTAssertEqual(veryWide.aspect, MosaicSpec.aspectMax, accuracy: 1e-6)
        XCTAssertEqual(veryTall.aspect, MosaicSpec.aspectMin, accuracy: 1e-6)
        for count in 2...9 {
            for aspect in [0.05, 0.5, 1, 2, 40] as [CGFloat] {
                let plan = PhotoMosaic.plan(aspects: [CGFloat](repeating: aspect, count: count), width: width)
                XCTAssertGreaterThanOrEqual(plan.aspect, MosaicSpec.aspectMin)
                XCTAssertLessThanOrEqual(plan.aspect, MosaicSpec.aspectMax)
            }
        }
    }

    /// A photo Telegram gave us no dimensions for lays out like a photograph, not like a divide by
    /// zero.
    func testAPhotoWithNoDimensionsFallsBackRatherThanBreakingTheBlock() {
        let ref = PhotoRef(fileId: 1, uniqueId: "u1", width: 0, height: 0, minithumbnail: nil)
        XCTAssertEqual(PhotoMosaic.aspect(of: ref), MosaicSpec.unknownAspect)
        let plan = PhotoMosaic.plan(aspects: [PhotoMosaic.aspect(of: ref), 0, -3], width: width)
        XCTAssertTrue(plan.aspect.isFinite)
        XCTAssertGreaterThan(plan.aspect, 0)
    }

    // MARK: The narrow end

    /// "It reflows at the narrow end rather than overflowing." The width it reflows at is the width
    /// at which a tile would stop being a hit target, because a tile is a control.
    func testItReflowsAtTheNarrowEndRatherThanOverflowing() {
        let roomy = PhotoMosaic.plan(aspects: [CGFloat](repeating: 1, count: 4), width: width)
        XCTAssertFalse(roomy.reflowed)
        XCTAssertEqual(roomy.columns.count, 2)

        // Two columns would put each tile under a hit target: one column instead.
        let tight = 2 * HPTokens.Space.touchMin - 1
        let narrow = PhotoMosaic.plan(aspects: [CGFloat](repeating: 1, count: 4), width: tight)
        print("[mosaic] reflow at \(tight): columns=\(narrow.columns)")
        XCTAssertTrue(narrow.reflowed)
        XCTAssertEqual(narrow.columns.count, 1)
        XCTAssertEqual(narrow.columns.first?.count, 4, "every tile is still there — nothing overflowed")
    }

    /// And on either side of the boundary, a tile is never narrower than a hit target.
    func testATileIsNeverNarrowerThanAHitTarget() {
        for w in stride(from: HPTokens.Space.touchMin, through: MosaicFixture.contentWidth, by: 7) {
            let plan = PhotoMosaic.plan(aspects: [CGFloat](repeating: 1, count: 4), width: w)
            let tile = (w - MosaicSpec.gutter * CGFloat(plan.columns.count - 1)) / CGFloat(plan.columns.count)
            XCTAssertGreaterThanOrEqual(tile, HPTokens.Space.touchMin - 0.001, "at width \(w)")
        }
    }

    /// The gutters are hairlines, and the radius is the media radius — the mosaic reads as one
    /// object, not four cards.
    func testTheGutterIsTheHairline() {
        XCTAssertEqual(MosaicSpec.gutter, HPTokens.borderWidth)
    }

    /// And the clamp is the shared `ratio` token, not a pair of numbers retyped here: Android and
    /// web clamp to these same two, so the same album is the same block on all three.
    func testTheClampIsTheSharedRatioToken() {
        XCTAssertEqual(MosaicSpec.aspectMin, HPTokens.Ratio.mosaicMin)
        XCTAssertEqual(MosaicSpec.aspectMax, HPTokens.Ratio.mosaicMax)
    }
}

// MARK: - Grouping, and the tap

@MainActor
final class PhotoMosaicGroupingTests: XCTestCase {
    /// More than one photo is ONE block, drawn where the first of them sat; everything else keeps
    /// its own place in the list.
    func testMoreThanOnePhotoBecomesOneMosaicWhereTheFirstOneSat() {
        let media: [PostMedia] = [
            .summary("Poll \u{00B7} 3 options"),
            MosaicFixture.photo(0),
            MosaicFixture.photo(1),
            MosaicFixture.photo(2),
            .audio(file: FileRef(fileId: 9, uniqueId: "a9", size: 1, mimeType: "audio/mpeg", fileName: "t.mp3"),
                   title: "Take 3", performer: "Ana", duration: 60),
        ]
        let blocks = PostMediaList.blocks(of: media)
        XCTAssertEqual(blocks.count, 3)
        guard case .single(let first) = blocks[0], case .mosaic(let indices) = blocks[1],
              case .single(let last) = blocks[2] else {
            return XCTFail("blocks: \(blocks)")
        }
        XCTAssertEqual(first, 0)
        XCTAssertEqual(indices, [1, 2, 3])
        XCTAssertEqual(last, 4)
    }

    /// One photo is a photo (§2.11: `HPMedia` at the post width), not a one-tile mosaic.
    func testASinglePhotoIsNotAMosaic() {
        let blocks = PostMediaList.blocks(of: [MosaicFixture.photo(0), .summary("Location")])
        XCTAssertEqual(blocks.count, 2)
        for block in blocks {
            if case .mosaic = block { return XCTFail("a single photo became a mosaic") }
        }
    }

    /// "Tapping any tile opens the carousel at that tile's index." The tile hands back its
    /// MEDIA-LIST index, and the viewer maps that to the page it opens on — past anything in the
    /// list that has no page of its own.
    func testTappingATileOpensTheCarouselAtThatTilesIndex() throws {
        let media: [PostMedia] = [
            .summary("Poll \u{00B7} 3 options"),      // not viewable — no page
            MosaicFixture.photo(0),
            MosaicFixture.photo(1),
            MosaicFixture.photo(2),
        ]
        let blocks = PostMediaList.blocks(of: media)
        guard case .mosaic(let indices) = blocks[1] else { return XCTFail("no mosaic: \(blocks)") }

        for (ordinal, mediaIndex) in indices.enumerated() {
            let request = try XCTUnwrap(ViewerRequest.from(media: media, caption: "",
                                                           tappedMediaIndex: mediaIndex))
            XCTAssertEqual(request.items.count, 3)
            XCTAssertEqual(request.index, ordinal,
                           "tile \(ordinal) (media index \(mediaIndex)) opened page \(request.index)")
        }
    }

    /// And through the post-flavoured request, which is what the card actually calls.
    func testAnAlbumsTilesOpenTheirOwnPages() throws {
        let post = MediaFixture.album(count: 4)
        for tile in 0..<4 {
            let request = try XCTUnwrap(ViewerRequest.from(post, tappedMediaIndex: tile))
            XCTAssertEqual(request.index, tile)
            XCTAssertEqual(request.itemLinks.count, 4)
        }
    }

    /// §2.11.3 has to keep holding when the viewer is opened **from** a viewer, which §2.12 makes a
    /// real path: `CommentRow` renders `PostMediaList` for a comment's own media, `CarouselComments`
    /// hosts that thread inside the open viewer, and tapping one of its tiles assigns `model.viewer`
    /// again with no nil frame between. `ViewerOverlay` keeps the page, the drag and the comments
    /// toggle in `@State`, which SwiftUI preserves unless the view's identity changes — so RootView
    /// hangs `.id(request.openingID)` off it.
    ///
    /// This is the model-layer half of that guard: `openingID` must identify the *opening*. The view
    /// half cannot be measured here, because `ViewerOverlay` reads `AppModel` from the environment
    /// and building one boots TDLib, which the test host must never do (`tgsocialApp.isTestHost`).
    /// So this asserts the property `.id()` is standing on: make `openingID` derived from the post,
    /// the index or anything else about *what* is opened, and reopening lands on the stale page again.
    func testEachOpeningIsItsOwnIdentity() throws {
        let post = MediaFixture.album(count: 4)
        let first = try XCTUnwrap(ViewerRequest.from(post, tappedMediaIndex: 2))
        let second = try XCTUnwrap(ViewerRequest.from(post, tappedMediaIndex: 0))
        XCTAssertNotEqual(first.openingID, second.openingID,
                          "two openings of one album share an identity, so the second keeps the first's page")

        // Including the degenerate case the Android key cannot cover: the same post at the same tile.
        let again = try XCTUnwrap(ViewerRequest.from(post, tappedMediaIndex: 2))
        XCTAssertNotEqual(first.openingID, again.openingID)

        // And it is stable through the value's own lifetime — paging must not re-identify the view,
        // or the TabView would be rebuilt mid-swipe.
        var copy = first
        copy.index = 3
        XCTAssertEqual(first.openingID, copy.openingID, "mutating a request is not a new opening")
    }
}

// MARK: - The memory claim

@MainActor
final class MosaicRenditionTests: XCTestCase {
    /// A tile is a thumbnail. Requesting it at the cell's size rather than the card's is the whole
    /// difference between drawing a 2×2 and decoding four full-width photos to do it.
    func testATileIsDecodedAtTileSizeNotCardSize() {
        let width = MosaicFixture.contentWidth
        let plan = PhotoMosaic.plan(aspects: [CGFloat](repeating: 1, count: 4), width: width)
        let cell = MosaicFixture.cell(plan, width: width)
        let tile = ImageRendition.points(MosaicSpec.renditionEdge(for: cell))
        let card = ImageRendition.card
        print("[mosaic] cell=\(cell) tile=\(tile.maxPixelSize)px card=\(card.maxPixelSize)px")
        XCTAssertLessThan(tile.maxPixelSize, card.maxPixelSize,
                          "a tile asked for card pixels")
        // Four tiles together still cost less than four card decodes would — the point of the
        // exercise, since a mosaic draws four photos where a card drew one.
        XCTAssertLessThan(4 * tile.maxPixelSize * tile.maxPixelSize,
                          4 * card.maxPixelSize * card.maxPixelSize / 2,
                          "four tiles cost more than half of four card decodes")
    }

    /// Renditions are quantised, so a fraction of a point of layout jitter cannot mint a second
    /// decode of the same tile at a size nobody can tell apart from the first.
    func testTheRenditionIsQuantisedSoJitterCannotMintASecondDecode() {
        let a = MosaicSpec.renditionEdge(for: CGSize(width: 235.5, height: 235.5))
        let b = MosaicSpec.renditionEdge(for: CGSize(width: 235.9, height: 236.1))
        XCTAssertEqual(a, b)
        XCTAssertEqual(ImageRendition.points(a), ImageRendition.points(b))
        // It rounds UP, so the tile is never asked for fewer pixels than it draws.
        XCTAssertGreaterThanOrEqual(a, 235.9)
        XCTAssertEqual(a.truncatingRemainder(dividingBy: MosaicSpec.renditionStep), 0, accuracy: 1e-9)
        // A zero cell (the frame before layout) still asks for something legal.
        XCTAssertGreaterThan(MosaicSpec.renditionEdge(for: .zero), 0)
    }

    /// The cell covers, so the edge that matters is the longest one — a tall cell in a 3-up needs
    /// its height, not its width.
    func testTheRenditionFollowsTheLongestEdgeOfTheCell() {
        let tall = MosaicSpec.renditionEdge(for: CGSize(width: 100, height: 300))
        let wide = MosaicSpec.renditionEdge(for: CGSize(width: 300, height: 100))
        XCTAssertEqual(tall, wide)
        XCTAssertGreaterThanOrEqual(tall, 300)
    }
}

// MARK: - The tiles are controls (COMPONENTS.md rule 6)

@MainActor
final class MosaicHitRegionTests: XCTestCase {
    /// Every tile keeps a full `touchMin` in both axes on the assembled card, no two tiles overlap,
    /// and none of them reaches into the post text's tap surface — which is laid out after the
    /// mosaic and would take every point they shared.
    func testEveryTileKeepsAFullRegionAndTilesWithItsNeighbours() throws {
        let regions = measure(photos: 4)
        let text = try XCTUnwrap(regions[PostCardRegion.text], "regions: \(regions.keys.sorted())")
        var rects: [CGRect] = []
        for ordinal in 0..<4 {
            let rect = try XCTUnwrap(regions[MosaicRegion.tile(ordinal)])
            print("[regions] tile\(ordinal)=\(rect)")
            XCTAssertGreaterThanOrEqual(rect.width, HPTokens.Space.touchMin, "tile \(ordinal) is \(rect.width)pt wide")
            XCTAssertGreaterThanOrEqual(rect.height, HPTokens.Space.touchMin, "tile \(ordinal) is \(rect.height)pt tall")
            XCTAssertFalse(rect.intersects(text), "tile \(ordinal) \(rect) reaches into the post text \(text)")
            rects.append(rect)
        }
        for (i, a) in rects.enumerated() {
            for b in rects.dropFirst(i + 1) {
                XCTAssertFalse(a.insetBy(dx: 0.5, dy: 0.5).intersects(b), "tiles overlap: \(a) and \(b)")
            }
        }
    }

    /// The measured four-up reads ACROSS then down, the way Android and web paint it: photo 1 sits
    /// beside photo 0, photo 2 under it. This is the rectangle-level statement of the same contract
    /// `testTheTableIsTheOneAndroidAndWebDeclare` makes about the plan.
    func testTheFourUpReadsAcrossThenDownOnTheAssembledCard() throws {
        let regions = measure(photos: 4)
        let rects = try (0..<4).map { try XCTUnwrap(regions[MosaicRegion.tile($0)]) }
        for (ordinal, rect) in rects.enumerated() { print("[regions] tile\(ordinal)=\(rect)") }
        XCTAssertEqual(rects[1].minY, rects[0].minY, accuracy: 0.5, "photo 1 is not in the top row")
        XCTAssertGreaterThan(rects[1].minX, rects[0].minX, "photo 1 is not to the right of photo 0")
        XCTAssertEqual(rects[2].minX, rects[0].minX, accuracy: 0.5, "photo 2 is not in the leading column")
        XCTAssertGreaterThan(rects[2].minY, rects[0].minY, "photo 2 is not below photo 0")
        // Which leaves the `+N` tile — the last one — in the bottom-right corner.
        XCTAssertEqual(rects[3].minX, rects[1].minX, accuracy: 0.5)
        XCTAssertEqual(rects[3].minY, rects[2].minY, accuracy: 0.5)
    }

    /// Three tiles, where one column has one tile and the other has two: the shape that most easily
    /// leaves a stacked tile under the target.
    func testTheStackedTilesOfAThreeUpAreStillTargets() throws {
        let regions = measure(photos: 3)
        for ordinal in 0..<3 {
            let rect = try XCTUnwrap(regions[MosaicRegion.tile(ordinal)])
            XCTAssertGreaterThanOrEqual(rect.height, HPTokens.Space.touchMin, "tile \(ordinal) is \(rect.height)pt tall")
            XCTAssertGreaterThanOrEqual(rect.width, HPTokens.Space.touchMin)
        }
    }

    private final class RegionBox { var regions: [HPTouchRegion] = [] }

    /// The shipped layout and the shipped tile — its button, its content shape, its region — with
    /// a stand-in for the pixels, which need an `AppModel` to load and occupy no space of their own.
    /// The same substitution `PostHeaderTests` makes for `NodeAvatar`.
    private func measure(photos: Int) -> [String: CGRect] {
        let box = RegionBox()
        let reported = expectation(description: "hit regions reported")
        reported.assertForOverFulfill = false
        let probe = HPCard {
            MosaicLayout(aspects: [CGFloat](repeating: 1, count: photos)) {
                ForEach(0..<photos, id: \.self) { ordinal in
                    MosaicTile(ordinal: ordinal, position: ordinal + 1, total: photos,
                               overflow: 0, onOpen: {}) { _ in
                        HPTokens.Colors.bg2
                    }
                }
            }
            .background(HPTokens.Colors.line)
            .clipShape(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous))
            PostTextBlock(text: RichText(spans: [RichSpan(text: "Four from the session.", kind: .plain, url: nil)]),
                          forwardedFrom: nil, label: "Open thread", onOpen: {}, onDetails: {})
        }
        .frame(width: MosaicFixture.cardWidth)
        .environment(\.hpMeasureTouchTargets, true)
        .hpTouchSpace()
        .onPreferenceChange(HPTouchTargetKey.self) { regions in
            guard !regions.isEmpty else { return }
            box.regions = regions
            reported.fulfill()
        }
        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: HPTokens.Space.columnMax, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        wait(for: [reported], timeout: 5)
        window.isHidden = true
        window.rootViewController = nil

        var out: [String: CGRect] = [:]
        for region in box.regions { out[region.label] = region.rect }
        return out
    }
}
