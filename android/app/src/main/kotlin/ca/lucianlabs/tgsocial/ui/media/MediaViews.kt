package ca.lucianlabs.tgsocial.ui.media

import android.graphics.ImageDecoder
import android.graphics.drawable.AnimatedImageDrawable
import android.os.Build
import android.widget.ImageView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import android.view.TextureView
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPDownloadRing
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMosaic
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPPlayCircle
import ca.lucianlabs.housepour.HPPlayerRow
import ca.lucianlabs.housepour.HPScrubber
import ca.lucianlabs.housepour.HPSpectrogramStrip
import ca.lucianlabs.housepour.HPStrip
import ca.lucianlabs.housepour.HPSmall
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTime
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.TgApp
import ca.lucianlabs.tgsocial.demo.DemoMedia
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.LinkPreviewInfo
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostMedia
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.protocol.Waveform
import ca.lucianlabs.tgsocial.repo.FileState
import ca.lucianlabs.tgsocial.repo.MediaRepo
import ca.lucianlabs.tgsocial.ui.components.openInTelegram
import ca.lucianlabs.tgsocial.ui.components.openLink
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage
import ca.lucianlabs.tgsocial.ui.components.rememberTdImagePx
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale

@Composable
fun rememberTgApp(): TgApp = LocalContext.current.applicationContext as TgApp

/**
 * `as?`, not `as`: the layout assertions boot the stock Application rather than `TgApp` (TDLib has no
 * business in a measure pass), and no app simply means no repo — the same state as a file that has not
 * arrived yet. [rememberTdImagePx] has taken this shape since the hit-region harness landed.
 */
@Composable
fun rememberTgAppOrNull(): TgApp? = LocalContext.current.applicationContext as? TgApp

@Composable
fun rememberFileState(ref: FileRef?): FileState? {
    val app = rememberTgAppOrNull() ?: return null
    val files by app.media.files.collectAsStateWithLifecycle()
    return ref?.let { files[it.id] }
}

@Composable
fun rememberMini(b64: String?): ImageBitmap? {
    val app = rememberTgAppOrNull()
    return remember(b64, app) { app?.media?.mini(b64) }
}

/** Document kinds the in-app viewer opens (PRODUCT §2.11); everything else downloads then offers Share / Save. */
enum class DocKind { PDF, TEXT, IMAGE, AUDIO, VIDEO, OTHER }

fun docKind(mimeType: String, fileName: String): DocKind {
    val mime = mimeType.lowercase(Locale.ROOT)
    val ext = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
    return when {
        mime == "application/pdf" || ext == "pdf" -> DocKind.PDF
        mime.startsWith("image/") || ext in setOf("png", "jpg", "jpeg", "webp", "gif", "bmp", "heic") -> DocKind.IMAGE
        mime.startsWith("audio/") || ext in setOf("mp3", "m4a", "flac", "ogg", "opus", "wav") -> DocKind.AUDIO
        mime.startsWith("video/") || ext in setOf("mp4", "mov", "webm", "mkv") -> DocKind.VIDEO
        mime.startsWith("text/") || mime == "application/json" || mime == "application/xml" ||
            ext in setOf("txt", "md", "json", "xml", "csv", "log", "yml", "yaml", "kt", "swift", "js", "ts", "html", "css", "sh", "py") -> DocKind.TEXT
        else -> DocKind.OTHER
    }
}

/** True when tapping this media opens the full-screen viewer. */
fun opensViewer(media: PostMedia): Boolean = when (media) {
    is PostMedia.Photo, is PostMedia.Video, is PostMedia.Animation, is PostMedia.VideoNote -> true
    is PostMedia.Document -> docKind(media.mimeType, media.fileName) != DocKind.OTHER
    else -> false
}

private fun aspect(w: Int, h: Int): Float = if (w > 0 && h > 0) (w.toFloat() / h).coerceIn(0.5f, 2.5f) else 16f / 9f

/**
 * PRODUCT §2.3 / §2.11 — everything a post carries, inline. Tapping media opens it in the app, never Telegram
 * or the browser; the link preview is the one exception and says so by being a link.
 */
