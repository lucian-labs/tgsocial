// Components — a WaveLoop drop inside its Bluesky card (PRODUCT.md §2.36.1, PROTOCOL.md §12.12).
//
// The card starts as §2.36's link card and only becomes the drop once the drop is read, so every
// failure on the way — the record, a blob, a kind this build does not know — leaves the link card
// exactly as it was (rule 8). What moves (the stereo wiggle, the depth parallax) moves only while
// the card is on screen, the app is in front and no viewer covers it (rule 11). Memory: the views
// hold card-width renditions from the shared image budget and let go of them on disappear; the
// files they show are pinned in the disk cache while shown.

import AVFoundation
import SwiftUI

// MARK: - The drop, once read

/// A record rule 2 accepted, where its blobs come from, what rule 7 says to load, and the poster.
struct ResolvedDrop: Equatable {
    let record: DropRecord
    let source: DropSource
    let plan: DropPlan
    /// The post view's own image, already on the AppView's CDN (rule 7).
    let posterURL: String?

    func blob(_ field: String) -> DropBlob? { record.blobs[field] }
    func blobs(_ fields: [String]) -> [DropBlob] { fields.compactMap { record.blobs[$0] } }

    /// §2.36.1 "Record read": the drop's aspect ratio, clamped to 0.5–2 like a single image; the
    /// link card's 1.91 when the record gives none. Decided once, so nothing below the box moves
    /// when the drop replaces the poster.
    var boxAspect: CGFloat {
        guard let a = plan.aspect, a.isFinite, a > 0 else { return BlueskyLinkCard.aspect }
        return min(max(CGFloat(a), 0.5), 2)
    }
}

enum StereoMode: String, CaseIterable, Hashable {
    case wiggle, anaglyph, sideBySide

    var label: String {
        switch self {
        case .wiggle: return DropCopy.wiggle
        case .anaglyph: return DropCopy.anaglyph
        case .sideBySide: return DropCopy.sideBySide
        }
    }
}

struct StereoSettings: Equatable {
    var mode: StereoMode = .wiggle
    /// A fraction of the box width (rule 10).
    var shift = 0.0
    /// Side by side only: parallel ↔ cross-eyed.
    var swap = false
}

/// The single-item `HPTabs` for `Sway` and `Spin` (§2.36.1: "selected while on").
enum DropToggle: Hashable { case on, off }

enum BlueskyLinkCard {
    /// §2.36's link-card thumb aspect, 1.91:1 — the Open Graph card.
    static let aspect: CGFloat = 1.91
}

// MARK: - The card

