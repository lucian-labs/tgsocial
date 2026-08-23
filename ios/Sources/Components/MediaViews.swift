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
    /// Poll / location / contact summaries hand off here (`Open in Telegram`, PRODUCT §2.11).
    var onOpenExternal: (() -> Void)?

    var body: some View {
        ForEach(Array(media.enumerated()), id: \.offset) { i, item in
            mediaView(item, at: i)
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    private func open(_ index: Int) {
        if let request = ViewerRequest.from(media: media, caption: caption, tappedMediaIndex: index) {
            model.viewer = request
        }
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
            AudioRowView(file: file, title: title, performer: performer, duration: duration)
        case .voice(let file, let duration, let waveform):
            VoiceRowView(file: file, duration: duration, waveform: waveform)
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
        if let hit = model.media.cached(preview) { image = hit; blurred = false; return }
        image = model.media.minithumbnail(preview); blurred = image != nil
        if let loaded = await model.media.image(for: preview) { image = loaded; blurred = false }
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
}

struct InlineVideoView: View {
    enum Mode { case video, animation, videoNote }

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
            if mode == .video, started {
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
            // Videos pause when scrolled off-screen (PRODUCT §2.11).
            startTask?.cancel()
            if player.isPlaying { player.pause() }
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
            } else if !player.isPlaying {
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
            HPScrubber(progress: player.progress) { player.seek(toFraction: $0) }
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
        if let hit = model.media.cached(thumbnail) { poster = hit; posterBlurred = false; return }
        poster = model.media.minithumbnail(thumbnail); posterBlurred = poster != nil
        if let loaded = await model.media.image(for: thumbnail) { poster = loaded; posterBlurred = false }
    }
}

// MARK: - Audio row (one at a time; the now-playing row mirrors it)

struct AudioRowView: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let title: String
    let performer: String
    let duration: Int

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
            HPScrubber(progress: isCurrent ? model.audio.progress : 0, knob: isCurrent,
                       onSeek: isCurrent ? { model.audio.seek(toFraction: $0) } : nil)
        }
    }

    private func tapped() {
        AudioActions.tap(model: model, key: key, fileId: file.fileId, title: displayTitle, duration: duration)
    }
}

struct VoiceRowView: View {
    @Environment(AppModel.self) private var model
    let file: FileRef
    let duration: Int
    let waveform: Data

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
            HPWaveform(samples: WaveformCodec.decode(waveform),
                       progress: isCurrent ? model.audio.progress : 0,
                       onSeek: isCurrent ? { model.audio.seek(toFraction: $0) } : nil)
        }
    }

    private func tapped() {
        AudioActions.tap(model: model, key: key, fileId: file.fileId, title: "Voice message", duration: duration)
    }
}

@MainActor
enum AudioActions {
    /// Shared tap behaviour for audio and voice rows: toggle when current, cancel when loading,
    /// otherwise download at tapped priority and play (pausing whatever else was playing).
    static func tap(model: AppModel, key: String, fileId: Int, title: String, duration: Int) {
        if model.audio.isCurrent(key) { model.audio.toggle(); return }
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
            model.audio.play(AudioPlayback.Item(key: key, title: title, duration: duration),
                             url: URL(fileURLWithPath: path))
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
        if animated {
            if let thumbnail { image = await model.media.image(for: thumbnail, label: "Downloading sticker") }
            return
        }
        if let path = await model.media.download(file.fileId, priority: MediaLoader.visiblePriority, label: "Downloading sticker") {
            image = UIImage(contentsOfFile: path)
        } else if let thumbnail {
            image = await model.media.image(for: thumbnail, label: "Downloading sticker")
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
                        .task(id: thumbnail.uniqueId) { image = await model.media.image(for: thumbnail) }
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

    init(request: ViewerRequest) {
        self.request = request
        _index = State(initialValue: request.index)
    }

    private var current: ViewerItem? {
        request.items.indices.contains(index) ? request.items[index] : nil
    }

    private var actionLabel: String? {
        switch current {
        case .photo, .video, .animation: return "Save"
        case .document: return "Share"
        case nil: return nil
        }
    }

    var body: some View {
        HPViewer(counter: request.items.count > 1 ? "\(index + 1) / \(request.items.count)" : nil,
                 caption: request.caption,
                 actionLabel: actionLabel,
                 onAction: performAction,
                 onClose: { model.viewer = nil }) {
            TabView(selection: $index) {
                ForEach(Array(request.items.enumerated()), id: \.offset) { i, item in
                    ViewerPageView(item: item)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragY)
            .simultaneousGesture(
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
    }

    private func performAction() {
        guard let current else { return }
        switch current {
        case .photo(_, let full):
            Task {
                guard let image = await model.media.image(for: full, priority: MediaLoader.tappedPriority) else {
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
            Task {
                let name = file.fileName.isEmpty ? "Document" : file.fileName
                guard let path = await model.media.download(file.fileId, priority: MediaLoader.tappedPriority, label: "Downloading \(name)") else { return }
                ShareSheet.present(url: URL(fileURLWithPath: path))
            }
        }
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
            if loading, image == nil || model.media.cached(full) == nil {
                HPProgressRing(progress: model.media.state(full.fileId).progress) {
                    model.media.cancel(full.fileId)
                }
            }
        }
        .task(id: full.uniqueId) { await load() }
    }

    private func load() async {
        if let hit = model.media.cached(full) { image = hit; loading = false; return }
        image = model.media.cached(preview) ?? model.media.minithumbnail(preview)
        if let loaded = await model.media.image(for: full, priority: MediaLoader.tappedPriority) { image = loaded }
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
            poster = model.media.cached(thumbnail) ?? model.media.minithumbnail(thumbnail)
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
        }
    }

    @ViewBuilder private func content(path: String) -> some View {
        switch kind {
        case .pdf:
            PDFKitView(url: URL(fileURLWithPath: path))
        case .image:
            ZoomableImageView(image: UIImage(contentsOfFile: path))
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