@OptIn(UnstableApi::class)
@Composable
fun MediaItems(post: Post, onOpenViewer: (Int) -> Unit) {
    // PRODUCT §2.11.3 — "a post with more than one photo is a mosaic, not a stack". The album's photos are
    // drawn ONCE, as one block, in the place the first of them held; the rest of the post's media keeps its
    // own rows. The pair is (index in `post.media`, photo), because a tile's tap opens the carousel at that
    // item's page and the page numbering is the post's, not the album's.
    val photos = remember(post.media) {
        post.media.withIndex().mapNotNull { (i, m) -> (m as? PostMedia.Photo)?.let { i to it } }
    }
    val mosaic = photos.size > 1
    Column(verticalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
        post.media.forEachIndexed { index, media ->
            val key = "${post.key}#$index"
            if (mosaic && media is PostMedia.Photo) {
                if (index == photos.first().first) PhotoMosaic(photos, onOpenViewer)
                return@forEachIndexed
            }
            when (media) {
                is PostMedia.Photo -> InlinePhoto(media) { onOpenViewer(index) }
                is PostMedia.Video -> InlineVideo(key, media) { onOpenViewer(index) }
                is PostMedia.Animation -> InlineAnimation(key, media) { onOpenViewer(index) }
                is PostMedia.VideoNote -> InlineVideoNote(key, media) { onOpenViewer(index) }
                is PostMedia.Audio -> AudioRow(key, media, post)
                is PostMedia.Voice -> VoiceRow(key, post.sourceTitle, media, post)
                is PostMedia.Document -> DocumentRow(media) { onOpenViewer(index) }
                is PostMedia.Sticker -> InlineSticker(media)
                is PostMedia.Summary -> SummaryRow(media.text, post)
            }
        }
        post.linkPreview?.let { LinkPreviewRow(it) }
    }
}

/** PRODUCT §2.11 — poll / location / contact summaries: a muted one-liner whose tap is the Telegram hand-off. */
@Composable
private fun SummaryRow(text: String, post: Post) {
    val context = LocalContext.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = HPTokens.Space.touchMin)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                openInTelegram(context, DeepLink.post(post.sourceUsername, post.messageId))
            }
            .semantics { contentDescription = "Open in Telegram" },
        contentAlignment = Alignment.CenterStart,
    ) {
        HPMuted(text, maxLines = 1)
    }
}

/** The blur-up ground every visual media sits on: minithumbnail (blurred where the OS can) under the real pixels. */
@Composable
private fun MediaGround(mini: ImageBitmap?, image: ImageBitmap?) {
    if (image == null && mini != null) {
        Image(
            bitmap = mini,
            contentDescription = null,
            modifier = Modifier.fillMaxSize().blur(HPTokens.Space.rowGap),
            contentScale = ContentScale.Crop,
        )
    }
    if (image != null) {
        Image(bitmap = image, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    }
}

/**
 * The video output surface: a plain TextureView driven by ExoPlayer. media3's own PlayerView/transport chrome
 * never appears — every control around this is House Pour (PRODUCT §2.11).
 */
@OptIn(UnstableApi::class)
@Composable
fun PlayerVideoSurface(player: ExoPlayer, modifier: Modifier = Modifier) {
    AndroidView(
        factory = { context -> TextureView(context) },
        update = { view -> player.setVideoTextureView(view) },
        onRelease = { view -> player.clearVideoTextureView(view) },
        modifier = modifier,
    )
}

@Composable
private fun InlinePhoto(media: PostMedia.Photo, onTap: () -> Unit) {
    val image = rememberTdImage(media.file, mediaWidth())
    val mini = rememberMini(media.mini)
    val state = rememberFileState(media.file)
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(aspect(media.width, media.height))
            .clip(shape)
            .background(HPTokens.Colors.bg2, shape)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onTap)
            .semantics { contentDescription = "Photo" },
        contentAlignment = Alignment.Center,
    ) {
        MediaGround(mini, image)
        if (image == null && state?.active == true) {
            val app = rememberTgApp()
            HPDownloadRing(state.progress, onCancel = { app.media.cancel(media.file) })
        }
    }
}

/**
 * PRODUCT §2.11.3 — the album as one object. [HPMosaic] owns the arrangement and the geometry; this owns
 * what goes in a cell, which is the memory half of the section.
 *
 * **Tiles are thumbnails.** Each asks the byte-budgeted cache for `tileWidthPx` — half the column, the widest
 * any tile is drawn at — *by value*, which is the only way to reach that decode bucket (`MediaRepo.bucket`).
 * The alternative is what a naive mosaic does: four card-width decodes for four pictures drawn at a quarter
 * of the area each, which on a small device is more bytes for one post than the whole image budget. Past four
 * photos nothing further is even requested — the fifth onward live behind the `+N` and are decoded when the
 * carousel reaches them.
 */
@Composable
private fun PhotoMosaic(photos: List<Pair<Int, PostMedia.Photo>>, onOpenViewer: (Int) -> Unit) {
    val aspects = remember(photos) {
        photos.map { (_, p) -> if (p.width > 0 && p.height > 0) p.width.toFloat() / p.height else 0f }
    }
    HPMosaic(
        count = photos.size,
        aspects = aspects,
        // The carousel opens at the tile that was tapped (§2.11.3), which is that photo's page in the post.
        onTap = { tile -> photos.getOrNull(tile)?.let { onOpenViewer(it.first) } },
    ) { tile, _, _ ->
        photos.getOrNull(tile)?.second?.let { MosaicTile(it) }
    }
}