/// §2.36.1: the link card of a post that announces a drop by its own poster.
struct DropCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let post: BlueskyPost
    let external: BlueskyExternal
    let ref: String
    /// The feed's post, for the dock's row tap (§2.11). Nil where the card has none.
    var feedPost: Post?

    @State private var drop: ResolvedDrop?
    /// Rule 8: the link card, for good, for this drop on this screen.
    @State private var failed = false
    @State private var onScreen = false
    @State private var stereo = StereoSettings()
    @State private var sway = true

    /// What the card is showing: a kind, or `link` (rule 8). Reported under `DropPhaseKey`.
    private var phase: String {
        guard let drop, !failed, let kind = drop.plan.kind else { return "link" }
        return kind.rawValue
    }

    private var posterURL: String? { external.thumb ?? post.images.first?.thumb ?? post.videoThumb }

    /// Rule 11: draw only on screen, in front, and not under a viewer.
    private var animating: Bool {
        onScreen && scenePhase == .active && model.viewer == nil && model.dropViewer == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HPTokens.Space.tabsGap) {
            if let drop, !failed, let kind = drop.plan.kind {
                media(drop, kind: kind)
                controls(kind)
            } else {
                linkMedia
            }
            Button { model.open(external.uri) } label: {
                VStack(alignment: .leading, spacing: HPTokens.Space.tabsGap) {
                    if !external.title.isEmpty { HPBody(external.title, strong: true).lineLimit(2).multilineTextAlignment(.leading) }
                    HPMonoSmall(external.domain, color: HPTokens.Colors.faint).lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: HPTokens.Space.touchMin, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open link \(external.title.isEmpty ? external.domain : external.title)")
        }
        .background(DropVisibility(onScreen: $onScreen))
        .transformPreference(DropPhaseKey.self) { $0.append("card:" + phase) }
        // Rule 1: read after 300 ms on screen. A fling past the card cancels the sleep and reads
        // nothing; coming back on screen after a `.later` asks again.
        .task(id: onScreen) {
            guard onScreen, drop == nil, !failed else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await resolve(tapped: false)
        }
    }

    // MARK: First paint

    /// §2.36's link card image, as it is today.
    private var linkMedia: some View {
        Button { Task { await tapBeforeRead() } } label: {
            ZStack {
                if let posterURL {
                    BlueskyRemoteImage(url: posterURL, aspect: BlueskyLinkCard.aspect, alt: external.title)
                } else {
                    RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.bg2)
                        .aspectRatio(BlueskyLinkCard.aspect, contentMode: .fit)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open link \(external.title.isEmpty ? external.domain : external.title)")
    }

    /// Rule 1's "or is tapped": a tap before the read reads it now, then acts as the drop would;
    /// anything short of a drop opens the link, which is what the link card does.
    private func tapBeforeRead() async {
        // A rate limit on a tap is §2.39's toast, and the tap stops there.
        if drop == nil, !failed, await resolve(tapped: true) { return }
        guard let drop, !failed, let kind = drop.plan.kind else {
            model.open(external.uri)
            return
        }
        switch kind {
        case .image, .model, .stereo, .depth: openViewer(drop)
        case .audio, .video: break
        }
    }

    /// True when a tap met a rate limit and was told so.
    @discardableResult
    private func resolve(tapped: Bool) async -> Bool {
        switch await model.drops.resolve(ref) {
        case .drop(let record, let source):
            let plan = Atproto.dropPlan(record, thumb: posterURL != nil)
            guard !plan.isLink else { failed = true; return false }
            stereo.shift = plan.shift ?? 0
            // Rule 11: Reduce Motion opens stereo side by side; wiggle is one tap away.
            if reduceMotion { stereo.mode = .sideBySide }
            drop = ResolvedDrop(record: record, source: source, plan: plan, posterURL: posterURL)
        case .none:
            failed = true
        case .later(let seconds):
            // Not an answer: nothing changes, and the card asks again next time it is on screen.
            if tapped, let seconds {
                model.showToast(AtprotoError.rateLimited(seconds: seconds).errorDescription ?? "", tone: .bad)
                return true
            }
        }
        return false
    }

    private func openViewer(_ drop: ResolvedDrop) {
        model.dropViewer = DropViewerRequest(post: post, title: external.title, drop: drop, stereo: stereo, sway: sway)
    }

    // MARK: Per kind (§2.36.1's table)

    @ViewBuilder private func media(_ drop: ResolvedDrop, kind: DropKind) -> some View {
        let fail = { failed = true }
        switch kind {
        case .stereo:
            DropStereoSurface(drop: drop, settings: stereo, active: animating, visible: onScreen, onFail: fail) { openViewer(drop) }
        case .depth:
            DropDepthSurface(drop: drop, sway: sway, active: animating, visible: onScreen, inViewer: false, onFail: fail) { openViewer(drop) }
        case .audio:
            VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                DropPoster(drop: drop)
                if let media = drop.blob("media") {
                    DropAudioRow(blob: media, source: drop.source, title: external.title.isEmpty ? post.name : external.title,
                                 performer: post.name, durationMs: drop.record.durationMs, feedPost: feedPost)
                }
            }
        case .video:
            if let media = drop.blob("media") {
                DropVideoSurface(drop: drop, blob: media, onExpand: { openViewer(drop) })
            }
        case .image, .model:
            Button { openViewer(drop) } label: {
                DropPoster(drop: drop, pill: kind.pill)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(kind == .model ? DropCopy.modelPill : "Image")
        }
    }

    /// §2.36.1: `HPTabs` under the media, stereo and depth only.
    @ViewBuilder private func controls(_ kind: DropKind) -> some View {
        switch kind {
        case .stereo:
            HPTabs(items: StereoMode.allCases, selected: $stereo.mode, label: \.label)
        case .depth:
            HPTabs(items: [DropToggle.on], selected: Binding(get: { sway ? .on : .off }, set: { _ in sway.toggle() }),
                   label: { _ in DropCopy.sway })
        default:
            EmptyView()
        }
    }
}

// MARK: - On screen

/// What each drop view is showing, in tree order: `card:<kind>` or `card:link`;
/// `stereo:ready` / `depth:ready` once the pixels are in; `canvas:<mode>` for the stereo mode
/// drawn; and `wiggle:moving|paused` / `depth:moving|paused` for whether the view's timeline runs
/// (rule 11). Costs one small array per card; it is how a test watches rule 8's fallback and
/// rule 11's pausing happen on the shipped view rather than on a model of it.
struct DropPhaseKey: PreferenceKey {
    static var defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

/// Whether the card intersects its scroll view's visible bounds — the same test `InlineVideoView`
/// pauses by, so a card in a non-lazy column (the Thread screen) still knows it scrolled away.
/// Outside any scroll view (a test host, a sheet) it is on screen while it is in the hierarchy.
struct DropVisibility: View {
    @Binding var onScreen: Bool

    var body: some View {
        GeometryReader { proxy in
            let visible = proxy.bounds(of: .scrollView).map { $0.intersects(CGRect(origin: .zero, size: proxy.size)) } ?? true
            Color.clear
                .onChange(of: visible, initial: true) { _, v in onScreen = v }
                .onDisappear { onScreen = false }
        }
    }
}

// MARK: - Poster

/// The poster: the post view's CDN image (zero PDS cost), else `preview` off the PDS when rule 7
/// put it on screen. Drawn at the box's aspect; a pill bottom left for the 3D kinds.
struct DropPoster: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    var pill: String?
    @State private var image: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous)
        // The box sizes itself from the drop's aspect and the column; the image only fills it, as
        // an overlay. A fill image as a sibling in a ZStack under `maxWidth: .infinity` grew the
        // frame to its filled size: a 4:3 poster in a model's 1:1 box ran off the column's edge and
        // took the pill with it (seen in the Debug drop gallery, 2026-09-25).
        shape.fill(HPTokens.Colors.bg2)
            .aspectRatio(drop.boxAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipShape(shape)
            .overlay(alignment: .bottomLeading) {
                if let pill { HPPill(pill).padding(HPTokens.Space.rowGap) }
            }
            .task(id: drop.record.ref) { image = await load() }
            .onDisappear {
                image = nil
                if let p = drop.blob("preview"), drop.plan.onScreen.contains("preview") { model.drops.release(p.cid) }
            }
    }

    private func load() async -> UIImage? {
        if let url = drop.posterURL { return await BlueskyImages.load(url, maxPoints: HPTokens.Space.columnMax) }
        guard let p = drop.blob("preview"), drop.plan.onScreen.contains("preview") else { return nil }
        model.drops.fetch(p, from: drop.source, priority: .screen)
        guard await model.drops.file(p.cid) != nil else { return nil }
        return await model.drops.image(p.cid, .card)
    }
}

// MARK: - Stereo

/// Loads both eyes on screen (rule 7), shows the poster and the ring until they are in, then the
/// pair. Any failure is the link card (rule 8) — `onFail` — unless it was a cancel: the reader's
/// own ring, or a cancel that was nobody's failure (the card left the screen, another view
/// cancelled the shared download), which leaves the poster waiting to be asked again.
struct DropStereoSurface: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    let settings: StereoSettings
    let active: Bool
    /// Inside the scroll view's bounds. A non-lazy column (the Thread screen) keeps the card in
    /// the hierarchy after it scrolls away, so `onDisappear` never comes; leaving the bounds is
    /// leaving the screen — rule 5's cancel, rule 6's unpin and rule 9's renditions all go.
    var visible = true
    let onFail: () -> Void
    let onOpen: () -> Void

    @State private var left: UIImage?
    @State private var right: UIImage?
    @State private var cancelled = false
    @State private var attempt = 0
    @State private var pinned: [String] = []
    /// CIDs this card has asked the store for at screen priority and not yet let go of. Only its
    /// own demand is released: the same eyes on another card (a repost) keep downloading.
    @State private var demanded: [String] = []

    private var eyes: [DropBlob] { drop.blobs(["left", "right"]) }

    var body: some View {
        ZStack {
            if let left, let right {
                Button(action: onOpen) {
                    StereoCanvas(left: left, right: right, settings: settings, active: active)
                        .aspectRatio(drop.boxAspect, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous))
                        .overlay(alignment: .bottomLeading) { HPPill(DropCopy.stereoPill).padding(HPTokens.Space.rowGap) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(DropCopy.stereoPill), \(settings.mode.label)")
            } else {
                DropLoadingPoster(drop: drop, blobs: eyes, pill: DropCopy.stereoPill, cancelled: $cancelled) { attempt += 1 }
            }
        }
        .transformPreference(DropPhaseKey.self) { if left != nil, right != nil { $0.append("stereo:ready") } }
        // Keyed on visibility too: leaving the bounds cancels a load in flight (so nothing it was
        // awaiting pins or draws afterwards) and unloads; coming back loads again.
        .task(id: DropLoadKey(attempt: attempt, visible: visible)) {
            if visible { await load() } else { unload() }
        }
        .onDisappear { unload() }
    }

    private func load() async {
        guard !cancelled else { return }
        demanded = eyes.map(\.cid)
        let files = await model.drops.files(eyes, from: drop.source, priority: .screen)
        guard !Task.isCancelled else { return }
        if files != nil { demanded = [] }
        guard files != nil, eyes.count == 2 else {
            switch DropLoadOutcome.after(model.drops.failure(eyes), readerCancelled: cancelled) {
            case .waitForTap: cancelled = true
            case .fallBack: onFail()
            case .nothing: break
            }
            return
        }
        for b in eyes { model.drops.pin(b.cid) }
        pinned = eyes.map(\.cid)
        async let l = model.drops.image(eyes[0].cid, .card)
        async let r = model.drops.image(eyes[1].cid, .card)
        let (li, ri) = await (l, r)
        guard !Task.isCancelled else { return }
        guard let li, let ri else { onFail(); return }
        left = li
        right = ri
    }

    private func unload() {
        for cid in demanded { model.drops.release(cid) }
        demanded = []
        for cid in pinned { model.drops.unpin(cid) }
        pinned = []
        left = nil
        right = nil
    }
}

/// The poster with the gold ring over it while `blobs` download (§2.36.1 "Loading"). Tapping the
/// ring cancels; tapping the poster after that starts again.
struct DropLoadingPoster: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    let blobs: [DropBlob]
    var pill: String?
    @Binding var cancelled: Bool
    let restart: () -> Void

    var body: some View {
        ZStack {
            DropPoster(drop: drop, pill: pill)
            if cancelled {
                // §2.36.1: after a cancel, the poster itself starts it again — no extra control.
                Button {
                    cancelled = false
                    restart()
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pill ?? "")
            } else if blobs.contains(where: { model.drops.state($0.cid).active }) {
                HPProgressRing(progress: model.drops.progress(blobs)) {
                    cancelled = true
                    for b in blobs { model.drops.cancel(b.cid) }
                }
            }
        }
    }
}

