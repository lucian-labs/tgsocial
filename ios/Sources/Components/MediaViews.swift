// Components — every media surface a post can carry (PRODUCT.md §2.11). Inline photo with
// blur-up, inline video with a House Pour scrubber, autoplaying muted looped animations,
// audio and voice player rows, circular video notes, document rows, stickers, link previews,
// muted summaries — and the full-screen viewer. Nothing hands off to Telegram or the browser
// except link previews and the explicit Open in Telegram button. System playback engines only;
// their transport chrome never appears.

import AVFoundation
import PDFKit
import SwiftUI

// MARK: - The media list inside a post or comment card

struct PostMediaList: View {
    @Environment(AppModel.self) private var model
    let ownerId: String
    let media: [PostMedia]
    let caption: String
    /// The post these surfaces belong to. Nil inside a comment card, which has media but no post:
    /// the carousel then carries no `Comments` control (§2.12) and the dock no row tap (§2.11).
    var post: Post?
    /// Poll / location / contact summaries hand off here (`Open in Telegram`, PRODUCT §2.11).
    var onOpenExternal: (() -> Void)?

    var body: some View {
        ForEach(blocks) { block in
            blockView(block)
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// How the media list groups itself (PRODUCT §2.11.3): more than one photo is ONE mosaic, drawn
    /// where the first of them sat, and everything else is a surface of its own in place. Pure and
    /// separate from the views so `PhotoMosaicTests` can state the grouping without a host.
    enum Block: Identifiable {
        case single(index: Int)
        case mosaic(indices: [Int])

        var id: Int {
            switch self {
            case .single(let i): return i
            case .mosaic(let indices): return indices.first ?? 0
            }
        }
    }

    var blocks: [Block] { Self.blocks(of: media) }

    static func blocks(of media: [PostMedia]) -> [Block] {
        let photos = media.indices.filter { if case .photo = media[$0] { return true } else { return false } }
        // One photo is a photo (§2.11: `HPMedia` at the post width); more than one is a mosaic.
        guard photos.count > 1, let first = photos.first else {
            return media.indices.map { .single(index: $0) }
        }
        let inMosaic = Set(photos)
        var out: [Block] = []
        for i in media.indices {
            if inMosaic.contains(i) {
                if i == first { out.append(.mosaic(indices: photos)) }
                continue
            }
            out.append(.single(index: i))
        }
        return out
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .single(let i):
            mediaView(media[i], at: i)
        case .mosaic(let indices):
            PhotoMosaicView(photos: indices.compactMap { i in
                guard case .photo(let preview, let full) = media[i] else { return nil }
                return (mediaIndex: i, preview: preview, full: full)
            }, onOpen: { open($0) })
        }
    }

    private func open(_ index: Int) {
        let request = post.map { ViewerRequest.from($0, tappedMediaIndex: index) }
            ?? ViewerRequest.from(media: media, caption: caption, tappedMediaIndex: index)
        if let request { model.viewer = request }
    }

    @ViewBuilder private func mediaView(_ item: PostMedia, at index: Int) -> some View {
        switch item {
        case .photo(let preview, let full):
            PhotoMediaView(preview: preview, full: full) { open(index) }
        case .video(let file, let thumbnail, let duration, let width, let height):
            InlineVideoView(id: "\(ownerId):\(index)", file: file, thumbnail: thumbnail, duration: duration,
                            aspect: aspect(width, height), mode: .video) { open(index) }
        case .animation(let file, let thumbnail, let duration, let width, let height):
            InlineVideoView(id: "\(ownerId):\(index)", file: file, thumbnail: thumbnail, duration: duration,
                            aspect: aspect(width, height), mode: .animation) { open(index) }
        case .videoNote(let file, let thumbnail, let duration):
            InlineVideoView(id: "\(ownerId):\(index)", file: file, thumbnail: thumbnail, duration: duration,
                            aspect: 1, mode: .videoNote, onExpand: nil)
        case .audio(let file, let title, let performer, let duration):
            AudioRowView(file: file, title: title, performer: performer, duration: duration, post: post)
        case .voice(let file, let duration, let waveform):
            VoiceRowView(file: file, duration: duration, waveform: waveform, post: post)
        case .document(let file, let thumbnail):
            DocumentRowView(file: file, thumbnail: thumbnail) { open(index) }
        case .sticker(let file, let thumbnail, let width, let height, let animated, let emoji):
            StickerView(file: file, thumbnail: thumbnail, aspect: aspect(width, height), animated: animated, emoji: emoji)
        case .linkPreview(let url, let siteName, let title, let text, let thumbnail):
            LinkPreviewRow(url: url, siteName: siteName, title: title, text: text, thumbnail: thumbnail)
        case .summary(let text):
            SummaryRow(text: text, onTap: onOpenExternal)
        }
    }

    private func aspect(_ w: Int, _ h: Int) -> CGFloat {
        h > 0 ? CGFloat(w) / CGFloat(h) : 1.5
    }
}

// MARK: - Photo (blur-up, tap → viewer)

struct PhotoMediaView: View {
    @Environment(AppModel.self) private var model
    let preview: PhotoRef
    let full: PhotoRef
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var blurred = false

    var body: some View {
        Button(action: onTap) {
            HPMedia(image: image, aspect: preview.height > 0 ? CGFloat(preview.width) / CGFloat(preview.height) : 1.5,
                    blurred: blurred)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo")
        .task(id: preview.uniqueId) { await load() }
    }

    private func load() async {
        // A card is full-column width: one screen width of pixels is the most it can ever show.
        if let hit = model.media.cached(preview, .card) { image = hit; blurred = false; return }
        image = model.media.minithumbnail(preview); blurred = image != nil
        if let loaded = await model.media.image(for: preview, rendition: .card) { image = loaded; blurred = false }
    }
}

// MARK: - Video / animation / video note (inline, AVPlayerLayer, no system chrome)

/// The raw playback surface: an AVPlayerLayer with no transport controls.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }

    /// AVPlayerLayer holds a strong reference to its player. Clearing it when SwiftUI drops the
    /// view releases the player (and its render buffers) now rather than at some later autorelease.
    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

struct InlineVideoView: View {
    enum Mode {
        case video, animation, videoNote

        /// Which surfaces carry a transport row under them. A muted looping animation is the only
        /// one that does not — it has no playhead a reader is meant to move (PRODUCT §2.11).
        var hasTransport: Bool { self != .animation }

        /// Which transport uses the spectrogram strip instead of the hairline. §2.11.1: "Voice
        /// notes and video notes use the same strip"; a video MESSAGE is the sentence after it —
        /// "video keeps its poster and transport; this replaces the audio scrubber only".
        var usesSpectrogramStrip: Bool { self == .videoNote }
    }

    @Environment(AppModel.self) private var model
    let id: String
    let file: FileRef
    let thumbnail: PhotoRef?
    let duration: Int
    let aspect: CGFloat
    let mode: Mode
    var onExpand: (() -> Void)?

    @State private var player = InlinePlayerModel()
    @State private var poster: UIImage?
    @State private var posterBlurred = false
    @State private var started = false
    @State private var starting = false
    @State private var startTask: Task<Void, Never>?
    /// The autoplay download was cancelled from the ring; the surface shows a retry affordance.
    @State private var cancelled = false

    private var fileState: MediaLoader.FileState { model.media.state(file.fileId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            surface
            // §2.11.1: "Voice notes and video notes use the same strip." A video note therefore
            // needs the same transport row underneath it that a video message has — the circle is
            // the picture, this is the scrubber. An animation is a muted loop with no transport
            // at all, which is the one mode that keeps no row here.
            if mode.hasTransport, started {
                scrubberRow.padding(.top, HPTokens.Space.tabsPad)
            }
        }
        .task(id: thumbnail?.uniqueId) { await loadPoster() }
        .task(id: file.uniqueId) {
            if mode == .animation { await autoplay() }
        }
        .onChange(of: model.video.activeId) { _, active in
            if mode != .animation, active != id, player.isPlaying { player.pause() }
        }
        .onDisappear {
            // Videos pause when scrolled off-screen (PRODUCT §2.11) — and are torn down, not just
            // paused. A paused AVPlayer still holds its item, its decode ring and its render
            // buffers; in a LazyVStack this view is being destroyed anyway, so a pause left the
            // player alive with nothing to release it. Teardown also removes the periodic time
            // observer and the didPlayToEnd token, which AVPlayer and NotificationCenter keep
            // alive independently of this view.
            startTask?.cancel()
            startTask = nil
            player.teardown()
            started = false
            model.video.stopped(id)
        }
    }

    @ViewBuilder private var surface: some View {
        let shape: AnyShape = mode == .videoNote
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous))
        ZStack {
            shape.fill(HPTokens.Colors.bg2)
            if let poster, !started {
                Image(uiImage: poster).resizable().scaledToFill()
                    .blur(radius: posterBlurred ? HPMetric.mediaBlur : 0)
            }
            if started {
                PlayerLayerView(player: player.player)
            }
            overlayControls
        }
        .aspectRatio(mode == .videoNote ? 1 : max(aspect, 0.2), contentMode: .fit)
        .frame(maxWidth: mode == .videoNote ? HPTokens.Space.columnMax / 2 : .infinity)
        .clipShape(shape)
        .contentShape(Rectangle())
        .onTapGesture { tapped() }
        .background(visibilityTracker)
        .accessibilityLabel(accessibilityText)
    }

    /// §2.11: videos pause when scrolled off-screen. `.onDisappear` covers lazy stacks (Feed);
    /// this covers non-lazy layouts (the Thread screen's plain column), where offscreen children
    /// are never torn down. Muted looped animations pause offscreen and resume on re-entry.
    private var visibilityTracker: some View {
        GeometryReader { proxy in
            let viewport = proxy.bounds(of: .scrollView) ?? CGRect(origin: .zero, size: proxy.size)
            let offscreen = !viewport.intersects(CGRect(origin: .zero, size: proxy.size))
            Color.clear
                .onChange(of: offscreen) { _, off in
                    if off {
                        if player.isPlaying {
                            player.pause()
                            if mode != .animation { model.video.stopped(id) }
                        }
                    } else if mode == .animation, started, !player.isPlaying {
                        player.play()
                    }
                }
        }
    }

