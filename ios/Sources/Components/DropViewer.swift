// Components — the drop's full-screen viewer (PRODUCT.md §2.36.1 "The 3D viewer", §2.11).
//
// §2.11's viewer chrome (`HPViewer`: ink 96%, `Close`, topbar and tab bar hidden) with the kind's
// controls in a row under the media. Stereo and depth are drawn from their CARD renditions, fit to
// the screen, and do not zoom — a zoomable decode of both eyes at the long edge is ~2 × 25 MB,
// more than the photo share of the budget (PROTOCOL §12.12 rule 9). An image decodes at the
// viewer's size and zooms like any photo. A model is the one SceneKit scene the app holds, torn
// down when the viewer closes (rule 11).

import SceneKit
import SwiftUI
#if !targetEnvironment(macCatalyst)
import ARKit
import QuickLook
#endif

struct DropViewerRequest: Equatable, Identifiable {
    let id = UUID()
    let post: BlueskyPost
    let title: String
    let drop: ResolvedDrop
    /// The card's settings, so the viewer opens where the card was.
    var stereo: StereoSettings
    var sway: Bool
}

struct DropViewerOverlay: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: DropViewerRequest

    @State private var stereo: StereoSettings
    @State private var sway: Bool
    @State private var depth = DepthParallax()
    @State private var spin = true
    @State private var dragY: CGFloat = 0
    @State private var saver = MediaSaver()

    init(request: DropViewerRequest) {
        self.request = request
        _stereo = State(initialValue: request.stereo)
        _sway = State(initialValue: request.sway)
    }

    private var kind: DropKind? { request.drop.plan.kind }

    var body: some View {
        HPViewer(caption: request.title, actions: actions, onClose: close) {
            VStack(spacing: HPTokens.Space.rowGap) {
                Spacer(minLength: HPViewerChrome.height)
                content
                    .frame(maxWidth: HPTokens.Space.columnMax * 2)
                    .offset(y: dragY)
                    .simultaneousGesture(swipesToDismiss ? dismissDrag : nil)
                controls
                    .padding(.horizontal, HPTokens.Space.columnSide)
                Spacer(minLength: HPTokens.Space.bottomSafe)
            }
        }
        .onAppear { spin = !reduceMotion }
    }

    private func close() { model.dropViewer = nil }

    /// Swipe down to close — not where a drag is the content's own input (depth's parallax, a
    /// model's orbit); those close with `Close`.
    private var swipesToDismiss: Bool { kind == .stereo || kind == .video || kind == .image }

    private var dismissDrag: some Gesture {
        DragGesture()
            .onChanged { v in if v.translation.height > 0, abs(v.translation.width) < HPTokens.Space.bottomSafe / 2 { dragY = v.translation.height } }
            .onEnded { _ in
                if dragY > HPTokens.Space.bottomSafe { close() } else { withAnimation(HPMotion.color) { dragY = 0 } }
            }
    }

    /// §2.36.1: no `Save` on a stereo pair, a depth photo or a model — none of them is one image.
    private var actions: [HPViewerAction] {
        guard kind == .image, let media = request.drop.blob("media") else { return [] }
        return [HPViewerAction(DropCopy.save) { save(media) }]
    }

    @ViewBuilder private var content: some View {
        let drop = request.drop
        switch kind {
        case .stereo:
            DropViewerStereo(drop: drop, settings: stereo)
        case .depth:
            DropDepthSurface(drop: drop, sway: sway, active: true, inViewer: true, onFail: close, amp: depth.amp)
        case .image:
            DropViewerImage(drop: drop)
        case .video:
            DropViewerVideo(drop: drop)
        case .model:
            DropViewerModel(drop: drop, spin: spin)
        case .audio, nil:
            EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        switch kind {
        case .stereo:
            VStack(spacing: HPTokens.Space.tabsGap) {
                HPTabs(items: StereoMode.allCases, selected: $stereo.mode, label: \.label)
                HStack(spacing: HPTokens.Space.rowGap) {
                    if stereo.mode == .sideBySide {
                        HPButton(DropCopy.swap, style: .ghostOnInk, size: .small) { stereo.swap.toggle() }
                    }
                    Spacer(minLength: 0)
                    DropGlyphButton(glyph: "\u{25C2}", label: DropCopy.apart) { stereo.shift = StereoMath.converge(stereo.shift, steps: -1) }
                    DropGlyphButton(glyph: "\u{25B8}", label: DropCopy.together) { stereo.shift = StereoMath.converge(stereo.shift, steps: 1) }
                }
            }
        case .depth:
            HStack(spacing: HPTokens.Space.rowGap) {
                HPTabs(items: [DropToggle.on], selected: Binding(get: { sway ? .on : .off }, set: { _ in sway.toggle() }),
                       hugging: true, label: { _ in DropCopy.sway })
                Spacer(minLength: 0)
                HPButton(DropCopy.depthLess, style: .ghostOnInk, size: .small) { depth.stepAmp(up: false) }
                HPButton(DropCopy.depthMore, style: .ghostOnInk, size: .small) { depth.stepAmp(up: true) }
            }
        case .model:
            HStack(spacing: HPTokens.Space.rowGap) {
                HPTabs(items: [DropToggle.on], selected: Binding(get: { spin ? .on : .off }, set: { _ in spin.toggle() }),
                       hugging: true, label: { _ in DropCopy.spin })
                Spacer(minLength: 0)
                #if !targetEnvironment(macCatalyst)
                // A Mac has no camera to place a model with (§2.36.1).
                if let usdz = request.drop.blob("usdz"), model.drops.state(usdz.cid).url != nil {
                    HPButton(DropCopy.ar, style: .ghostOnInk, size: .small) {
                        if let url = model.drops.localURL(usdz.cid) { DropQuickLook.present(url) }
                    }
                }
                #endif
            }
        default:
            EmptyView()
        }
    }

    /// The one place that wants every pixel: decoded from the file, uncached, released when saved.
    private func save(_ media: DropBlob) {
        guard let url = model.drops.localURL(media.cid) else { DropToast.failed(model, nil); return }
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                ImageDecoder.decode(path: url.path, maxPixelSize: ImageRendition.original.maxPixelSize)
            }.value
            guard let image else { DropToast.failed(model, nil); return }
            saver.save(image: image) { error in
                Task { @MainActor in model.showToast(error ?? "Saved.", tone: error == nil ? .good : .bad) }
            }
        }
    }
}