/// A surface's load task identity: a restart after the reader's cancel, or a change of visibility.
struct DropLoadKey: Hashable {
    let attempt: Int
    let visible: Bool
}

/// What a stereo or depth card does when its on-screen blobs did not all arrive.
enum DropLoadOutcome: Equatable {
    /// Rule 8: a failure the reader did not ask for is the link card.
    case fallBack
    /// A cancel that was not a failure — the card scrolled away and back while its download was
    /// still unwinding, or another view (a ring, the viewer) cancelled the shared download. The
    /// poster waits, and a tap starts it again (§2.36.1 "Loading"), as after the reader's cancel.
    case waitForTap
    /// The reader cancelled this card's ring: it already shows the poster that restarts on tap.
    case nothing

    static func after(_ failure: DropFailure?, readerCancelled: Bool) -> DropLoadOutcome {
        if readerCancelled { return .nothing }
        return failure == .cancelled ? .waitForTap : .fallBack
    }
}

/// The three stereo modes, WaveLoop's maths (rule 10). No Metal: two SwiftUI images, offset,
/// colour-multiplied or side by side. The anaglyph is the viewer's own recipe — the left eye
/// through red, the right through cyan, added — so it costs no third bitmap.
struct StereoCanvas: View {
    let left: UIImage
    let right: UIImage
    let settings: StereoSettings
    let active: Bool
    @State private var start = Date()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            switch settings.mode {
            case .wiggle:
                TimelineView(WiggleSchedule(start: start, paused: !active)) { ctx in
                    eye(StereoMath.eye(at: ctx.date.timeIntervalSince(start)), size: size)
                }
            case .anaglyph:
                ZStack {
                    Color.black
                    eye(.left, size: size).colorMultiply(Color(red: 1, green: 0, blue: 0))
                    eye(.right, size: size).colorMultiply(Color(red: 0, green: 1, blue: 1)).blendMode(.plusLighter)
                }
                .compositingGroup()
            case .sideBySide:
                let pane = CGSize(width: max((size.width - Self.divider) / 2, 1), height: size.height)
                HStack(spacing: Self.divider) {
                    eye(settings.swap ? .right : .left, size: pane)
                    eye(settings.swap ? .left : .right, size: pane)
                }
                .background(HPTokens.Colors.bg)
            }
        }
        .transformPreference(DropPhaseKey.self) {
            $0.append("canvas:" + settings.mode.rawValue)
            if settings.mode == .wiggle { $0.append(active ? "wiggle:moving" : "wiggle:paused") }
        }
    }

    /// Rule 10: "two half-width boxes with a 2 pt divider in the background colour".
    static let divider: CGFloat = 2

    /// One eye cover-fit into `size`, shifted by its half of `shift × width`.
    private func eye(_ which: StereoMath.Eye, size: CGSize) -> some View {
        Image(uiImage: which == .left ? left : right)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .offset(x: StereoMath.offset(which, shift: settings.shift, width: size.width))
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityHidden(true)
    }
}

