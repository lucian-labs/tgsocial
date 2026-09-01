// Components — the photo mosaic (PRODUCT.md §2.11.3). A post with more than one photo is a
// mosaic, not a stack: an album is one thing, and reading it as one block is the point.
//
// Three separate problems live in this file, and they are kept apart on purpose.
//
//   `MosaicSpec`   the numbers, each with its derivation. Nothing below writes a literal.
//   `PhotoMosaic`  the LAYOUT RULE as a value: which tiles go in which column, what `+N` the last
//                  one carries, and what overall ratio the block keeps. Pure — no views, no
//                  geometry proxy, no AppModel — so `PhotoMosaicTests` can state §2.11.3's table
//                  as four assertions rather than four screenshots.
//   `MosaicLayout` the SwiftUI `Layout` that places tiles against that rule, and the tile view.
//
// Why a `Layout` and not a `GeometryReader` wrapped in `.aspectRatio`: the block's height depends
// on its width (the reflow at the narrow end changes the column count, which changes the ratio),
// and a `GeometryReader` cannot tell its parent how tall to be. `sizeThatFits` receives the width
// as a proposal and answers with the height, which is exactly the shape of the problem. It also
// hands each tile its own cell size, which is what lets a tile ask the image cache for TILE pixels
// instead of card pixels — a 2×2 of full-width decodes is four times the memory of the mosaic it
// draws (`MediaMemoryTests` pins the ratio).

import SwiftUI

/// Every number the mosaic runs on, with the sentence it comes from. None of these is a literal at
/// a call site.
enum MosaicSpec {
    /// §2.11.3's table is one or two columns and never more: 2 side by side, 3 as one tall tile
    /// plus a stack of two, 4 as two by two.
    static let maxColumns = 2
    /// How many photos get their own tile before the rest collapse into the `+N` count.
    static let maxTiles = 4

    /// The gutter between tiles: the hairline (§2.11.3 "hairline `line` gutters"). It is the border
    /// width because it *is* a border — the `line` colour behind the grid, showing through the gaps.
    static var gutter: CGFloat { HPTokens.borderWidth }

    /// The block "keeps a sane overall ratio rather than letting one tall photo set the height"
    /// (§2.11.3). Two halves to that: the ratio follows the album's MEDIAN photo shape, so one
    /// panorama among squares is outvoted rather than flattening the block — and it is then clamped
    /// to this range.
    ///
    /// The bounds are the `ratio` tokens, not numbers retyped here: `design/tokens.json` carries the
    /// same two for Android (`HPMosaic.ratio`'s `HPTokens.Ratio.mosaicMin` / `mosaicMax`) and web
    /// (`--ratio-mosaic-min` / `--ratio-mosaic-max`), so the three builds clamp the same album to
    /// the same block. Below the floor an album of portraits runs taller than the card it sits in;
    /// above the ceiling a pair of panoramas draws as a letterbox slot.
    static var aspectMin: CGFloat { HPTokens.Ratio.mosaicMin }
    static var aspectMax: CGFloat { HPTokens.Ratio.mosaicMax }

    /// The aspect used for a photo whose dimensions are missing or nonsense. 3:2 is the ordinary
    /// camera frame, so an unknown photo lays out like a photograph rather than like a square.
    static let unknownAspect: CGFloat = 3.0 / 2.0

    /// Renditions are quantised to one hit target, so a fraction of a point of layout jitter cannot
    /// mint a second decode of the same tile at a size no one can tell apart from the first.
    static var renditionStep: CGFloat { HPTokens.Space.touchMin }

    /// The longest edge a tile of `size` should be decoded at, quantised.
    static func renditionEdge(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return renditionStep }
        return (longest / renditionStep).rounded(.up) * renditionStep
    }
}

// MARK: - The layout rule, as a value