/// A ghost glyph on ink, `touchMin` square as an overlay past its painted size (COMPONENTS.md
/// rule 6), with a spoken label in place of the glyph.
struct DropGlyphButton: View {
    let glyph: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(glyph)
                .hpStyle(HPType.buttonSm, color: HPTokens.Colors.charcoalText)
                .padding(.horizontal, HPTokens.Space.buttonSmX)
                .padding(.vertical, HPTokens.Space.buttonSmY)
                .hpTouchOverlay(label: label)
        }
        .buttonStyle(HPPressStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Per kind

/// The card's renditions, fit to the screen, no zoom (rule 9). They are almost always still in the
/// shared cache from the card; if memory pressure took them, they decode again from the pinned file.
/// If the eyes cannot be had — the files were evicted and the PDS now fails, or a file no longer
/// decodes — it is §2.36.1's tap that failed: the toast, and back to the card's poster.
struct DropViewerStereo: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    let settings: StereoSettings
    @State private var left: UIImage?
    @State private var right: UIImage?

    private var eyes: [DropBlob] { drop.blobs(["left", "right"]) }

    var body: some View {
        ZStack {
            if let left, let right {
                StereoCanvas(left: left, right: right, settings: settings, active: true)
            } else {
                DropPoster(drop: drop)
                if eyes.contains(where: { model.drops.state($0.cid).active }) {
                    HPProgressRing(progress: model.drops.progress(eyes)) {
                        for b in eyes { model.drops.cancel(b.cid) }
                        model.dropViewer = nil
                    }
                }
            }
        }
        .aspectRatio(drop.boxAspect, contentMode: .fit)
        .task(id: drop.record.ref) { await load() }
        .onDisappear { left = nil; right = nil }
    }

    private func load() async {
        let got = eyes.count == 2 ? await model.drops.files(eyes, from: drop.source, priority: .tap) : nil
        guard !Task.isCancelled else { return }
        guard got != nil else {
            DropViewerFailure.close(model, model.drops.failure(eyes))
            return
        }
        async let l = model.drops.image(eyes[0].cid, .card)
        async let r = model.drops.image(eyes[1].cid, .card)
        let (li, ri) = await (l, r)
        guard !Task.isCancelled else { return }
        guard let li, let ri else {
            DropViewerFailure.close(model, nil)
            return
        }
        left = li
        right = ri
    }
}

/// §2.36.1: a tap whose download fails shows `Couldn't load this drop.` and returns to the poster —
/// the card under the viewer. A cancel is the reader's (the ring closes the viewer itself) or
/// someone else's, and says nothing; the viewer still closes rather than hold a poster that will
/// never change.
@MainActor
enum DropViewerFailure {
    static func close(_ model: AppModel, _ failure: DropFailure?) {
        if failure != .cancelled { DropToast.failed(model, failure) }
        model.dropViewer = nil
    }
}