/** One cell: the blur-up ground under a tile-sized decode, cropped to cover (§2.11.3). */
@Composable
private fun MosaicTile(photo: PostMedia.Photo) {
    val app = rememberTgAppOrNull()
    val tilePx = app?.media?.tileWidthPx ?: 0
    val image = rememberTdImagePx(photo.file, tilePx)
    val state = rememberFileState(photo.file)
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        MediaGround(rememberMini(photo.mini), image)
        if (image == null && state?.active == true && app != null) {
            HPDownloadRing(state.progress, onCancel = { app.media.cancel(photo.file) })
        }
    }
}

/**
 * The width a full-bleed card image is actually drawn at on a screen [screenWidthDp] wide: the House Pour
 * content column, capped and padded (PRODUCT §1). This is the single source of that arithmetic — `TgApp` sizes
 * the decode bucket from it too, and a bucket that disagreed with the drawn width sent every landscape photo
 * into the zoom rendition.
 */
fun mediaWidthDp(screenWidthDp: Int): Dp =
    screenWidthDp.dp.coerceAtMost(HPTokens.Space.columnMax) - HPTokens.Space.columnSide * 2 - HPTokens.Space.cardPad * 2

@Composable
private fun mediaWidth() = mediaWidthDp(androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp)

/** Pauses/releases with the composition, pauses when scrolled away (disposal) and when the app stops. */
@OptIn(UnstableApi::class)
@Composable
private fun rememberOwnedPlayer(key: String, build: () -> androidx.media3.exoplayer.ExoPlayer): androidx.media3.exoplayer.ExoPlayer {
    val app = rememberTgApp()
    val player = remember(key) { build() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(key) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) player.pause()
        }
        lifecycle.addObserver(observer)
        onDispose {
            lifecycle.removeObserver(observer)
            app.playback.releaseVideo(key)
            player.release()
        }
    }
    return player
}

@OptIn(UnstableApi::class)
@Composable
private fun InlineVideo(key: String, media: PostMedia.Video, onOpenFull: () -> Unit) {
    val app = rememberTgApp()
    var playing by remember(key) { mutableStateOf(false) }
    // PRODUCT §2.22.4 — a demo clip is generated, not downloaded, and the encode takes a second or two. It is
    // warmed here, off the main thread, the moment the poster is on screen; until it lands the play control is
    // the same not-yet state a file still downloading puts it in.
    var ready by remember(key) { mutableStateOf(!DemoMedia.isDemo(media.file)) }
    LaunchedEffect(key) { if (!ready) ready = app.media.localPath(media.file) != null }
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(aspect(media.width, media.height))
            .clip(shape)
            .background(HPTokens.Colors.bg2, shape)
            .then(
                // The whole poster plays inline (PRODUCT §2.3 "tap plays inline"), not just the 40pt circle.
                if (!playing) Modifier
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                        if (ready) {
                            app.playback.claimVideo(key)
                            playing = true
                        }
                    }
                    .semantics { contentDescription = "Play video" }
                else Modifier,
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (!playing) {
            val thumb = rememberTdImage(media.thumb, mediaWidth())
            MediaGround(rememberMini(media.mini), thumb)
            HPPill(
                Format.duration(media.durationSeconds),
                HPPillTone.NEUTRAL,
                modifier = Modifier.align(Alignment.BottomEnd).padding(HPTokens.Space.rowGap),
            )
            HPPlayCircle(
                playing = false,
                raised = true,
                onToggle = {
                    if (ready) {
                        app.playback.claimVideo(key)
                        playing = true
                    }
                },
                label = "Play video",
            )
        } else {
            InlinePlayerSurface(
                key = key,
                file = media.file,
                mimeType = media.mimeType,
                durationSeconds = media.durationSeconds,
                loop = false,
                muted = false,
                onSurfaceTap = onOpenFull,
                onEnded = { playing = false },
            )
        }
    }
}

/**
 * One playing surface's transport state, hoisted out of the surface that produces it.
 *
 * A video MESSAGE draws its transport over the picture, so the state could live inside the surface. A video
 * NOTE cannot: PRODUCT §2.11.1 puts the strip "underneath" a circular player, and the circle is clipped to a
 * `CircleShape` — anything drawn inside it is a chord of the circle, not a row under it. So the state comes
 * out here and both placements read the same numbers.
 */
@Stable
internal class InlinePlayback(val player: ExoPlayer, durationSeconds: Int) {
    var playing by mutableStateOf(true)
        internal set
    var positionMs by mutableLongStateOf(0L)
        internal set
    var durationMs by mutableLongStateOf(durationSeconds * 1000L)
        internal set

    val progress: Float get() = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
}