/// Wiggle's clock: one entry per 110 ms, aligned to when the pair appeared, so every entry flips
/// the eye. Paused — off screen, in the background, under a viewer — it is a single entry, and the
/// view draws once and stops (rule 11).
struct WiggleSchedule: TimelineSchedule {
    let start: Date
    let paused: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        if paused || mode == .lowFrequency { return AnySequence([startDate]) }
        let elapsed = max(startDate.timeIntervalSince(start), 0)
        let first = start.addingTimeInterval((elapsed / StereoMath.period).rounded(.down) * StereoMath.period)
        return AnySequence(sequence(first: first) { $0.addingTimeInterval(StereoMath.period) })
    }
}

// MARK: - Depth

/// The parallax state for one depth view. A class, and not observed: the TimelineView redraws every
/// frame anyway, and publishing each eased step would re-render everything that reads it.
final class DepthMotionState {
    var parallax = DepthParallax()
    private(set) var input: (x: Double, y: Double) = (0, 0)
    private(set) var lastInput: Date?
    private var lastFrame: Date?
    private let born: Date
    private var tiltReference: (roll: Double, pitch: Double)?
    private var lastTilt: (x: Double, y: Double)?

    init(born: Date = Date()) { self.born = born }

    /// A pointer or a drag at `(x, y)` in −1…1.
    func point(_ x: Double, _ y: Double, at date: Date = Date()) {
        input = (min(max(x, -1), 1), min(max(y, -1), 1))
        lastInput = date
    }