    @ViewBuilder private var overlayControls: some View {
        switch mode {
        case .animation:
            if fileState.complete {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    HPPill("GIF", tone: .neutral).padding(HPTokens.Space.rowGap)
                }
            } else if cancelled {
                // A cancelled download leaves a play-style affordance that restarts it, so the
                // surface never sits on a dead ring.
                HPPlayButton(state: .idle, label: "Download animation") {
                    cancelled = false
                    model.media.prefetch(file.fileId)
                }
            } else {
                HPProgressRing(progress: fileState.progress) {
                    model.media.cancel(file.fileId)
                    cancelled = true
                }
            }
        case .video:
            if starting {
                HPProgressRing(progress: fileState.progress) { cancelStart() }
            } else if !started {
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    HPPill(PostTime.duration(seconds: duration), tone: .neutral).padding(HPTokens.Space.rowGap)
                }
                HPPlayButton(state: .idle, label: "Play") { tapped() }
            }
        case .videoNote:
            if starting {
                HPProgressRing(progress: fileState.progress) { cancelStart() }
            } else if !started {
                // Only before the first play, as with a video: once the transport row is under the
                // circle, a second play glyph on top of it is two controls for one action. Tapping
                // the circle still toggles.
                HPPlayButton(state: .idle, label: "Play video note") { tapped() }
            }
        }
    }

    private var accessibilityText: String {
        switch mode {
        case .animation: return "Animation"
        case .video: return "Video, \(PostTime.duration(seconds: duration))"
        case .videoNote: return "Video note, \(PostTime.duration(seconds: duration))"
        }
    }

    private var scrubberRow: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            HPPlayButton(state: player.isPlaying ? .playing : .idle,
                         label: player.isPlaying ? "Pause" : "Play") {
                if player.isPlaying { player.pause() } else { model.video.willPlay(id, pausing: model.audio); player.play() }
            }
            Text(PostTime.duration(seconds: Int(player.elapsed))).hpStyle(HPType.totals)
            // §2.11.1 draws the line here: a video NOTE gets the strip ("voice notes and video
            // notes use the same strip"), a video MESSAGE keeps the hairline ("video keeps its
            // poster and transport; this replaces the audio scrubber only"). Either way the
            // transport underneath is this view's own AVPlayer, not the shared audio player.
            if mode.usesSpectrogramStrip {
                // The analyser reads the video note's own mp4 with `AVAudioFile`, which opens a
                // QuickTime/MPEG-4 container with a video track and hands back its audio track —
                // verified against a real h264+AAC mp4, not assumed. A container it cannot open
                // degrades to the empty strip like any other decode failure.
                SpectrogramScrubber(file: file, duration: duration, title: "Video note",
                                    transport: player, label: "Video note progress")
            } else {
                HPScrubber(progress: player.progress) { player.seek(toFraction: $0) }
            }
            Text(PostTime.duration(seconds: player.duration > 0 ? Int(player.duration) : duration))
                .hpStyle(HPType.totals, color: HPTokens.Colors.muted)
        }
    }

    private func tapped() {
        switch mode {
        case .animation:
            onExpand?()
        case .video:
            if started { onExpand?() } else if !starting { start(muted: false) }
        case .videoNote:
            if started { player.toggle(); if player.isPlaying { model.video.willPlay(id, pausing: model.audio) } }
            else if !starting { start(muted: false) }
        }
    }

    private func cancelStart() {
        startTask?.cancel()
        starting = false
        model.media.cancel(file.fileId)
    }

    /// Tap: priority 32, streaming when the downloaded prefix allows (PRODUCT §2.11).
    private func start(muted: Bool) {
        starting = true
        startTask = Task {
            let url = await model.media.readyToPlayURL(file, label: "Downloading video")
            guard !Task.isCancelled else { starting = false; return }
            starting = false
            guard let url else { return }
            player.muted = muted
            player.loop = mode == .animation
            player.load(url: url)
            started = true
            model.video.willPlay(id, pausing: model.audio)
            player.play()
        }
    }

    /// Animations download at visible priority and autoplay muted, looped, once complete.
    private func autoplay() async {
        model.media.prefetch(file.fileId)
        while !Task.isCancelled {
            if let url = model.media.localURL(file.fileId) {
                player.muted = true
                player.loop = true
                player.load(url: url)
                started = true
                player.play()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func loadPoster() async {
        guard let thumbnail else { return }
        if let hit = model.media.cached(thumbnail, .card) { poster = hit; posterBlurred = false; return }
        poster = model.media.minithumbnail(thumbnail); posterBlurred = poster != nil
        if let loaded = await model.media.image(for: thumbnail, rendition: .card) { poster = loaded; posterBlurred = false }
    }
}

// MARK: - Audio row (one at a time; the now-playing row mirrors it)

struct AudioRowView: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let title: String
    let performer: String
    let duration: Int
    /// Carried into the dock so the docked row can open the post the audio came from (§2.11).
    var post: Post?

    private var key: String { file.uniqueId }
    private var isCurrent: Bool { model.audio.isCurrent(key) }
    private var displayTitle: String {
        if !title.isEmpty { return title }
        if !file.fileName.isEmpty { return file.fileName }
        return "Audio"
    }

    private var state: HPPlayButton.PlayState {
        if isCurrent, model.audio.isPlaying { return .playing }
        if model.audio.loadingKey == key { return .loading(model.media.state(file.fileId).progress) }
        return .idle
    }

    var body: some View {
        HPPlayerRow(title: displayTitle, subtitle: performer.isEmpty ? nil : performer,
                    elapsed: PostTime.duration(seconds: isCurrent ? Int(model.audio.elapsed) : 0),
                    total: PostTime.duration(seconds: isCurrent && model.audio.duration > 0 ? Int(model.audio.duration) : duration),
                    state: state,
                    buttonLabel: isCurrent && model.audio.isPlaying ? "Pause \(displayTitle)" : "Play \(displayTitle)",
                    onButton: tapped) {
            SpectrogramScrubber(file: file, duration: duration, title: displayTitle, post: post,
                                label: "\(displayTitle) progress")
        }
    }

    private func tapped() {
        AudioActions.tap(model: model, key: key, fileId: file.fileId, title: displayTitle,
                         duration: duration, post: post)
    }
}

struct VoiceRowView: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let duration: Int
    let waveform: Data
    /// See `AudioRowView.post`.
    var post: Post?

    private var key: String { file.uniqueId }
    private var isCurrent: Bool { model.audio.isCurrent(key) }

    private var state: HPPlayButton.PlayState {
        if isCurrent, model.audio.isPlaying { return .playing }
        if model.audio.loadingKey == key { return .loading(model.media.state(file.fileId).progress) }
        return .idle
    }

    var body: some View {
        HPPlayerRow(title: nil, subtitle: nil,
                    elapsed: PostTime.duration(seconds: isCurrent ? Int(model.audio.elapsed) : 0),
                    total: PostTime.duration(seconds: duration),
                    state: state,
                    buttonLabel: isCurrent && model.audio.isPlaying ? "Pause voice message" : "Play voice message",
                    onButton: tapped) {
            // §2.11.1: a voice note ships its own waveform bytes, so the silhouette is drawn
            // IMMEDIATELY — no decode, nothing to wait for — and the spectrum fills in behind it.
            SpectrogramScrubber(file: file, duration: duration, title: "Voice message",
                                waveform: waveform, post: post, label: "Voice message progress")
        }
    }

    private func tapped() {
        AudioActions.tap(model: model, key: key, fileId: file.fileId, title: "Voice message",
                         duration: duration, post: post)
    }
}