/** The TDLib-streamed player behind an inline surface, plus the 250 ms tick every transport reads. */
@OptIn(UnstableApi::class)
@Composable
private fun rememberInlinePlayback(
    key: String,
    file: FileRef,
    mimeType: String,
    durationSeconds: Int,
    loop: Boolean,
    muted: Boolean,
    onEnded: (() -> Unit)?,
): InlinePlayback {
    val app = rememberTgApp()
    val player = rememberOwnedPlayer(key) {
        // Starting unmuted playback claims the video slot before the active-check composes, so a viewer
        // page pauses the inline player underneath instead of pausing itself (PRODUCT §2.11).
        if (!muted) app.playback.claimVideo(key)
        app.playback.newPlayer(MediaRepo.PRIORITY_TAPPED).apply {
            setMediaItem(app.playback.mediaItem(file, mimeType))
            repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
            volume = if (muted) 0f else 1f
            prepare()
            playWhenReady = true
        }
    }
    val playback = remember(key) { InlinePlayback(player, durationSeconds) }
    DisposableEffect(key) {
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(playingNow: Boolean) {
                playback.playing = playingNow
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED && !loop) onEnded?.invoke()
            }
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }
    LaunchedEffect(key) {
        while (true) {
            playback.positionMs = player.currentPosition.coerceAtLeast(0)
            if (player.duration > 0) playback.durationMs = player.duration
            kotlinx.coroutines.delay(250)
        }
    }
    val active by app.playback.activeVideo.collectAsStateWithLifecycle()
    LaunchedEffect(active) {
        if (active != key && !muted) player.pause()
    }
    return playback
}

/** The picture alone: the video output and its tap. The transport is placed by whoever owns the layout. */
@OptIn(UnstableApi::class)
@Composable
private fun InlinePlayerPicture(playback: InlinePlayback, key: String, onSurfaceTap: (() -> Unit)?) {
    val app = rememberTgApp()
    PlayerVideoSurface(
        playback.player,
        Modifier
            .fillMaxSize()
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                if (onSurfaceTap != null) onSurfaceTap() else if (playback.player.isPlaying) playback.player.pause() else {
                    app.playback.claimVideo(key)
                    playback.player.play()
                }
            },
    )
}

/**
 * The playing inline video: TDLib-streamed ExoPlayer under a House Pour transport (serif times + hairline
 * scrubber on the translucent topbar fill). The system transport never appears.
 */
@OptIn(UnstableApi::class)
@Composable
fun InlinePlayerSurface(
    key: String,
    file: FileRef,
    mimeType: String,
    durationSeconds: Int,
    loop: Boolean,
    muted: Boolean,
    onSurfaceTap: (() -> Unit)?,
    onEnded: (() -> Unit)? = null,
    showTransport: Boolean = true,
) {
    val app = rememberTgApp()
    val playback = rememberInlinePlayback(key, file, mimeType, durationSeconds, loop, muted, onEnded)
    Box(Modifier.fillMaxSize()) {
        InlinePlayerPicture(playback, key, onSurfaceTap)
        if (showTransport) {
            Row(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .padding(HPTokens.Space.rowGap)
                    .background(HPTokens.Colors.topbarBg, RoundedCornerShape(HPTokens.Radius.pill))
                    .padding(horizontal = HPTokens.Space.rowPad),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
            ) {
                HPPlayGlyphButton(playback.playing) {
                    if (playback.player.isPlaying) playback.player.pause() else {
                        app.playback.claimVideo(key)
                        playback.player.play()
                    }
                }
                HPTime(Format.duration((playback.positionMs / 1000).toInt()))
                HPScrubber(
                    progress = playback.progress,
                    onSeek = { playback.player.seekTo((it * playback.durationMs).toLong()) },
                    modifier = Modifier.weight(1f),
                )
                HPTime(Format.duration((playback.durationMs / 1000).toInt()), color = HPTokens.Colors.muted)
            }
        }
    }
}

/**
 * PRODUCT §2.11.1, last paragraph — a video note's transport: "a video note keeps its circular player and
 * gets the strip as the transport underneath it." Same components and same order as the video message's
 * transport above (glyph, elapsed, scrubber, total) with the strip in the scrubber's place, which is the
 * one difference §2.11.1 draws between the two: a video MESSAGE keeps the hairline, a video NOTE takes the
 * strip, because "this replaces the audio scrubber only".
 *
 * It sits in the card's flow rather than over the picture — the circle is clipped, and a control drawn
 * inside it would be a chord rather than a row. iOS stacks it the same way (`InlineVideoView.body`:
 * `if mode.hasTransport, started`), and web appends the strip after the circle's box (js/media.js
 * `videoNoteBlock`).
 *
 * Values in, callbacks out: no player, no repo and no `TgApp`, so what this draws is what the caller
 * measured, and a test can drive it without an ExoPlayer.
 */