    /// Device attitude in degrees, relative to the first reading this view saw (rule 11). Held in
    /// the hand a phone never reads the same twice; a reading within 0.01 of the last is not input,
    /// or the sway — which starts after 1.8 s without input — would never start.
    func tilt(roll: Double, pitch: Double, at date: Date = Date()) {
        let ref = tiltReference ?? (roll, pitch)
        tiltReference = ref
        let t = (DepthParallax.tilt(roll - ref.roll), DepthParallax.tilt(pitch - ref.pitch))
        if let last = lastTilt, abs(last.x - t.0) < 0.01, abs(last.y - t.1) < 0.01 { return }
        lastTilt = t
        point(t.0, t.1, at: date)
    }

    /// One frame: the target (latest input, else the sway after 1.8 s idle, else rest), then the ease.
    func frame(at date: Date, sway: Bool) -> DepthParallax {
        let dt = lastFrame.map { date.timeIntervalSince($0) } ?? 0
        lastFrame = date
        let idle = lastInput.map { date.timeIntervalSince($0) > DepthParallax.idle } ?? true
        let target = idle ? (sway ? DepthParallax.sway(date.timeIntervalSince(born)) : (0, 0)) : input
        parallax.ease(toward: target, dt: dt)
        return parallax
    }
}

/// Loads the colour image and the map on screen (rule 7), then the parallax. Input per rule 11:
/// device motion on iPhone and iPad; the pointer on a Mac; a drag in the viewer everywhere and in
/// the card on a Mac — on a phone the card's drag is the feed's scroll.
struct DropDepthSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let drop: ResolvedDrop
    let sway: Bool
    let active: Bool
    /// As `DropStereoSurface.visible`: out of the scroll view's bounds is off the screen.
    var visible = true
    let inViewer: Bool
    let onFail: () -> Void
    var onOpen: (() -> Void)?
    /// The viewer's `Depth −` / `Depth +`, or the default.
    var amp = DepthParallax.defaultAmp

    @State private var image: UIImage?
    @State private var map: UIImage?
    @State private var motionState = DepthMotionState()
    @State private var cancelled = false
    @State private var attempt = 0
    @State private var pinned: [String] = []
    /// As `DropStereoSurface.demanded`.
    @State private var demanded: [String] = []
    @State private var subscribed = false

    private var files: [DropBlob] { drop.blobs(["media", "depth"]) }

    private var takesDrag: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return inViewer
        #endif
    }

    var body: some View {
        ZStack {
            if let image, let map {
                let parallaxView = TimelineView(.animation(minimumInterval: nil, paused: !active)) { ctx in
                    DepthLayer(image: image, map: map, parallax: frame(ctx.date))
                }
                GeometryReader { geo in
                    parallaxView
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let p) = phase { point(p, in: geo.size) }
                        }
                        .gesture(takesDrag ? pointerDrag(in: geo.size) : nil)
                        // Where the drag is taken, the drag answers the click itself (see
                        // `pointerDrag`); an outer tap would never see it.
                        .onTapGesture { if !takesDrag { onOpen?() } }
                }
                .aspectRatio(drop.boxAspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if !inViewer { HPPill(DropCopy.depthPill).padding(HPTokens.Space.rowGap).allowsHitTesting(false) }
                }
                .accessibilityElement()
                .accessibilityLabel(DropCopy.depthPill)
                .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
                // The button trait promises an activation; a gesture is not one VoiceOver can reach.
                .accessibilityAction(.default) { onOpen?() }
            } else {
                DropLoadingPoster(drop: drop, blobs: files, pill: DropCopy.depthPill, cancelled: $cancelled) { attempt += 1 }
            }
        }
        .transformPreference(DropPhaseKey.self) {
            guard image != nil, map != nil else { return }
            $0.append("depth:ready")
            $0.append(active ? "depth:moving" : "depth:paused")
        }
        .task(id: DropLoadKey(attempt: attempt, visible: visible)) {
            if visible { await load() } else { unload() }
        }
        .onChange(of: active, initial: true) { _, on in setMotion(on) }
        .onAppear { model.drops.liveDepthViews += 1 }
        .onDisappear {
            model.drops.liveDepthViews -= 1
            setMotion(false)
            unload()
        }
    }

    private func frame(_ date: Date) -> DepthParallax {
        motionState.parallax.amp = amp
        let motion = model.drops.motion
        if subscribed, motion.hasReading {
            let (x, y) = Self.axes(roll: motion.roll, pitch: motion.pitch)
            motionState.tilt(roll: x, pitch: y, at: date)
        }
        // Rule 11: under Reduce Motion depth neither sways nor follows the device.
        return motionState.frame(at: date, sway: sway && !reduceMotion)
    }

    /// Roll and pitch follow the interface orientation: in landscape the device's long axis is
    /// horizontal, so its pitch is the picture's left-right.
    private static func axes(roll: Double, pitch: Double) -> (Double, Double) {
        let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
        switch orientation {
        case .landscapeLeft: return (-pitch, roll)
        case .landscapeRight: return (pitch, -roll)
        case .portraitUpsideDown: return (-roll, -pitch)
        default: return (roll, pitch)
        }
    }

    private func point(_ p: CGPoint, in size: CGSize) {
        guard let n = Self.normalised(p, in: size) else { return }
        motionState.point(n.x, n.y)
    }

    /// Rule 11's drag — and, in a Mac card, the click that opens the viewer. A zero-distance drag
    /// recognises on mouse-down and wins over any tap outside it, so a click never reached one;
    /// the drag answers it instead: a press that ends within `clickSlop` of where it began is a
    /// click. In the viewer `onOpen` is nil and a click only moves the parallax.
    private func pointerDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { point($0.location, in: size) }
            .onEnded { v in if Self.isClick(v.translation) { onOpen?() } }
    }

    /// UIKit's own tap slop is about 10 pt; a mouse is steadier than a finger, so 4 pt.
    static let clickSlop: CGFloat = 4
    static func isClick(_ translation: CGSize) -> Bool { hypot(translation.width, translation.height) <= clickSlop }

    /// A pointer or drag location over the media → −1…1 on each axis, the viewer's mapping.
    static func normalised(_ p: CGPoint, in size: CGSize) -> (x: Double, y: Double)? {
        guard size.width > 0, size.height > 0 else { return nil }
        return (Double(p.x / size.width) * 2 - 1, Double(p.y / size.height) * 2 - 1)
    }

    /// One app-wide motion source, subscribed only while this view is on screen and moving, and
    /// never under Reduce Motion (rule 11).
    private func setMotion(_ on: Bool) {
        let want = on && !reduceMotion && image != nil
        guard want != subscribed else { return }
        subscribed = want
        if want { model.drops.motion.subscribe() } else { model.drops.motion.unsubscribe() }
    }

    private func load() async {
        guard !cancelled, files.count == 2 else {
            if files.count != 2 { onFail() }
            return
        }
        demanded = files.map(\.cid)
        let got = await model.drops.files(files, from: drop.source, priority: .screen)
        guard !Task.isCancelled else { return }
        if got != nil { demanded = [] }
        guard got != nil else {
            switch DropLoadOutcome.after(model.drops.failure(files), readerCancelled: cancelled) {
            case .waitForTap: cancelled = true
            case .fallBack: onFail()
            case .nothing: break
            }
            return
        }
        for b in files { model.drops.pin(b.cid) }
        pinned = files.map(\.cid)
        async let colour = model.drops.image(files[0].cid, .card)
        async let depth = model.drops.image(files[1].cid, .depthMap)
        let (c, d) = await (colour, depth)
        guard !Task.isCancelled else { return }
        guard let c, let d else { onFail(); return }
        image = c
        map = d
        setMotion(active)
    }

    private func unload() {
        for cid in demanded { model.drops.release(cid) }
        demanded = []
        for cid in pinned { model.drops.unpin(cid) }
        pinned = []
        image = nil
        map = nil
    }
}