// MARK: - The spectrogram scrubber (PRODUCT §2.11.1)

/// The strip in the player row: it decides *when* an analysis is allowed to run, sizes it to the
/// pixels it will be drawn at, and keeps whatever it already has while the rest arrives.
///
/// Two gates, both from §2.11.1. Analysis never runs for a row that has not been **played or
/// scrolled into view** — `.task` is the second half of that, and the first is that the strip never
/// starts a download of its own: it analyses the bytes that are already on disk (TDLib had the
/// file, or the row has been played once) and otherwise draws its silhouette and waits. And the
/// duration decides the plan before a byte is read, so a three-hour file costs a comparison.
struct SpectrogramScrubber: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let duration: Int
    let title: String
    /// TDLib's 5-bit waveform samples, for a voice note. Empty for `messageAudio`.
    var waveform: Data = Data()
    /// The player this strip reads and drives, when it is not the shared audio player: a video
    /// note plays through its own `AVPlayer` inside `InlineVideoView` (§2.11.1 — video notes use
    /// the same strip, but not the same transport). nil for audio and voice rows.
    var transport: InlinePlayerModel?
    /// The post this row belongs to — carried only so a drag on the strip of a row that is not
    /// playing can start it *and* dock it with somewhere to go (§2.11).
    var post: Post?
    let label: String

    @State private var render: SpectrogramRender?

    private var key: String { file.uniqueId }
    private var isCurrent: Bool { model.audio.isCurrent(key) }
    private var progress: Double {
        if let transport { return transport.progress }
        return isCurrent ? model.audio.progress : 0
    }
    /// Whether the bytes are here yet. Read from the observable download state, so finishing a
    /// download re-runs the task below rather than leaving the row silhouette-only for ever.
    private var localPath: String? { model.media.localURL(file.fileId)?.path }

    /// The silhouette to draw right now: a voice note's own bytes if it has them (they need no
    /// decode and must not be replaced by the analysis — that is the whole point of drawing them),
    /// otherwise the one-pole envelope once it lands.
    private var envelope: [Double] {
        let samples = WaveformCodec.decode(waveform)
        return samples.isEmpty ? (render?.envelope ?? []) : samples
    }

    private var rows: Int {
        min(max(Int((HPTokens.Space.stripHeight * ScreenPixels.scale).rounded()), 1), SpectrogramSpec.maxRows)
    }

    private func columns(_ width: CGFloat) -> Int {
        min(max(Int((width * ScreenPixels.scale).rounded()), 1), SpectrogramSpec.maxColumns)
    }

    var body: some View {
        GeometryReader { geo in
            let cols = columns(geo.size.width)
            HPSpectrogramStrip(content: HPSpectrogramStrip.Content(image: render?.image, envelope: envelope),
                               progress: progress,
                               label: label,
                               regionLabel: PostCardRegion.strip,
                               onSeek: seek)
                .task(id: AnalysisKey(uniqueId: key, columns: cols, rows: rows, hasBytes: localPath != nil)) {
                    await analyse(columns: cols)
                }
        }
        .frame(height: max(HPTokens.Space.stripHeight, HPTokens.Space.touchMin))
    }

    /// Seeking anywhere on the strip works whether or not this row is the one playing: on a row
    /// that is not current the drag *starts* it at that point, which is what "the strip is also the
    /// scrubber" has to mean for a row you have not pressed play on yet.
    private func seek(_ fraction: Double) {
        if let transport {
            // A video note is already loaded and playing by the time its strip exists, so a drag
            // is a seek and never a "start it here" — that path belongs to the audio player.
            transport.seek(toFraction: fraction)
            return
        }
        if isCurrent {
            model.audio.seek(toFraction: fraction)
            return
        }
        AudioActions.tap(model: model, key: key, fileId: file.fileId, title: title,
                         duration: duration, post: post, startAt: fraction)
    }

    private func analyse(columns: Int) async {
        // §2.11.2: whatever silhouette this row draws, the dock draws the same one. A voice note's
        // TDLib bytes are published first because they are here *now* and need no decode — so a
        // clip that starts playing before its spectrum lands still docks with a shape rather than a
        // flat line. `SpectrogramStore.strip` publishes the analysed envelope over it when it
        // arrives, which is the same order the strip itself swaps them in.
        let bytes = WaveformCodec.decode(waveform)
        if !bytes.isEmpty { model.spectrograms.publish(envelope: bytes, uniqueId: key) }

        if let hit = model.spectrograms.cached(uniqueId: key, columns: columns, rows: rows) {
            render = hit
            model.spectrograms.publish(envelope: hit.envelope, uniqueId: key)
            return
        }
        guard duration > 0, let path = localPath else { return }
        render = await model.spectrograms.strip(uniqueId: key, path: path, duration: Double(duration),
                                                columns: columns, rows: rows)
    }

    /// What re-runs the analysis: the clip, the pixel size it is drawn at, and whether its bytes
    /// have arrived. Not the playhead — the strip is static once computed.
    private struct AnalysisKey: Equatable {
        let uniqueId: String
        let columns: Int
        let rows: Int
        let hasBytes: Bool
    }
}