/// One mosaic's plan: which tile ordinals sit in which column, the `+N` the last tile carries, and
/// the ratio the whole block keeps.
struct PhotoMosaic: Equatable {
    /// Tile ordinals (0-based, into the mosaic's own photo list), leading column first, each column
    /// listed top to bottom.
    let columns: [[Int]]
    /// The count on the last tile — `photos - maxTiles` — or 0 when every photo has a tile.
    let overflow: Int
    /// width / height of the whole block, clamped to `MosaicSpec`'s range.
    let aspect: CGFloat
    /// The narrow end reflowed this into a single column rather than letting it overflow.
    let reflowed: Bool

    var tileCount: Int { columns.reduce(0) { $0 + $1.count } }

    /// §2.11.3's table, before any width is known — the same table Android (`HPMosaic.AREAS`) and
    /// web (`MOSAIC_AREAS`, and the `grid-template-areas` it hands the cascade) declare, so the
    /// three platforms cannot disagree about which tile is where:
    ///
    /// ```
    ///   2   a b       two tiles side by side, equal width
    ///   3   a b       one TALL leading tile with two stacked beside it
    ///       a c
    ///   4   a b       two by two — album order reads left to right, THEN down
    ///       c d
    /// ```
    ///
    /// The siblings spell that table as ROWS because their placers walk rows; `MosaicLayout` walks
    /// columns, so the same table is transposed here. That is the whole reason the four-up is
    /// `[[0, 2], [1, 3]]` and not `[[0, 1], [2, 3]]`: the album's second photo is the TOP RIGHT
    /// tile — the head of the trailing column — not the one under the first.
    ///
    /// Written as "N equal-width columns, each an equal-height stack" rather than as four cases
    /// with their own frames: the three shapes are the same rule with different column contents,
    /// and the `+N` case is the 4 case plus a count.
    static func shape(count: Int) -> [[Int]] {
        switch max(count, 0) {
        case 0: return []
        case 1: return [[0]]
        case 2: return [[0], [1]]
        case 3: return [[0], [1, 2]]
        default: return [[0, 2], [1, 3]]
        }
    }

    /// The plan for `aspects` (one per photo, width / height) inside `width` points.
    static func plan(aspects: [CGFloat], width: CGFloat) -> PhotoMosaic {
        let count = aspects.count
        var columns = shape(count: count)
        let overflow = max(0, count - MosaicSpec.maxTiles)
        guard !columns.isEmpty else {
            return PhotoMosaic(columns: [], overflow: 0, aspect: MosaicSpec.aspectMax, reflowed: false)
        }

        // "It reflows at the narrow end rather than overflowing" (§2.11.3). A tile is a control —
        // tapping it opens the carousel — so the width at which two columns stop being allowed is
        // the width at which a tile would stop being a hit target.
        var reflowed = false
        let tileWidth = (width - MosaicSpec.gutter * CGFloat(columns.count - 1)) / CGFloat(columns.count)
        if columns.count > 1, tileWidth < HPTokens.Space.touchMin {
            columns = [Array(0..<min(count, MosaicSpec.maxTiles))]
            reflowed = true
        }

        return PhotoMosaic(columns: columns, overflow: overflow,
                           aspect: aspect(columns: columns, aspects: aspects), reflowed: reflowed)
    }