/// The colour image cover-fit into the box, displaced per pixel by the map (DropDepth.metal).
struct DepthLayer: View {
    let image: UIImage
    let map: UIImage
    let parallax: DepthParallax

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let crop = Self.coverCrop(image: image.size, box: size)
            let shift = parallax.shift
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .layerEffect(ShaderLibrary.dropDepthParallax(.float2(size), .image(Image(uiImage: map)),
                                                              .float4(crop.minX, crop.minY, crop.width, crop.height),
                                                              .float2(shift.x, shift.y), .float(parallax.zoom)),
                             maxSampleOffset: .zero)
        }
    }

    /// The part of the image a cover-fit into `box` shows, in the image's 0…1 coordinates — the part
    /// of the map the shader must read, since the map has the image's framing.
    static func coverCrop(image: CGSize, box: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let ia = image.width / image.height
        let ba = box.width / box.height
        if ia > ba {
            let w = ba / ia
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let h = ia / ba
        return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
    }
}

// MARK: - Audio

/// §2.11's player row over a drop's sound. The file downloads whole on play (rule 5) under the
/// play button's ring; the strip is the hairline until it is local, then fills in (§2.11.1).
struct DropAudioRow: View {
    @Environment(AppModel.self) private var model
    let blob: DropBlob
    let source: DropSource
    let title: String
    let performer: String
    let durationMs: Int?
    var feedPost: Post?