// MARK: - The dock's mini waveform (PRODUCT §2.11.2)

/// The now-playing dock's waveform: **a view of the analysis the strip already did**, resampled to
/// the dock's width. There is no file path anywhere in this type and no call into
/// `SpectrogramStore.strip` — the only thing it can do is read a published envelope and resample
/// it, which is what makes "playing a clip must never trigger a second analysis" a property of the
/// code rather than a promise in a comment (`MiniWaveformTests` asserts the analysis count).
///
/// A clip whose strip has not run — or whose strip degraded to the hairline — has no envelope here,
/// and `HPMiniWave` draws the flat line for it.
struct DockWaveform: View {
    @Environment(AppModel.self) private var model
    /// The clip's `uniqueId`: the same identity the strip cached its analysis under.
    let key: String
    let title: String

    var body: some View {
        GeometryReader { geo in
            HPMiniWave(peaks: model.spectrograms.peaks(uniqueId: key,
                                                       columns: Self.columns(width: geo.size.width)),
                       progress: model.audio.progress,
                       label: "\(title) progress",
                       regionLabel: DockRegion.wave,
                       onSeek: { model.audio.seek(toFraction: $0) })
        }
        // The kit view carries the sizing (`miniWaveWidth` floor, `touchMin` height); this frame
        // only bounds the greedy `GeometryReader` that reads the width to resample against, so the
        // shipped control and `DockHitRegionTests`' `HPMiniWave` are the same geometry.
        .frame(minWidth: HPTokens.Space.miniWaveWidth, maxWidth: .infinity,
               minHeight: HPTokens.Space.touchMin, maxHeight: HPTokens.Space.touchMin)
    }

    /// One vertex per point, not per pixel. The strip is a texture drawn once, so it buys a column
    /// per pixel; this is a stroked path re-emitted on every playhead tick, and a hairline polyline
    /// gains nothing from vertices closer together than the line is wide.
    static func columns(width: CGFloat) -> Int {
        min(max(Int(width.rounded()), 1), SpectrogramSpec.maxColumns)
    }
}

/// Labels the docked now-playing row's hit regions report under `hpMeasureTouchTargets`, so the
/// assembled-dock test names a region instead of counting tree order.
enum DockRegion {
    static let wave = "dock waveform"
    static let play = "dock play"
}

@MainActor
enum AudioActions {
    /// Shared tap behaviour for audio and voice rows: toggle when current, cancel when loading,
    /// otherwise download at tapped priority and play (pausing whatever else was playing).
    /// `startAt` is the fraction a drag on the spectrogram strip landed on (§2.11.1) — 0 for a
    /// press of the play button.
    static func tap(model: AppModel, key: String, fileId: Int, title: String, duration: Int,
                    post: Post? = nil, startAt: Double = 0) {
        if model.audio.isCurrent(key) {
            if startAt > 0 { model.audio.seek(toFraction: startAt); return }
            model.audio.toggle()
            return
        }
        if model.audio.loadingKey == key {
            model.media.cancel(fileId)
            model.audio.loadingKey = nil
            return
        }
        model.audio.loadingKey = key
        Task {
            let path = await model.media.download(fileId, priority: MediaLoader.tappedPriority, label: "Downloading audio")
            guard model.audio.loadingKey == key else { return }
            guard let path else { model.audio.loadingKey = nil; return }
            model.audio.play(AudioPlayback.Item(key: key, title: title, duration: duration, post: post),
                             url: URL(fileURLWithPath: path), startAt: startAt)
        }
    }
}

// MARK: - Document row

struct DocumentRowView: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let thumbnail: PhotoRef?
    let onOpenViewer: () -> Void
    @State private var fetching = false

    private var kind: DocumentKind { DocumentKind.of(mimeType: file.mimeType, fileName: file.fileName) }
    private var name: String { file.fileName.isEmpty ? "Document" : file.fileName }
    private var detail: String {
        var parts = [FileSize.format(file.size)]
        if !file.mimeType.isEmpty { parts.append(file.mimeType) }
        return parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            Text("\u{25A4}")
                .hpStyle(HPType.h2, color: HPTokens.Colors.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).hpStyle(HPType.body).lineLimit(1)
                HPMonoSmall(detail).lineLimit(1)
            }
            Spacer(minLength: HPTokens.Space.rowGap)
            if fetching {
                HPProgressRing(progress: model.media.state(file.fileId).progress) {
                    model.media.cancel(file.fileId)
                    fetching = false
                }
            } else {
                HPButton(kind.isViewable ? "Open" : "Share", style: .ghost, size: .small) { open() }
            }
        }
        .padding(.vertical, HPTokens.Space.inputY)
        .padding(.horizontal, HPTokens.Space.inputX)
        .background(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.bg2))
    }

    private func open() {
        // PDF, images, text, audio and video documents open in the in-app viewer; other types
        // download then offer Share (PRODUCT §2.11).
        if kind.isViewable { onOpenViewer(); return }
        fetching = true
        Task {
            let path = await model.media.download(file.fileId, priority: MediaLoader.tappedPriority,
                                                  label: "Downloading \(name)")
            fetching = false
            guard let path else { return }
            ShareSheet.present(url: URL(fileURLWithPath: path))
        }
    }
}

// MARK: - Sticker (static; animated stickers show their thumbnail)