/// §2.11's photo viewer over a drop: the ring over the poster until the full image is in, then zoom.
private struct DropViewerImage: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    @State private var image: UIImage?
    @State private var pinned = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image)
            } else {
                DropPoster(drop: drop)
                if let media = drop.blob("media"), model.drops.state(media.cid).active {
                    HPProgressRing(progress: model.drops.progress([media])) {
                        model.drops.cancel(media.cid)
                        model.dropViewer = nil
                    }
                }
            }
        }
        .task(id: drop.record.ref) { await load() }
        .onDisappear {
            // Rule 5: a tapped download runs until the reader leaves the viewer.
            if let media = drop.blob("media") {
                if image == nil { model.drops.cancel(media.cid) }
                if pinned { model.drops.unpin(media.cid) }
            }
            image = nil
        }
    }

    private func load() async {
        guard let media = drop.blob("media") else { return }
        guard await model.drops.files([media], from: drop.source, priority: .tap) != nil else {
            if model.drops.state(media.cid).failure != .cancelled {
                DropToast.failed(model, model.drops.state(media.cid).failure)
                model.dropViewer = nil
            }
            return
        }
        model.drops.pin(media.cid)
        pinned = true
        image = await model.drops.image(media.cid, .fullScreen)
    }
}

/// §2.11's full-screen video over the downloaded file.
private struct DropViewerVideo: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    @State private var player = InlinePlayerModel()
    @State private var ready = false

    private var blob: DropBlob? { drop.blob("media") }

    var body: some View {
        ZStack {
            if ready {
                PlayerLayerView(player: player.player)
            } else {
                DropPoster(drop: drop)
                if let blob, model.drops.state(blob.cid).active {
                    HPProgressRing(progress: model.drops.progress([blob])) { model.drops.cancel(blob.cid); model.dropViewer = nil }
                }
            }
            if ready {
                VStack {
                    Spacer()
                    HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                        HPPlayButton(state: player.isPlaying ? .playing : .idle, label: player.isPlaying ? "Pause" : "Play") { player.toggle() }
                        Text(PostTime.duration(seconds: Int(player.elapsed))).hpStyle(HPType.totals, color: HPTokens.Colors.charcoalText)
                        HPScrubber(progress: player.progress) { player.seek(toFraction: $0) }
                        Text(PostTime.duration(seconds: Int(player.duration))).hpStyle(HPType.totals, color: HPTokens.Colors.charcoalText)
                    }
                    .padding(.horizontal, HPTokens.Space.cardPad)
                }
            }
        }
        .aspectRatio(drop.boxAspect, contentMode: .fit)
        .task(id: drop.record.ref) {
            guard let blob, let files = await model.drops.files([blob], from: drop.source, priority: .tap), let url = files[blob.cid] else {
                if let blob, model.drops.state(blob.cid).failure != .cancelled {
                    DropToast.failed(model, model.drops.state(blob.cid).failure)
                    model.dropViewer = nil
                }
                return
            }
            model.drops.pin(blob.cid)
            player.load(url: url)
            ready = true
            model.video.willPlay("viewer:drop:\(blob.cid)", pausing: model.audio)
            player.play()
        }
        .onDisappear {
            player.teardown()
            if let blob {
                if !ready { model.drops.cancel(blob.cid) } else { model.drops.unpin(blob.cid) }
                model.video.stopped("viewer:drop:\(blob.cid)")
            }
        }
    }
}

/// The ring until the USDZ is in, then the scene (rule 10: drag orbits, pinch zooms, it turns at
/// 32° a second until `Spin` is off, pausing while touched). A file whose bytes match their CID can
/// still be one SceneKit will not read, or one with nothing in it to draw; that is a failed tap
/// (§2.36.1), not an empty box with `Spin` and `AR` still offered.
struct DropViewerModel: View {
    @Environment(AppModel.self) private var model
    let drop: ResolvedDrop
    let spin: Bool
    @State private var url: URL?
    @State private var scene: DropSceneHandoff?

    private var blob: DropBlob? { drop.blob("usdz") }

    var body: some View {
        ZStack {
            if let scene, let url {
                DropModelScene(url: url, handoff: scene, spinning: spin, store: model.drops)
            } else {
                DropPoster(drop: drop, pill: DropCopy.modelPill)
                if let blob, model.drops.state(blob.cid).active {
                    HPProgressRing(progress: model.drops.progress([blob])) { model.drops.cancel(blob.cid); model.dropViewer = nil }
                }
            }
        }
        .aspectRatio(drop.boxAspect, contentMode: .fit)
        .task(id: drop.record.ref) {
            guard let blob, let files = await model.drops.files([blob], from: drop.source, priority: .tap), let got = files[blob.cid] else {
                if let blob, model.drops.state(blob.cid).failure != .cancelled {
                    DropToast.failed(model, model.drops.state(blob.cid).failure)
                    model.dropViewer = nil
                }
                return
            }
            model.drops.pin(blob.cid)
            url = got
            // Parsed off the main actor: a USDZ can be tens of megabytes of mesh.
            let loaded = await Task.detached(priority: .userInitiated) { DropModelScene.load(got).map(DropSceneHandoff.init) }.value
            guard !Task.isCancelled else { return }
            guard let loaded else {
                DropViewerFailure.close(model, nil)
                return
            }
            scene = loaded
        }
        .onDisappear {
            if let blob {
                if url == nil { model.drops.cancel(blob.cid) } else { model.drops.unpin(blob.cid) }
            }
            url = nil
            scene = nil
        }
    }
}