    @State private var fileDuration: Double?

    private var key: String { "drop:" + blob.cid }
    private var isCurrent: Bool { model.audio.isCurrent(key) }
    /// The drop's duration until the file says otherwise (§2.36.1).
    private var duration: Int { Int(fileDuration ?? Double(durationMs ?? 0) / 1000) }

    private var state: HPPlayButton.PlayState {
        if isCurrent, model.audio.isPlaying { return .playing }
        if model.audio.loadingKey == key { return .loading(model.drops.progress([blob])) }
        return .idle
    }

    var body: some View {
        HPPlayerRow(title: title, subtitle: performer,
                    elapsed: PostTime.duration(seconds: isCurrent ? Int(model.audio.elapsed) : 0),
                    total: PostTime.duration(seconds: isCurrent && model.audio.duration > 0 ? Int(model.audio.duration) : duration),
                    state: state,
                    buttonLabel: isCurrent && model.audio.isPlaying ? "Pause \(title)" : "Play \(title)",
                    onButton: { tap() }) {
            DropStrip(key: key, path: model.drops.state(blob.cid).url?.path, duration: Double(duration),
                      progress: isCurrent ? model.audio.progress : 0, label: "\(title) progress") { tap(startAt: $0) }
        }
        .task(id: model.drops.state(blob.cid).url) {
            guard durationMs == nil, let url = model.drops.state(blob.cid).url else { return }
            if let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite, d > 0 { fileDuration = d }
        }
    }

    /// `AudioActions.tap`'s rules over a drop file: toggle when current, cancel when loading,
    /// otherwise download at tap priority and play. The download is the store's, not this row's,
    /// so scrolling the row away does not cancel what the reader asked for (rule 5).
    private func tap(startAt: Double = 0) {
        if isCurrent {
            if startAt > 0 { model.audio.seek(toFraction: startAt) } else { model.audio.toggle() }
            return
        }
        if model.audio.loadingKey == key {
            model.drops.cancel(blob.cid)
            model.audio.loadingKey = nil
            return
        }
        model.audio.loadingKey = key
        let store = model.drops!
        store.fetch(blob, from: source, priority: .tap)
        let item = AudioPlayback.Item(key: key, title: title, duration: duration, post: feedPost)
        Task {
            let url = await store.file(blob.cid)
            guard model.audio.loadingKey == key else { return }
            guard let url else {
                model.audio.loadingKey = nil
                if store.state(blob.cid).failure != .cancelled { DropToast.failed(model, store.state(blob.cid).failure) }
                return
            }
            // No pin: AVPlayer holds the file open, and an open file outlives its unlink on Apple
            // platforms, so an eviction mid-play cannot cut the sound off.
            model.audio.play(item, url: url, startAt: startAt)
        }
    }
}

/// The spectrogram strip over a local path, keyed like every other strip so the dock's mini
/// waveform reads the same analysis (§2.11.2). Never downloads.
struct DropStrip: View {
    @Environment(AppModel.self) private var model
    let key: String
    let path: String?
    let duration: Double
    let progress: Double
    let label: String
    let onSeek: (Double) -> Void

    @State private var render: SpectrogramRender?

    private var rows: Int { min(max(Int((HPTokens.Space.stripHeight * ScreenPixels.scale).rounded()), 1), SpectrogramSpec.maxRows) }