@Composable
internal fun VideoNoteTransport(
    playing: Boolean,
    positionMs: Long,
    durationMs: Long,
    strip: HPStrip?,
    onToggle: () -> Unit,
    onSeek: (Float) -> Unit,
    modifier: Modifier = Modifier,
    onStripVisible: (widthPx: Int, heightPx: Int) -> Unit = { _, _ -> },
) {
    Row(
        modifier = modifier.fillMaxWidth().padding(top = HPTokens.Space.rowGap),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
    ) {
        HPPlayGlyphButton(playing, onToggle)
        HPTime(Format.duration((positionMs / 1000).toInt()))
        HPSpectrogramStrip(
            strip,
            progress = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f,
            onSeek = onSeek,
            modifier = Modifier.weight(1f),
            label = "Seek video note",
            onVisible = onStripVisible,
        )
        HPTime(Format.duration((durationMs / 1000).toInt()), color = HPTokens.Colors.muted)
    }
}

/** A bare play/pause tap target for transports where the 40pt circle would cover the picture. */
@Composable
private fun HPPlayGlyphButton(playing: Boolean, onToggle: () -> Unit) {
    Box(
        modifier = Modifier
            .size(HPTokens.Space.touchMin)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onToggle)
            .semantics { contentDescription = if (playing) "Pause" else "Play" },
        contentAlignment = Alignment.Center,
    ) {
        ca.lucianlabs.housepour.HPPlayGlyph(playing, HPTokens.Colors.ink)
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun InlineAnimation(key: String, media: PostMedia.Animation, onTap: () -> Unit) {
    val state = rememberFileState(media.file)
    val app = rememberTgApp()
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    var path by remember(key) { mutableStateOf<String?>(null) }
    LaunchedEffect(key) { path = app.media.localPath(media.file) ?: app.media.download(media.file, MediaRepo.PRIORITY_VISIBLE, "Downloading animation") }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(aspect(media.width, media.height))
            .clip(shape)
            .background(HPTokens.Colors.bg2, shape)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onTap)
            .semantics { contentDescription = "Animation" },
        contentAlignment = Alignment.Center,
    ) {
        val ready = path
        when {
            ready != null && media.mimeType.equals("image/gif", ignoreCase = true) -> AnimatedGif(ready, media.thumb)
            ready != null -> InlinePlayerSurface(
                key = key,
                file = media.file,
                mimeType = media.mimeType,
                durationSeconds = 0,
                loop = true,
                muted = true,
                onSurfaceTap = onTap,
                showTransport = false,
            )
            else -> {
                MediaGround(rememberMini(media.mini), rememberTdImage(media.thumb, mediaWidth()))
                if (state?.active == true) HPDownloadRing(state.progress, onCancel = { app.media.cancel(media.file) })
            }
        }
    }
}

/**
 * GIF documents and animations: AnimatedImageDrawable on 28+, first frame before that (PRODUCT platform note).
 *
 * Two memory rules live here. The decode is bounded to the card width — an AnimatedImageDrawable holds decoded
 * frame buffers, so a 1080p GIF in a 360 px card costs nine times what it needs to. And the drawable is
 * **stopped and detached in `onRelease`**: without that, a GIF scrolled off screen kept animating and kept its
 * buffers alive for as long as the process did. `key(path)` makes the view a new node when the file changes so
 * the old one is actually released instead of silently reused with a stale frame.
 */
@Composable
fun AnimatedGif(path: String, thumb: FileRef?) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        val cardWidth = mediaWidth()
        val targetPx = with(LocalDensity.current) { cardWidth.roundToPx() }
        key(path) {
            AndroidView(
                factory = { context ->
                    ImageView(context).apply {
                        scaleType = ImageView.ScaleType.CENTER_CROP
                        runCatching {
                            val source = ImageDecoder.createSource(File(path))
                            val drawable = ImageDecoder.decodeDrawable(source) { decoder, info, _ ->
                                val w = info.size.width
                                if (w > targetPx) {
                                    val h = (info.size.height.toLong() * targetPx / w).toInt().coerceAtLeast(1)
                                    decoder.setTargetSize(targetPx, h)
                                }
                            }
                            setImageDrawable(drawable)
                            (drawable as? AnimatedImageDrawable)?.apply {
                                repeatCount = AnimatedImageDrawable.REPEAT_INFINITE
                                start()
                            }
                        }
                    }
                },
                onRelease = { view ->
                    (view.drawable as? AnimatedImageDrawable)?.stop()
                    view.setImageDrawable(null)
                },
                modifier = Modifier.fillMaxSize(),
            )
        }
    } else {
        val image = rememberTdImage(thumb, mediaWidth())
        MediaGround(null, image)
    }
}

/**
 * The round frame a video note lives in (PRODUCT §2.11 "circular inline player"): `bg2`, a hairline border,
 * 62% of the column. [onPlay] non-null is the poster state, where the whole circle is the play target;
 * null is the playing state, where the surface inside owns the tap.
 */
