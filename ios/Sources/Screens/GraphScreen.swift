// Screens — Graph (PRODUCT.md §2.7): fixed radial layout on a Canvas, tap a dot → profile, drag to pan.

import SwiftUI

struct GraphScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pan: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        @Bindable var model = model
        Screen(refresh: { await model.refreshDiscovery(force: true) }) {
            HPTabs(items: Tab.allCases, selected: $model.tab) { $0.label }
            HPSectionMark("Your network")
            HPCard(padded: false) {
                GraphCanvas(layout: layout, pan: pan)
                    .frame(height: Self.canvasHeight)
                    .background(GeometryReader { g in Color.clear.onAppear { canvasSize = g.size }.onChange(of: g.size) { _, n in canvasSize = n } })
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                pan = CGSize(width: dragStart.width + v.translation.width, height: dragStart.height + v.translation.height)
                            }
                            .onEnded { v in
                                let moved = hypot(v.translation.width, v.translation.height)
                                if moved < Self.tapSlop {
                                    pan = dragStart
                                    if let hit = layout.hit(at: v.location, pan: pan, size: canvasSize) { model.path.append(.profile(username: hit)) }
                                } else {
                                    dragStart = pan
                                }
                            }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: HPTokens.Radius.card, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Network graph: you, \(model.direct.count) direct, \(model.nearby.count) at distance two")
            }

            HPSectionMark("Direct", count: model.direct.count)
            if model.direct.isEmpty {
                HPCard { HPMuted("Follow someone and they appear here.") }
            } else {
                HPListCard {
                    ForEach(Array(model.direct.enumerated()), id: \.element.id) { i, n in
                        NodeRow(node: n, isLast: i == model.direct.count - 1) { model.path.append(.profile(username: n.username)) }
                    }
                }
            }

            HPSectionMark("+1", count: model.nearby.count)
            if model.nearby.isEmpty {
                HPCard { HPMuted("Follow someone and their people appear here.") }
            } else {
                HPListCard {
                    ForEach(Array(model.nearby.enumerated()), id: \.element.id) { i, e in
                        NodeRow(node: e.node, followedBy: e.followedByCount, isLast: i == model.nearby.count - 1) {
                            model.path.append(.profile(username: e.node.username))
                        }
                    }
                }
            }
        }
        .task { if model.direct.isEmpty, !model.exploreLoading { await model.refreshDiscovery() } }
    }

    static let canvasHeight: CGFloat = HPTokens.Space.columnMax * 0.6
    static let tapSlop: CGFloat = HPTokens.Space.rowGap

    private var layout: GraphLayout {
        GraphLayout(me: model.myNode?.username ?? "", direct: model.direct.map(\.username),
                    plusOne: model.nearby.map(\.node.username), edges: model.edges)
    }
}

/// Angles evenly spaced; ring radii derived from the canvas size. No physics.
struct GraphLayout {
    let me: String
    let direct: [String]
    let plusOne: [String]
    let edges: [String: [String]]

    struct Dot { let username: String; let point: CGPoint; let radius: CGFloat; let ring: Int }

    func dots(in size: CGSize) -> [Dot] {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let r1 = min(size.width, size.height) * 0.28
        let r2 = min(size.width, size.height) * 0.46
        var out = [Dot(username: me, point: centre, radius: HPMetric.graphDotYou / 2, ring: 0)]
        for (i, u) in direct.enumerated() {
            let a = angle(i, of: direct.count, offset: -.pi / 2)
            out.append(Dot(username: u, point: CGPoint(x: centre.x + CGFloat(Foundation.cos(a)) * r1, y: centre.y + CGFloat(Foundation.sin(a)) * r1), radius: HPMetric.graphDotFollow / 2, ring: 1))
        }
        for (i, u) in plusOne.enumerated() {
            let a = angle(i, of: plusOne.count, offset: -.pi / 2 + .pi / Double(max(plusOne.count, 1)))
            out.append(Dot(username: u, point: CGPoint(x: centre.x + CGFloat(Foundation.cos(a)) * r2, y: centre.y + CGFloat(Foundation.sin(a)) * r2), radius: HPMetric.graphDotPlusOne / 2, ring: 2))
        }
        return out
    }

    private func angle(_ i: Int, of n: Int, offset: Double) -> Double {
        offset + Double(i) / Double(max(n, 1)) * 2 * .pi
    }

    func lines(in size: CGSize) -> [(CGPoint, CGPoint)] {
        let all = dots(in: size)
        var index: [String: CGPoint] = [:]
        for d in all { index[Username.key(d.username)] = d.point }
        guard let centre = index[Username.key(me)] else { return [] }
        var out: [(CGPoint, CGPoint)] = []
        for u in direct {
            guard let p = index[Username.key(u)] else { continue }
            out.append((centre, p))
            for f in edges[Username.key(u)] ?? [] {
                if let q = index[Username.key(f)], Username.key(f) != Username.key(me) { out.append((p, q)) }
            }
        }
        return out
    }

    /// Nearest dot within a 40pt target, in canvas coordinates (pan removed).
    func hit(at location: CGPoint, pan: CGSize, size: CGSize) -> String? {
        let p = CGPoint(x: location.x - pan.width, y: location.y - pan.height)
        let reach = HPTokens.Space.touchMin / 2
        return dots(in: size)
            .filter { !$0.username.isEmpty }
            .map { ($0.username, hypot($0.point.x - p.x, $0.point.y - p.y)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }
}

struct GraphCanvas: View {
    let layout: GraphLayout
    let pan: CGSize

    var body: some View {
        Canvas { context, size in
            context.translateBy(x: pan.width, y: pan.height)
            for (a, b) in layout.lines(in: size) {
                var path = Path()
                path.move(to: a); path.addLine(to: b)
                context.stroke(path, with: .color(HPTokens.Colors.line), lineWidth: HPTokens.borderWidth)
            }
            for d in layout.dots(in: size) {
                let rect = CGRect(x: d.point.x - d.radius, y: d.point.y - d.radius, width: d.radius * 2, height: d.radius * 2)
                let color: Color = d.ring == 0 ? HPTokens.Colors.accent : d.ring == 1 ? HPTokens.Colors.ink : HPTokens.Colors.faint
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .background(HPTokens.Colors.panel)
    }
}