    /// The block's ratio, derived exactly as `HPMosaic.ratio` (Android) and `mosaicRatio` (web) do —
    /// the shape of an album must not depend on which build is drawing it.
    ///
    /// Every arrangement is equal-width columns of equal-height tiles, so a cell's own ratio is the
    /// block's times `rows / columns`. Solve "the cells look like the photos" for the block and it
    /// wants `r × columns / rows`, where `r` is the album's **median** photo ratio: `2 × r` for the
    /// two-up (one row), `r` for the three- and four-up (two rows). The median is §2.11.3's "rather
    /// than letting one tall photo set the height" and `tokens.json`'s "one panorama among squares
    /// must not set the shape" — the outlier is outvoted rather than allowed to drag the block.
    ///
    /// Then clamp, which is what stops a column of portraits painting a block taller than the card,
    /// and why a tall photo **covers** its cell instead of setting the height. An album with no
    /// usable shape at all (nothing but photos Telegram declared no size for) falls back to the
    /// geometric middle of the clamp — centred in ratio rather than in arithmetic — instead of to a
    /// guess about the picture, again as the siblings do.
    static func aspect(columns: [[Int]], aspects: [CGFloat]) -> CGFloat {
        guard let rows = columns.map(\.count).max(), rows > 0 else { return MosaicSpec.aspectMax }
        let shown: [CGFloat] = columns.flatMap { $0 }.compactMap { tile in
            guard aspects.indices.contains(tile) else { return nil }
            let a = aspects[tile]
            return a.isFinite && a > 0 ? a : nil
        }
        guard let r = median(shown) else {
            return (MosaicSpec.aspectMin * MosaicSpec.aspectMax).squareRoot()
        }
        let wanted = r * CGFloat(columns.count) / CGFloat(rows)
        return min(max(wanted, MosaicSpec.aspectMin), MosaicSpec.aspectMax)
    }

    /// The middle value — one panorama in an album of squares must not set the shape.
    private static func median(_ values: [CGFloat]) -> CGFloat? {
        let xs = values.sorted()
        guard !xs.isEmpty else { return nil }
        let mid = xs.count / 2
        return xs.count % 2 == 1 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2
    }

    /// width / height for a photo, falling back when Telegram gives us no dimensions.
    static func aspect(of photo: PhotoRef) -> CGFloat {
        guard photo.width > 0, photo.height > 0 else { return MosaicSpec.unknownAspect }
        return CGFloat(photo.width) / CGFloat(photo.height)
    }
}

// MARK: - The Layout

/// Places one subview per tile against `PhotoMosaic.plan`. Equal-width columns, equal-height rows
/// inside each column, one hairline gutter between neighbours.
struct MosaicLayout: Layout {
    let aspects: [CGFloat]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? HPTokens.Space.columnMax
        guard width > 0 else { return .zero }
        let plan = PhotoMosaic.plan(aspects: aspects, width: width)
        return CGSize(width: width, height: (width / plan.aspect).rounded())
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = PhotoMosaic.plan(aspects: aspects, width: bounds.width)
        guard !plan.columns.isEmpty else { return }
        let gutter = MosaicSpec.gutter
        let columnWidth = (bounds.width - gutter * CGFloat(plan.columns.count - 1)) / CGFloat(plan.columns.count)
        for (c, column) in plan.columns.enumerated() {
            guard !column.isEmpty else { continue }
            let rowHeight = (bounds.height - gutter * CGFloat(column.count - 1)) / CGFloat(column.count)
            let x = bounds.minX + CGFloat(c) * (columnWidth + gutter)
            for (r, tile) in column.enumerated() {
                guard subviews.indices.contains(tile) else { continue }
                subviews[tile].place(at: CGPoint(x: x, y: bounds.minY + CGFloat(r) * (rowHeight + gutter)),
                                     anchor: .topLeading,
                                     proposal: ProposedViewSize(width: columnWidth, height: rowHeight))
            }
        }
    }
}

// MARK: - The view

/// Labels the mosaic's hit regions report under `hpMeasureTouchTargets`.
enum MosaicRegion {
    static func tile(_ ordinal: Int) -> String { "mosaic tile \(ordinal)" }
}

/// The mosaic as it ships: `radius-media` on the OUTER corners only, the `line` colour behind the
/// grid so the gutters read as hairlines, and one object where four photos used to be four cards.
struct PhotoMosaicView: View {
    /// The album's photos in posting order, each with the media-list index that opens it.
    let photos: [(mediaIndex: Int, preview: PhotoRef, full: PhotoRef)]
    /// Tapping a tile opens the carousel **at that tile's index** (§2.11.3).
    let onOpen: (Int) -> Void