@Composable
private fun VideoNoteCircle(onPlay: (() -> Unit)?, content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier
                .fillMaxWidth(0.62f)
                .aspectRatio(1f)
                .clip(CircleShape)
                .background(HPTokens.Colors.bg2, CircleShape)
                .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, CircleShape)
                .then(
                    if (onPlay != null) Modifier
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onPlay)
                        .semantics { contentDescription = "Play video note" }
                    else Modifier,
                ),
            contentAlignment = Alignment.Center,
            content = content,
        )
    }
}

/**
 * PRODUCT §2.11.1, last paragraph — the video note ONCE IT IS PLAYING: "a video note keeps its circular
 * player and gets the strip as the transport underneath it." Both halves of that sentence are assembled
 * here rather than inside [InlineVideoNote], with the picture as a slot: the real note passes the ExoPlayer
 * surface and `VideoNoteTransportTest` passes a stand-in, so the arrangement the sentence describes is
 * something a test can render and touch without a player.
 *
 * A Column, not a Box: the circle is a clipped shape, so the transport is a sibling under it rather than an
 * overlay inside it. And ONE child rather than two — [MediaItems] spaces its children by `rowGap`, so a bare
 * pair here would open a second gap between a note and its own transport, on top of the one the transport
 * already pads with.
 */
@Composable
internal fun PlayingVideoNote(
    playing: Boolean,
    positionMs: Long,
    durationMs: Long,
    strip: HPStrip?,
    onToggle: () -> Unit,
    onSeek: (Float) -> Unit,
    onStripVisible: (widthPx: Int, heightPx: Int) -> Unit = { _, _ -> },
    picture: @Composable BoxScope.() -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        VideoNoteCircle(onPlay = null, content = picture)
        VideoNoteTransport(
            playing = playing,
            positionMs = positionMs,
            durationMs = durationMs,
            strip = strip,
            onToggle = onToggle,
            onSeek = onSeek,
            onStripVisible = onStripVisible,
        )
    }
}

/**
 * PRODUCT §2.11 — the video note's circular inline player, and the gate on [PlayingVideoNote] under it.
 *
 * Until the circle is tapped there is no player for a transport to drive — the same gate iOS runs
 * (`InlineVideoView.body`: `if mode.hasTransport, started`) — which is also what keeps §2.11.1's "analysis
 * never runs for a row that has not been played" honest here: the strip is what reports its geometry, so a
 * scrolled feed of round videos analyses nothing until one is played.
 */
@OptIn(UnstableApi::class)
@Composable
private fun InlineVideoNote(key: String, media: PostMedia.VideoNote, onTap: () -> Unit) {
    val app = rememberTgApp()
    var playing by remember(key) { mutableStateOf(false) }
    // The analyser reads the note's own mp4 — MediaExtractor selects its audio track (PcmDecoder), so the
    // file the player is already streaming is the file the strip is drawn from, and there is one download.
    val (strip, onStripVisible) = rememberStrip(media.file, media.durationSeconds)
    if (!playing) {
        VideoNoteCircle(onPlay = { app.playback.claimVideo(key); playing = true }) {
            MediaGround(rememberMini(media.mini), rememberTdImage(media.thumb, mediaWidth()))
            HPPill(
                Format.duration(media.durationSeconds),
                HPPillTone.NEUTRAL,
                modifier = Modifier.align(Alignment.BottomCenter).padding(HPTokens.Space.rowGap),
            )
            HPPlayCircle(
                playing = false,
                raised = true,
                onToggle = {
                    app.playback.claimVideo(key)
                    playing = true
                },
                label = "Play video note",
            )
        }
        return
    }
    val playback = rememberInlinePlayback(
        key = key,
        file = media.file,
        mimeType = "video/mp4",
        durationSeconds = media.durationSeconds,
        loop = false,
        muted = false,
        onEnded = { playing = false },
    )
    PlayingVideoNote(
        playing = playback.playing,
        positionMs = playback.positionMs,
        durationMs = playback.durationMs,
        strip = strip,
        onToggle = {
            if (playback.player.isPlaying) playback.player.pause() else {
                app.playback.claimVideo(key)
                playback.player.play()
            }
        },
        onSeek = { playback.player.seekTo((it * playback.durationMs).toLong()) },
        onStripVisible = onStripVisible,
        // Tapping the playing note opens the full-screen viewer, like the video surface.
        picture = { InlinePlayerPicture(playback, key, onTap) },
    )
}

/**
 * PRODUCT §2.11.1 — the strip's pixel geometry and the analysed result for one clip, requested only once the
 * strip has actually been laid out on screen.
 *
 * The `version` counter is what re-reads the cache: the strip itself lives in [MediaRepo]'s byte-bounded
 * store, so an eviction under memory pressure really does free it and the next read simply finds nothing and
 * asks again. Holding the strip in composition state instead would pin every strip a scroll ever produced.
 */