struct StickerView: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let thumbnail: PhotoRef?
    let aspect: CGFloat
    let animated: Bool
    let emoji: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous)
                    .fill(HPTokens.Colors.bg2)
            }
        }
        .aspectRatio(max(aspect, 0.2), contentMode: .fit)
        .frame(maxWidth: HPTokens.Space.columnMax / 3, alignment: .leading)
        .accessibilityLabel("Sticker")
        .task(id: file.uniqueId) { await load() }
    }

    private func load() async {
        // A sticker tile is at most a third of the column; it never needs more than that in pixels.
        let rendition = ImageRendition.points(HPTokens.Space.columnMax / 3)
        if animated {
            if let thumbnail {
                image = await model.media.image(for: thumbnail, rendition: rendition, label: "Downloading sticker")
            }
            return
        }
        // Was `UIImage(contentsOfFile:)`: full-resolution, uncached, and re-decoded every time the
        // sticker scrolled back into view.
        if let loaded = await model.media.image(for: file, rendition: rendition, label: "Downloading sticker") {
            image = loaded
        } else if let thumbnail {
            image = await model.media.image(for: thumbnail, rendition: rendition, label: "Downloading sticker")
        }
    }
}

// MARK: - Link preview (the one tap that leaves the app, by design)

struct LinkPreviewRow: View {
    @Environment(AppModel.self) private var model
    let url: String
    let siteName: String
    let title: String
    let text: String
    let thumbnail: PhotoRef?
    @State private var image: UIImage?

    var body: some View {
        Button { model.open(url) } label: {
            HStack(alignment: .top, spacing: HPTokens.Space.rowGap) {
                if let thumbnail {
                    HPMedia(image: image, aspect: 1)
                        .frame(width: HPTokens.Space.avatarProfile)
                        .task(id: thumbnail.uniqueId) {
                            image = await model.media.image(for: thumbnail,
                                                            rendition: .points(HPTokens.Space.avatarProfile))
                        }
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !siteName.isEmpty { HPMonoSmall(siteName).lineLimit(1) }
                    if !title.isEmpty { HPBody(title, strong: true).lineLimit(2) }
                    if !text.isEmpty { HPSmall(text).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .padding(HPTokens.Space.rowPad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.inputBg))
            .overlay(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous)
                .strokeBorder(HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(HPPressStyle())
        .accessibilityLabel("Open link \(siteName.isEmpty ? url : siteName)")
    }
}

// MARK: - Summary (poll, location, contact, other)

struct SummaryRow: View {
    let text: String
    var onTap: (() -> Void)?

    var body: some View {
        let row = HStack(spacing: HPTokens.Space.rowGap) {
            HPMuted(text)
            Spacer(minLength: 0)
        }
        .padding(.vertical, HPTokens.Space.inputY)
        .padding(.horizontal, HPTokens.Space.inputX)
        .background(RoundedRectangle(cornerRadius: HPTokens.Radius.media, style: .continuous).fill(HPTokens.Colors.bg2))
        if let onTap {
            Button(action: onTap) { row.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(text). Open in Telegram.")
        } else {
            row
        }
    }
}

// MARK: - Full-screen viewer (PRODUCT §2.11)

struct ViewerOverlay: View {
    @Environment(AppModel.self) private var model
    let request: ViewerRequest
    @State private var index: Int
    @State private var dragY: CGFloat = 0
    @State private var saver = MediaSaver()
    /// §2.12: opening comments does NOT leave the media — it shrinks to a mini view pinned at the
    /// top and the thread takes the rest of the sheet.
    @State private var showsComments = false

    init(request: ViewerRequest) {
        self.request = request
        _index = State(initialValue: request.index)
    }

    private var current: ViewerItem? {
        request.items.indices.contains(index) ? request.items[index] : nil
    }

    private var saveLabel: String? {
        switch current {
        case .photo, .video, .animation: return "Save"
        case .document: return "Share"
        case nil: return nil
        }
    }

    /// The trailing chrome. `Comments` comes first because it is the one that changes what the
    /// screen is; `Save` acts on whatever is showing either way.
    private var actions: [HPViewerAction] {
        var out: [HPViewerAction] = []
        if request.post != nil {
            out.append(HPViewerAction("Comments") {
                withAnimation(HPMotion.color) { showsComments.toggle() }
            })
        }
        if let saveLabel { out.append(HPViewerAction(saveLabel, action: performAction)) }
        return out
    }

    var body: some View {
        HPViewer(counter: request.items.count > 1 ? "\(index + 1) / \(request.items.count)" : nil,
                 // With the thread open the sheet owns the bottom of the screen; the caption is the
                 // post's text, and the thread is about that post already.
                 caption: showsComments ? "" : request.caption,
                 actions: actions,
                 onClose: { model.viewer = nil }) {
            VStack(spacing: 0) {
                if showsComments {
                    // Room for the Close / Comments row, which the mini view must sit under rather
                    // than behind.
                    Color.clear.frame(height: HPViewerChrome.height)
                }
                pager
                if showsComments, let post = request.post {
                    CarouselComments(post: post, link: request.link(at: index))
                }
            }
        }
        // Paging re-targets the thread, so a selection made against the previous item does not
        // survive the swipe (§2.12).
        .onChange(of: index) { _, _ in model.clearReply() }
        .onDisappear { model.clearReply() }
    }

    /// The carousel. One `TabView` in both states: shrinking its frame is what "the media shrinks to
    /// a mini view" means, and it is why paging keeps working with the thread open — there is no
    /// second player and no second page list to keep in step.
    private var pager: some View {
        TabView(selection: $index) {
            ForEach(Array(request.items.enumerated()), id: \.offset) { i, item in
                ViewerPageView(item: item)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: showsComments ? HPTokens.Space.viewerMiniHeight : nil)
        .modifier(ViewerFullBleed(active: !showsComments))
        .offset(y: dragY)
        // §2.12: the mini view is "still tappable to restore it full-screen". Simultaneous, so the
        // page swipe underneath still gets its drag.
        .simultaneousGesture(
            showsComments
                ? TapGesture().onEnded { withAnimation(HPMotion.color) { showsComments = false } }
                : nil
        )
        .accessibilityAction(named: "Show the media full screen") {
            withAnimation(HPMotion.color) { showsComments = false }
        }
        .simultaneousGesture(
            // Swipe down to dismiss — but not while the thread is open, where a downward drag
            // belongs to the thread's own scrolling.
            showsComments ? nil :
            DragGesture()
                .onChanged { v in
                    if v.translation.height > 0, abs(v.translation.width) < HPTokens.Space.bottomSafe / 2 {
                        dragY = v.translation.height
                    }
                }
                .onEnded { v in
                    if dragY > HPTokens.Space.bottomSafe {
                        model.viewer = nil
                    } else {
                        withAnimation(HPMotion.color) { dragY = 0 }
                    }
                    if abs(v.translation.width) > abs(v.translation.height) { dragY = 0 }
                }
        )
    }

    private func performAction() {
        guard let current else { return }
        switch current {
        case .photo(_, let full):
            Task {
                // Saving to the library is the one place that genuinely wants every pixel, so it
                // decodes the original — uncached, released as soon as the save finishes.
                guard let image = await model.media.originalImage(for: full) else {
                    model.showToast("Couldn't load the photo.", tone: .bad); return
                }
                saver.save(image: image) { error in
                    Task { @MainActor in
                        model.showToast(error ?? "Saved.", tone: error == nil ? .good : .bad)
                    }
                }
            }
        case .video(let file, _, _), .animation(let file, _):
            Task {
                guard let path = await model.media.download(file.fileId, priority: MediaLoader.tappedPriority, label: "Downloading video") else {
                    model.showToast("Couldn't load the video.", tone: .bad); return
                }
                saver.save(videoPath: path) { error in
                    Task { @MainActor in
                        model.showToast(error ?? "Saved.", tone: error == nil ? .good : .bad)
                    }
                }
            }
        case .document(let file, _, _):
            // §2.22.3: `Share`, anywhere it appears, answers the line that says why — the post
            // header's was converted and this one is the same control under the same label. It is
            // also the only chrome action that hands generated bytes to another app, which the
            // always-on strip says cannot happen.
            if model.isDemo { model.refuseShareInDemo(); return }
            Task {
                let name = file.fileName.isEmpty ? "Document" : file.fileName
                guard let path = await model.media.download(file.fileId, priority: MediaLoader.tappedPriority, label: "Downloading \(name)") else { return }
                ShareSheet.present(url: URL(fileURLWithPath: path))
            }
        }
    }
}

/// `ignoresSafeArea` only while the media is full screen. With the thread open the mini view has to
/// sit inside the safe area under the chrome, and a modifier that is applied conditionally has to be
/// a modifier — `if` inside a view builder would rebuild the `TabView` and lose its page.
private struct ViewerFullBleed: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.ignoresSafeArea() } else { content }
    }
}

/// §2.12 "Comments in the carousel": the thread, on the look's one panel surface, taking the rest
/// of the sheet under the mini view.
///
/// It hosts `CommentThreadList` — the same rows, the same reply-target selection and the same
/// composer the Thread screen uses. `link` is the album item the carousel is showing, so paging
/// re-targets the thread to that item's post without this view knowing anything about paging.
private struct CarouselComments: View {
    @Environment(AppModel.self) private var model
    let post: Post
    let link: String?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HPTokens.Radius.card, style: .continuous)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                CommentThreadList(post: post, roots: [link ?? post.deepLink])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HPTokens.Space.cardPad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `bg`, not `panel`: the sheet is the app's PAGE docked over the media, and the comment
        // cards inside it are cards on a page. A panel here would be a card holding cards.
        .background(shape.fill(HPTokens.Colors.bg))
        .hpBorder(shape)
        .padding(.horizontal, HPTokens.Space.columnSide)
        .padding(.top, HPTokens.Space.cardGap)
        .scrollDismissesKeyboard(.interactively)
        // §6.3, as on the Thread screen: opening the thread refreshes the index for the target.
        .task(id: link ?? post.deepLink) { await model.refreshComments(for: post) }
    }
}

private struct ViewerPageView: View {
    let item: ViewerItem