    var body: some View {
        GeometryReader { geo in
            let cols = min(max(Int((geo.size.width * ScreenPixels.scale).rounded()), 1), SpectrogramSpec.maxColumns)
            HPSpectrogramStrip(content: HPSpectrogramStrip.Content(image: render?.image, envelope: render?.envelope ?? []),
                               progress: progress, label: label, regionLabel: PostCardRegion.strip, onSeek: onSeek)
                .task(id: "\(key)|\(cols)|\(path ?? "")|\(Int(duration))") {
                    if let hit = model.spectrograms.cached(uniqueId: key, columns: cols, rows: rows) {
                        render = hit
                        model.spectrograms.publish(envelope: hit.envelope, uniqueId: key)
                        return
                    }
                    guard duration > 0, let path else { return }
                    render = await model.spectrograms.strip(uniqueId: key, path: path, duration: duration, columns: cols, rows: rows)
                }
        }
        .frame(height: max(HPTokens.Space.stripHeight, HPTokens.Space.touchMin))
    }
}

// MARK: - Video

/// §2.36.1 video: poster, ▶ and the duration pill; a tap downloads under the ring (rule 5 — no
/// streaming from a PDS that ignores `Range`), then plays inline as a §2.11 video; tapping the
/// playing video opens it full screen.
struct DropVideoSurface: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    let blob: DropBlob
    let onExpand: () -> Void

    @State private var player = InlinePlayerModel()
    @State private var started = false
    @State private var starting = false
    @State private var startTask: Task<Void, Never>?

    private var id: String { "drop:" + blob.cid }
    private var durationSeconds: Int { (drop.record.durationMs ?? 0) / 1000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if started {
                    RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.bg2)
                        .aspectRatio(drop.boxAspect, contentMode: .fit)
                    PlayerLayerView(player: player.player)
                } else {
                    DropPoster(drop: drop)
                }
                if starting {
                    HPProgressRing(progress: model.drops.progress([blob])) { cancelStart() }
                } else if !started {
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                        if durationSeconds > 0 {
                            HPPill(PostTime.duration(seconds: durationSeconds), tone: .neutral).padding(HPTokens.Space.rowGap)
                        }
                    }
                    HPPlayButton(state: .idle, label: "Play") { tapped() }
                }
            }
            .aspectRatio(drop.boxAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { tapped() }
            .accessibilityLabel("Video, \(PostTime.duration(seconds: durationSeconds))")
            if started {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    HPPlayButton(state: player.isPlaying ? .playing : .idle, label: player.isPlaying ? "Pause" : "Play") {
                        if player.isPlaying { player.pause() } else { model.video.willPlay(id, pausing: model.audio); player.play() }
                    }
                    Text(PostTime.duration(seconds: Int(player.elapsed))).hpStyle(HPType.totals)
                    HPScrubber(progress: player.progress) { player.seek(toFraction: $0) }
                    Text(PostTime.duration(seconds: player.duration > 0 ? Int(player.duration) : durationSeconds))
                        .hpStyle(HPType.totals, color: HPTokens.Colors.muted)
                }
                .padding(.top, HPTokens.Space.tabsPad)
            }
        }
        .onChange(of: model.video.activeId) { _, active in
            if active != id, player.isPlaying { player.pause() }
        }
        .onChange(of: model.dropViewer != nil) { _, open in
            // The full-screen copy plays its own player; this one pauses under it.
            if open, player.isPlaying { player.pause() }
        }
        .onDisappear {
            // Torn down, not paused (the InlineVideoView rule): a paused AVPlayer keeps its item,
            // decode ring and render buffers.
            startTask?.cancel()
            startTask = nil
            player.teardown()
            if started { model.drops.unpin(blob.cid) }
            started = false
            starting = false
            model.video.stopped(id)
        }
    }

    private func tapped() {
        if started { onExpand(); return }
        guard !starting else { return }
        starting = true
        let store = model.drops!
        store.fetch(blob, from: drop.source, priority: .tap)
        startTask = Task {
            let url = await store.file(blob.cid)
            guard !Task.isCancelled else { return }
            starting = false
            guard let url else {
                if store.state(blob.cid).failure != .cancelled { DropToast.failed(model, store.state(blob.cid).failure) }
                return
            }
            store.pin(blob.cid)
            player.load(url: url)
            started = true
            model.video.willPlay(id, pausing: model.audio)
            player.play()
        }
    }

    private func cancelStart() {
        startTask?.cancel()
        starting = false
        model.drops.cancel(blob.cid)
    }
}

/// §2.36.1 "Errors the reader asked for".
@MainActor
enum DropToast {
    static func failed(_ model: AppModel, _ failure: DropFailure?) {
        if case .rateLimited(let s) = failure {
            model.showToast(AtprotoError.rateLimited(seconds: s).errorDescription ?? DropCopy.failed, tone: .bad)
        } else {
            model.showToast(DropCopy.failed, tone: .bad)
        }
    }
}