@Composable
private fun rememberStrip(file: FileRef, durationSeconds: Int, fallbackEnvelope: FloatArray? = null): Pair<HPStrip?, (Int, Int) -> Unit> {
    val app = rememberTgApp()
    val version by app.strips.ready.collectAsStateWithLifecycle()
    var geometry by remember(file.uniqueId) { mutableStateOf(0 to 0) }
    val analysed = remember(file.uniqueId, geometry, version) {
        if (geometry.first <= 0) null else app.strips.strip(file.uniqueId, geometry.first, geometry.second)
    }
    LaunchedEffect(file.uniqueId, geometry) {
        if (geometry.first > 0) app.strips.request(file, durationSeconds, geometry.first, geometry.second)
    }
    val strip = remember(analysed, fallbackEnvelope) {
        when {
            analysed != null -> HPStrip(analysed.spectrum, analysed.envelope.takeIf { it.size >= 2 } ?: fallbackEnvelope)
            fallbackEnvelope != null -> HPStrip(null, fallbackEnvelope)
            else -> null
        }
    }
    val onVisible: (Int, Int) -> Unit = remember(file.uniqueId) { { w, h -> geometry = w to h } }
    return strip to onVisible
}

@Composable
private fun AudioRow(key: String, media: PostMedia.Audio, post: Post) {
    val app = rememberTgApp()
    val now by app.playback.now.collectAsStateWithLifecycle()
    val state = rememberFileState(media.file)
    val isThis = now?.key == key
    val title = media.title.ifBlank { media.fileName.ifBlank { "Audio" } }
    val (strip, onStripVisible) = rememberStrip(media.file, media.durationSeconds)
    HPPlayerRow(
        title = title,
        subtitle = media.performer.takeIf { it.isNotBlank() },
        playing = isThis && now?.playing == true,
        progress = if (isThis) now?.progress ?: 0f else 0f,
        elapsed = Format.duration(if (isThis) ((now?.positionMs ?: 0) / 1000).toInt() else 0),
        total = Format.duration(media.durationSeconds),
        onToggle = { app.playback.toggleAudio(key, title, media.file, media.mimeType, media.durationSeconds, post) },
        onSeek = { fraction ->
            if (isThis) app.playback.seekAudio(fraction)
            else app.playback.toggleAudio(key, title, media.file, media.mimeType, media.durationSeconds, post)
        },
        strip = strip,
        downloadProgress = state?.takeIf { it.active && !it.done }?.progress,
        onStripVisible = onStripVisible,
    )
}

@Composable
private fun VoiceRow(key: String, sourceTitle: String, media: PostMedia.Voice, post: Post) {
    val app = rememberTgApp()
    val now by app.playback.now.collectAsStateWithLifecycle()
    val state = rememberFileState(media.file)
    val isThis = now?.key == key
    // PRODUCT §2.11.1 — TDLib ships a voice note's waveform, so the silhouette is drawn IMMEDIATELY, with no
    // decode at all, and the spectrum fills in behind it. 128 points: enough to read as a shape at strip
    // width, few enough that the resample is free.
    val samples = remember(media.waveform) {
        val raw = media.waveform?.let { runCatching { java.util.Base64.getDecoder().decode(it) }.getOrNull() }
        resample(Waveform.decode(raw ?: ByteArray(0)), 128).toFloatArray().takeIf { it.size >= 2 }
    }
    val (strip, onStripVisible) = rememberStrip(media.file, media.durationSeconds, samples)
    // PRODUCT §2.11.2 — the dock draws the same envelope this row does. A voice note's arrives free with the
    // message, so offer it: an analysed envelope still wins, this only keeps the dock from drawing a flat
    // line for a clip whose shape is already known.
    LaunchedEffect(media.file.uniqueId, samples) { samples?.let { app.strips.offerEnvelope(media.file.uniqueId, it) } }
    HPPlayerRow(
        title = sourceTitle,
        subtitle = null,
        playing = isThis && now?.playing == true,
        progress = if (isThis) now?.progress ?: 0f else 0f,
        elapsed = Format.duration(if (isThis) ((now?.positionMs ?: 0) / 1000).toInt() else 0),
        total = Format.duration(media.durationSeconds),
        onToggle = { app.playback.toggleAudio(key, sourceTitle, media.file, media.mimeType, media.durationSeconds, post) },
        onSeek = { fraction ->
            if (isThis) app.playback.seekAudio(fraction)
            else app.playback.toggleAudio(key, sourceTitle, media.file, media.mimeType, media.durationSeconds, post)
        },
        strip = strip,
        downloadProgress = state?.takeIf { it.active && !it.done }?.progress,
        onStripVisible = onStripVisible,
    )
}