    var body: some View {
        switch item {
        case .photo(let preview, let full):
            ViewerPhotoPage(preview: preview, full: full)
        case .video(let file, let thumbnail, let duration):
            ViewerVideoPage(file: file, thumbnail: thumbnail, duration: duration, loop: false, muted: false, showsScrubber: true)
        case .animation(let file, let thumbnail):
            ViewerVideoPage(file: file, thumbnail: thumbnail, duration: 0, loop: true, muted: true, showsScrubber: false)
        case .document(let file, let kind, let thumbnail):
            ViewerDocumentPage(file: file, kind: kind, thumbnail: thumbnail)
        }
    }
}

private struct ViewerPhotoPage: View {
    @Environment(AppModel.self) private var model
    let preview: PhotoRef
    let full: PhotoRef
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        ZStack {
            ZoomableImageView(image: image)
            if loading, image == nil || model.media.cached(full, .fullScreen) == nil {
                HPProgressRing(progress: model.media.state(full.fileId).progress) {
                    model.media.cancel(full.fileId)
                }
            }
        }
        .task(id: full.uniqueId) { await load() }
    }

    private func load() async {
        // The viewer is the one surface that earns a larger rendition — the screen's longest edge,
        // which is still a fraction of a 12 MP original and leaves plenty of pixels to zoom into.
        // Its own cache key means opening the viewer never evicts the card's cheaper copy.
        if let hit = model.media.cached(full, .fullScreen) { image = hit; loading = false; return }
        image = model.media.cached(preview, .card) ?? model.media.minithumbnail(preview)
        if let loaded = await model.media.image(for: full, rendition: .fullScreen,
                                                priority: MediaLoader.tappedPriority) { image = loaded }
        loading = false
    }
}