    private var shown: [(mediaIndex: Int, preview: PhotoRef, full: PhotoRef)] {
        Array(photos.prefix(MosaicSpec.maxTiles))
    }
    private var overflow: Int { max(0, photos.count - MosaicSpec.maxTiles) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous)
        MosaicLayout(aspects: shown.map { PhotoMosaic.aspect(of: $0.preview) }) {
            ForEach(Array(shown.enumerated()), id: \.offset) { ordinal, photo in
                MosaicTile(ordinal: ordinal,
                           position: ordinal + 1,
                           total: photos.count,
                           // §2.11.3: the `+N` sits on the fourth tile, over a scrim.
                           overflow: ordinal == shown.count - 1 ? overflow : 0,
                           onOpen: { onOpen(photo.mediaIndex) }) { cell in
                    MosaicTileImage(preview: photo.preview, cell: cell)
                }
            }
        }
        // The gutters ARE this fill, seen through the one-point gaps the layout leaves.
        .background(HPTokens.Colors.line)
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(photos.count) photos")
    }
}

/// One tile: a tap target, the `+N` chrome, and whatever fills the cell.
///
/// Generic over its content for the same reason `PostHeader` is generic over its avatar: the pixels
/// need an `AppModel` to load and the *geometry* does not, so `MosaicHitRegionTests` can measure the
/// shipped tile — its button, its content shape, its region, its place in the layout — without one.
/// The `+N` scrim lives here rather than in the image because it is chrome, not photograph.
struct MosaicTile<Content: View>: View {
    let ordinal: Int
    let position: Int
    let total: Int
    let overflow: Int
    let onOpen: () -> Void
    let content: (CGSize) -> Content

    init(ordinal: Int, position: Int, total: Int, overflow: Int,
         onOpen: @escaping () -> Void, @ViewBuilder content: @escaping (CGSize) -> Content) {
        self.ordinal = ordinal; self.position = position; self.total = total
        self.overflow = overflow; self.onOpen = onOpen; self.content = content
    }

    var body: some View {
        Button(action: onOpen) {
            GeometryReader { geo in
                ZStack {
                    HPTokens.Colors.bg2
                    content(geo.size)
                    if overflow > 0 {
                        HPTokens.Colors.scrim
                        HPPill("+\(overflow)", tone: .neutral)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hpTouchRegion(MosaicRegion.tile(ordinal))
        .accessibilityLabel(overflow > 0
                            ? "Photo \(position) of \(total), and \(overflow) more"
                            : "Photo \(position) of \(total)")
    }
}

/// The pixels. Split out of the tile so the decode's `.task` is keyed on the CELL SIZE: a tile is a
/// thumbnail, and asking for a card-width decode of four photos to draw a 2×2 is four times the
/// bytes for none of the resolution.
private struct MosaicTileImage: View {
    @Environment(AppModel.self) private var model
    let preview: PhotoRef
    let cell: CGSize
    @State private var image: UIImage?
    @State private var blurred = false

    private var rendition: ImageRendition { .points(MosaicSpec.renditionEdge(for: cell)) }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    // §2.11.3: tiles fill their cell (`cover`).
                    .scaledToFill()
                    .blur(radius: blurred ? HPMetric.mediaBlur : 0)
            }
        }
        .animation(HPMotion.color, value: image == nil)
        .task(id: TileKey(uniqueId: preview.uniqueId, edge: MosaicSpec.renditionEdge(for: cell))) {
            await load()
        }
    }

    private func load() async {
        guard cell.width > 0, cell.height > 0 else { return }
        let want = rendition
        if let hit = model.media.cached(preview, want) { image = hit; blurred = false; return }
        if image == nil {
            image = model.media.minithumbnail(preview)
            blurred = image != nil
        }
        if let loaded = await model.media.image(for: preview, rendition: want) {
            image = loaded
            blurred = false
        }
    }

    /// What re-runs the decode: the photo, and the quantised size of the cell it landed in.
    private struct TileKey: Equatable {
        let uniqueId: String
        let edge: CGFloat
    }
}