// MARK: - The model scene

/// SceneKit over a local `.usdz` — the one 3D view that runs on iOS 17 and Catalyst alike (a
/// RealityView orbit camera needs iOS 18). At most one exists across the app: it lives only in the
/// viewer, and the viewer is one at a time; `DropStore.liveModelScenes` counts it for the tests.
struct DropModelScene: UIViewRepresentable {
    let url: URL
    /// The scene `load` already parsed and checked off the main actor: a scene that failed never
    /// reaches a view. Taken once by `makeUIView`.
    let handoff: DropSceneHandoff
    let spinning: Bool
    let store: DropStore

    /// The scene in `url`, or nil when SceneKit cannot read it or it holds no geometry at all.
    nonisolated static func load(_ url: URL) -> SCNScene? {
        guard let scene = try? SCNScene(url: url, options: nil) else { return nil }
        var drawable = false
        scene.rootNode.enumerateHierarchy { node, stop in
            if node.geometry != nil {
                drawable = true
                stop.pointee = true
            }
        }
        return drawable ? scene : nil
    }


    /// `auto-rotate`'s default in model-viewer, which WaveLoop's viewer uses: 32° a second.
    static let degreesPerSecond: CGFloat = 32

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var pivot: SCNNode?
        var spinning = true
        var touching = false
        let store: DropStore
        init(store: DropStore) { self.store = store }

        func apply() { pivot?.isPaused = !spinning || touching }

        @objc func touched(_ g: TouchWatcher) {
            touching = g.state == .began || g.state == .changed
            apply()
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    /// Reports touch-down and touch-up without claiming the touch, so SceneKit's own camera control
    /// still orbits and zooms while the turn pauses.
    final class TouchWatcher: UIGestureRecognizer {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { state = .began }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { state = .changed }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = .ended }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        // A second make for the same value (SwiftUI replacing the view) parses the file again
        // rather than show an empty box.
        let scene = handoff.take() ?? Self.load(url) ?? SCNScene()
        let pivot = SCNNode()
        for child in scene.rootNode.childNodes where child.camera == nil && child.light == nil {
            child.removeFromParentNode()
            pivot.addChildNode(child)
        }
        scene.rootNode.addChildNode(pivot)
        let turn = SCNAction.rotateBy(x: 0, y: Self.degreesPerSecond * .pi / 180, z: 0, duration: 1)
        pivot.runAction(.repeatForever(turn), forKey: "spin")
        view.scene = scene
        let watcher = TouchWatcher(target: context.coordinator, action: #selector(Coordinator.touched(_:)))
        watcher.cancelsTouchesInView = false
        watcher.delegate = context.coordinator
        view.addGestureRecognizer(watcher)
        context.coordinator.pivot = pivot
        context.coordinator.spinning = spinning
        context.coordinator.apply()
        store.liveModelScenes += 1
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.spinning = spinning
        context.coordinator.apply()
    }

    /// Mesh, textures and the render loop go now, not at some later autorelease.
    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.pivot?.removeAllActions()
        coordinator.pivot = nil
        view.scene = nil
        coordinator.store.liveModelScenes -= 1
    }
}

/// A parsed scene handed to exactly one view. `take()` empties it, so once the view is made the
/// SCNView is the scene's only owner, and tearing the view down frees the mesh and textures —
/// however long SwiftUI keeps a copy of the representable's value (which it does: a scene stored
/// on the struct outlived its torn-down viewer in `testModelSceneIsCountedAndTornDown`). Also what
/// carries the scene out of the detached task that parsed it; nothing else holds it then.
final class DropSceneHandoff: @unchecked Sendable {
    private var scene: SCNScene?
    init(_ scene: SCNScene) { self.scene = scene }
    func take() -> SCNScene? {
        defer { scene = nil }
        return scene
    }
}

#if !targetEnvironment(macCatalyst)
/// `AR` on iPhone and iPad: AR Quick Look over the same cached file — placement in the room with no
/// renderer code of ours, and it opens inside the app (§2.11).
@MainActor
enum DropQuickLook {
    private final class Source: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            ARQuickLookPreviewItem(fileAt: url)
        }
    }

    /// The data source is weak on the controller; held here until the next presentation.
    private static var current: Source?

    static func present(_ url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let source = Source(url: url)
        current = source
        let controller = QLPreviewController()
        controller.dataSource = source
        top.present(controller, animated: true)
    }
}
#endif