private struct ViewerVideoPage: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let thumbnail: PhotoRef?
    let duration: Int
    let loop: Bool
    let muted: Bool
    let showsScrubber: Bool
    @State private var player = InlinePlayerModel()
    @State private var poster: UIImage?
    @State private var ready = false

    var body: some View {
        ZStack {
            if let poster, !ready {
                Image(uiImage: poster).resizable().scaledToFit()
            }
            if ready {
                PlayerLayerView(player: player.player)
            }
            if !ready {
                HPProgressRing(progress: model.media.state(file.fileId).progress) {
                    model.media.cancel(file.fileId)
                }
            }
            if showsScrubber, ready {
                VStack {
                    Spacer()
                    HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                        HPPlayButton(state: player.isPlaying ? .playing : .idle,
                                     label: player.isPlaying ? "Pause" : "Play") { player.toggle() }
                        Text(PostTime.duration(seconds: Int(player.elapsed)))
                            .hpStyle(HPType.totals, color: HPTokens.Colors.charcoalText)
                        HPScrubber(progress: player.progress) { player.seek(toFraction: $0) }
                        Text(PostTime.duration(seconds: player.duration > 0 ? Int(player.duration) : duration))
                            .hpStyle(HPType.totals, color: HPTokens.Colors.charcoalText)
                    }
                    .padding(.horizontal, HPTokens.Space.cardPad)
                    .padding(.bottom, HPTokens.Space.bottomSafe)
                }
            }
        }
        .task(id: file.uniqueId) { await start() }
        .onDisappear { player.teardown() }
    }

    private func start() async {
        if let thumbnail {
            poster = model.media.cached(thumbnail, .card) ?? model.media.minithumbnail(thumbnail)
        }
        guard let url = await model.media.readyToPlayURL(file, label: "Downloading video") else { return }
        player.muted = muted
        player.loop = loop
        player.load(url: url)
        ready = true
        if !muted { model.video.willPlay("viewer:\(file.uniqueId)", pausing: model.audio) }
        player.play()
    }
}

private struct ViewerDocumentPage: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let kind: DocumentKind
    let thumbnail: PhotoRef?
    @State private var path: String?
    /// Decoded once, at screen size. Held here rather than rebuilt in `content(path:)`, where a
    /// full-resolution `UIImage(contentsOfFile:)` ran on the main thread on every body evaluation.
    @State private var documentImage: UIImage?

    var body: some View {
        ZStack {
            if let path {
                content(path: path)
            } else {
                HPProgressRing(progress: model.media.state(file.fileId).progress) {
                    model.media.cancel(file.fileId)
                }
            }
        }
        .task(id: file.uniqueId) {
            let name = file.fileName.isEmpty ? "Document" : file.fileName
            path = await model.media.download(file.fileId, priority: MediaLoader.tappedPriority, label: "Downloading \(name)")
            guard kind == .image else { return }
            documentImage = await model.media.image(for: file, rendition: .fullScreen,
                                                    priority: MediaLoader.tappedPriority, label: "Downloading \(name)")
        }
        .onDisappear { documentImage = nil }
    }

    @ViewBuilder private func content(path: String) -> some View {
        switch kind {
        case .pdf:
            PDFKitView(url: URL(fileURLWithPath: path))
        case .image:
            ZoomableImageView(image: documentImage)
        case .text:
            ScrollView(.vertical, showsIndicators: false) {
                Text((try? String(contentsOfFile: path, encoding: .utf8)) ?? "Couldn't read this file.")
                    .hpStyle(HPType.mono, color: HPTokens.Colors.charcoalText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HPTokens.Space.cardPad)
                    .padding(.vertical, HPTokens.Space.bottomSafe)
            }
        case .audio:
            ViewerAudioPage(url: URL(fileURLWithPath: path), title: file.fileName)
        case .video:
            ViewerVideoPage(file: file, thumbnail: thumbnail, duration: 0, loop: false, muted: false, showsScrubber: true)
        case .other:
            HPMono(file.fileName, color: HPTokens.Colors.charcoalText)
        }
    }
}

/// An audio document inside the viewer: the player row controls on the dark surface.
private struct ViewerAudioPage: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let title: String
    @State private var player = InlinePlayerModel()

    var body: some View {
        VStack(spacing: HPTokens.Space.cardPad) {
            Text(title.isEmpty ? "Audio" : title)
                .hpStyle(HPType.bodyStrong, color: HPTokens.Colors.charcoalText)
                .lineLimit(2)
                .padding(.horizontal, HPTokens.Space.cardPad)
            HPPlayButton(state: player.isPlaying ? .playing : .idle,
                         label: player.isPlaying ? "Pause" : "Play") {
                if player.player == nil { player.load(url: url) }
                if player.isPlaying { player.pause() } else {
                    model.video.willPlay("viewer:\(url.path)", pausing: model.audio)
                    player.play()
                }
            }
            HStack(spacing: HPTokens.Space.rowGap) {
                Text(PostTime.duration(seconds: Int(player.elapsed)))
                    .hpStyle(HPType.totals, color: HPTokens.Colors.charcoalText)
                HPScrubber(progress: player.progress) { player.seek(toFraction: $0) }
                Text(PostTime.duration(seconds: Int(player.duration)))
                    .hpStyle(HPType.totals, color: HPTokens.Colors.charcoalText)
            }
            .padding(.horizontal, HPTokens.Space.cardPad)
        }
        .onDisappear { player.teardown() }
    }
}

/// Pinch-zoom and double-tap zoom for photos (PRODUCT §2.11), on a plain UIScrollView.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}

/// PDFKit's PDFView with no chrome of its own.
struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