private fun resample(values: List<Float>, target: Int): List<Float> {
    if (values.isEmpty()) return emptyList()
    if (values.size <= target) return values
    return List(target) { i ->
        val start = i * values.size / target
        val end = ((i + 1) * values.size / target).coerceAtLeast(start + 1)
        values.subList(start, end).max()
    }
}

/** A document glyph drawn from tokens: page outline with two hairline text lines. No icon font, no emoji. */
@Composable
private fun DocGlyph() {
    Box(
        Modifier
            .size(HPTokens.Space.rowPad + HPTokens.Space.labelBottom, HPTokens.Space.cardGap + HPTokens.Space.labelBottom)
            .drawBehind {
                val stroke = HPTokens.BORDER_WIDTH.dp.toPx()
                drawRoundRect(
                    HPTokens.Colors.muted,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(stroke),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(stroke * 2),
                )
                val inset = size.width * 0.25f
                for (frac in listOf(0.4f, 0.6f)) {
                    drawLine(HPTokens.Colors.muted, Offset(inset, size.height * frac), Offset(size.width - inset, size.height * frac), stroke, StrokeCap.Round)
                }
            },
    )
}

/**
 * PRODUCT §2.3/§2.11 — the document row. `Open` opens viewable types in the app; other types download here and
 * then offer Share / Save. The determinate ring cancels on tap.
 */
@Composable
private fun DocumentRow(media: PostMedia.Document, onOpenViewer: () -> Unit) {
    val app = rememberTgApp()
    val context = LocalContext.current
    val state = rememberFileState(media.file)
    val kind = docKind(media.mimeType, media.fileName)
    val viewable = kind != DocKind.OTHER
    val downloaded = state?.done == true || media.file.localPath != null
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(HPTokens.Colors.bg2, shape)
            .padding(HPTokens.Space.rowPad)
            .semantics { contentDescription = media.fileName },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
    ) {
        DocGlyph()
        Column(Modifier.weight(1f)) {
            HPBody(media.fileName.ifBlank { "File" }, maxLines = 1)
            val type = media.mimeType.substringAfterLast('/', "").ifBlank { media.fileName.substringAfterLast('.', "") }
            val parts = listOfNotNull(
                media.size.takeIf { it > 0 }?.let { Format.size(it) },
                type.takeIf { it.isNotBlank() }?.uppercase(Locale.ROOT),
            )
            if (parts.isNotEmpty()) HPMonoSmall(parts.joinToString(" · "), maxLines = 1)
        }
        when {
            state?.active == true && !downloaded -> HPDownloadRing(state.progress, onCancel = { app.media.cancel(media.file) })
            viewable -> HPButton("Open", onOpenViewer, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
            downloaded -> {
                HPButton("Share", {
                    scope.launch {
                        val path = app.media.localPath(media.file) ?: return@launch
                        app.media.share(context, path, media.mimeType)
                    }
                }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
            }
            else -> HPButton("Open", {
                scope.launch { app.media.download(media.file, MediaRepo.PRIORITY_TAPPED, "Downloading file") }
            }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
        }
    }
}

@Composable
private fun InlineSticker(media: PostMedia.Sticker) {
    val ref = if (media.animated) media.thumb else media.file
    val image = rememberTdImage(ref ?: media.thumb, mediaWidth() / 2)
    Box(Modifier.fillMaxWidth(0.5f).aspectRatio(aspect(media.width, media.height)).semantics { contentDescription = "Sticker" }) {
        if (image != null) {
            Image(bitmap = image, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
        }
    }
}

/** PRODUCT §2.11 — `linkPreview` as a bordered row; opens in the system browser (the one exception). */
@Composable
private fun LinkPreviewRow(preview: LinkPreviewInfo) {
    val context = LocalContext.current
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line2, shape)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) { openLink(context, preview.url) }
            .padding(HPTokens.Space.rowPad)
            .semantics { contentDescription = "Open link" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
    ) {
        val thumb = rememberTdImage(preview.thumb, HPTokens.Space.avatarProfile)
        if (thumb != null) {
            Image(
                bitmap = thumb,
                contentDescription = null,
                modifier = Modifier.size(HPTokens.Space.avatarProfile - HPTokens.Space.cardGap).clip(RoundedCornerShape(HPTokens.Radius.input)),
                contentScale = ContentScale.Crop,
            )
        }
        Column(Modifier.weight(1f)) {
            if (preview.siteName.isNotBlank()) HPMonoSmall(preview.siteName, maxLines = 1)
            val title = preview.title.ifBlank { preview.url }
            HPBody(title, strong = true, maxLines = 2)
            if (preview.description.isNotBlank()) HPSmall(preview.description, maxLines = 2)
        }
        HPText("›", HPTokens.Type.body, HPTokens.Colors.faint, maxLines = 1)
    }
}
