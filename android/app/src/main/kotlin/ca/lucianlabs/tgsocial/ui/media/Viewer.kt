package ca.lucianlabs.tgsocial.ui.media

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.media3.common.util.UnstableApi
import ca.lucianlabs.housepour.HPDownloadRing
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPToastTone
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HPViewer
import ca.lucianlabs.housepour.HPViewerButton
import ca.lucianlabs.housepour.HPViewerDismissState
import ca.lucianlabs.housepour.HPZoomable
import ca.lucianlabs.housepour.hpViewerDismiss
import ca.lucianlabs.tgsocial.demo.DemoCopy
import ca.lucianlabs.tgsocial.demo.DemoGate
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.PostMedia
import ca.lucianlabs.tgsocial.repo.MediaRepo
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.ViewerUi
import ca.lucianlabs.tgsocial.ui.components.rememberTdImagePx
import ca.lucianlabs.tgsocial.ui.screens.ThreadItems
import kotlinx.coroutines.launch

/**
 * PRODUCT §2.11 — the full-screen viewer: ink 96%, pinch/double-tap zoom for photos, swipe-down or `Close` to
 * dismiss, `Save` ghost button, caption below, swipe between the album items of one post. It covers the topbar
 * and the floating tab bar; scroll position under it is untouched.
 *
 * PRODUCT §2.12 — and `Comments`, which does not leave the media: the pages shrink to the mini view at the top
 * (still paging, still tappable to restore) and the thread takes the rest. The thread is targeted at the
 * **current page's post**, so paging re-targets it; every page of one viewer belongs to one post here, which
 * makes that a re-read rather than a reload.
 */
@OptIn(UnstableApi::class)
@Composable
fun PostViewer(vm: AppViewModel, viewer: ViewerUi) {
    val post = viewer.post
    val pages = post.media
    if (pages.isEmpty()) return
    HPViewer(
        pageCount = pages.size,
        initialPage = viewer.page,
        onDismiss = vm::closeViewer,
        caption = post.text?.text,
        onPage = vm::setViewerPage,
        actions = { page ->
            // §2.12's one new control. Its label does not change with the state — copy is shared across the
            // three builds (§3) — and the way back to the media is the mini view's own tap, or Back.
            HPViewerButton("Comments", vm::toggleViewerComments)
            pages.getOrNull(page)?.let { SaveActions(vm, it) }
        },
        sheet = if (viewer.commentsOpen) ({ ViewerComments(vm, viewer) }) else null,
        onRestore = vm::toggleViewerComments,
    ) { page, dismiss ->
        when (val m = pages[page]) {
            is PostMedia.Photo -> ViewerImage(m.file, m.mini, dismiss)
            is PostMedia.Video -> ViewerPlayer("viewer:${post.key}#$page", m.file, m.mimeType, m.durationSeconds, aspect(m.width, m.height), loop = false, muted = false, dismiss = dismiss)
            is PostMedia.Animation ->
                if (m.mimeType.equals("image/gif", ignoreCase = true)) ViewerGif(m, dismiss)
                else ViewerPlayer("viewer:${post.key}#$page", m.file, m.mimeType.ifBlank { "video/mp4" }, 0, aspect(m.width, m.height), loop = true, muted = true, dismiss = dismiss, transport = false)
            is PostMedia.VideoNote -> ViewerVideoNote("viewer:${post.key}#$page", m, dismiss)
            is PostMedia.Document -> ViewerDocument("viewer:${post.key}#$page", m, dismiss)
            is PostMedia.Sticker -> ViewerImage(m.file, null, dismiss)
            is PostMedia.Audio, is PostMedia.Voice, is PostMedia.Summary -> Box(Modifier.fillMaxSize().hpViewerDismiss(dismiss))
        }
    }
}

/**
 * PRODUCT §2.12 — the thread over the media. It is [ThreadItems] without the post card at the top, because the
 * post's media is the mini view directly above it; everything else — the `re:` tree, tap-to-select, the
 * composer — is the Thread screen's own code, running here.
 */
@Composable
private fun ViewerComments(vm: AppViewModel, viewer: ViewerUi) {
    val shape = RoundedCornerShape(topStart = HPTokens.Radius.card, topEnd = HPTokens.Radius.card)
    val nav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    Box(
        modifier = Modifier
            .fillMaxSize()
            .clip(shape)
            .background(HPTokens.Colors.bg, shape),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().imePadding(),
            contentPadding = PaddingValues(
                start = HPTokens.Space.columnSide,
                end = HPTokens.Space.columnSide,
                top = HPTokens.Space.cardGap,
                bottom = HPTokens.Space.cardGap + nav,
            ),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            ThreadItems(vm, viewer.current, includePost = false)
        }
    }
}

private fun aspect(w: Int, h: Int): Float = if (w > 0 && h > 0) w.toFloat() / h else 16f / 9f

private fun extensionFor(mime: String, fallback: String): String = when (mime.lowercase()) {
    "image/jpeg" -> "jpg"
    "image/png" -> "png"
    "image/webp" -> "webp"
    "image/gif" -> "gif"
    "video/mp4" -> "mp4"
    "video/webm" -> "webm"
    "audio/mpeg" -> "mp3"
    "audio/ogg" -> "ogg"
    "application/pdf" -> "pdf"
    else -> fallback
}

private data class Savable(val file: FileRef, val mimeType: String, val name: String, val shareable: Boolean)

private fun savable(media: PostMedia): Savable? = when (media) {
    is PostMedia.Photo -> Savable(media.file, "image/jpeg", "tgsocial-${media.file.uniqueId}.jpg", shareable = false)
    is PostMedia.Video -> Savable(media.file, media.mimeType.ifBlank { "video/mp4" }, "tgsocial-${media.file.uniqueId}.${extensionFor(media.mimeType, "mp4")}", shareable = false)
    is PostMedia.Animation -> Savable(media.file, media.mimeType.ifBlank { "video/mp4" }, "tgsocial-${media.file.uniqueId}.${extensionFor(media.mimeType, "mp4")}", shareable = false)
    is PostMedia.VideoNote -> Savable(media.file, "video/mp4", "tgsocial-${media.file.uniqueId}.mp4", shareable = false)
    is PostMedia.Sticker -> Savable(media.file, "image/webp", "tgsocial-${media.file.uniqueId}.webp", shareable = false)
    is PostMedia.Document -> Savable(media.file, media.mimeType, media.fileName.ifBlank { "tgsocial-${media.file.uniqueId}" }, shareable = true)
    else -> null
}

/** `Save` (and `Share` for documents) in the viewer chrome. 26–28 ask for the storage permission at tap time. */
@Composable
private fun SaveActions(vm: AppViewModel, media: PostMedia) {
    val target = savable(media) ?: return
    val app = rememberTgApp()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun doSave() {
        scope.launch {
            val path = app.media.download(target.file, MediaRepo.PRIORITY_TAPPED, "Downloading file")
            if (path == null) {
                vm.toast.show("Couldn't save that.", HPToastTone.BAD)
                return@launch
            }
            val ok = app.media.save(context, path, target.mimeType, target.name)
            vm.toast.show(if (ok) "Saved." else "Couldn't save that.", if (ok) HPToastTone.GOOD else HPToastTone.BAD)
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) doSave() else vm.toast.show("Couldn't save that.", HPToastTone.BAD)
    }
    if (target.shareable) {
        HPViewerButton("Share", {
            // PRODUCT §2.22.3 — `Share`, anywhere it appears, answers with the line that says why.
            if (DemoGate.refused(DemoCopy.NOT_ON_TELEGRAM)) return@HPViewerButton
            scope.launch {
                val path = app.media.download(target.file, MediaRepo.PRIORITY_TAPPED, "Downloading file")
                if (path != null) app.media.share(context, path, target.mimeType)
            }
        })
    }
    HPViewerButton("Save", {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) permission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        else doSave()
    })
}

/** Photo page: blur-up mini under the full pixels, pinch/double-tap zoom, downward drag hands off to dismiss. */
@Composable
private fun ViewerImage(file: FileRef, mini: String?, dismiss: HPViewerDismissState) {
    val app = rememberTgApp()
    // The viewer is a tapped context: fetch at priority 32, not the visible-in-feed 1 (PRODUCT §2.11), and at
    // the one-step-up zoom rendition — a real pixel count with a hard ceiling, not a doubled Dp.
    val image = rememberTdImagePx(file, app.media.zoomWidthPx, MediaRepo.PRIORITY_TAPPED)
    val miniImage = rememberMini(mini)
    val state = rememberFileState(file)
    HPZoomable(dismiss) {
        when {
            image != null -> Image(bitmap = image, contentDescription = "Photo", modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
            miniImage != null -> Image(bitmap = miniImage, contentDescription = null, modifier = Modifier.fillMaxSize().blur(HPTokens.Space.rowGap), contentScale = ContentScale.Fit)
            else -> Unit
        }
        if (image == null && state?.active == true) {
            HPDownloadRing(state.progress, onCancel = { app.media.cancel(file) })
        }
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun ViewerPlayer(
    key: String,
    file: FileRef,
    mimeType: String,
    durationSeconds: Int,
    aspect: Float,
    loop: Boolean,
    muted: Boolean,
    dismiss: HPViewerDismissState,
    transport: Boolean = true,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .hpViewerDismiss(dismiss),
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.fillMaxWidth().aspectRatio(aspect.coerceIn(0.4f, 2.5f))) {
            InlinePlayerSurface(
                key = key,
                file = file,
                mimeType = mimeType,
                durationSeconds = durationSeconds,
                loop = loop,
                muted = muted,
                onSurfaceTap = null,
                showTransport = transport,
            )
        }
    }
}

@Composable
private fun ViewerGif(media: PostMedia.Animation, dismiss: HPViewerDismissState) {
    val app = rememberTgApp()
    var path by remember(media.file.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(media.file.id) { path = app.media.localPath(media.file) ?: app.media.download(media.file, MediaRepo.PRIORITY_TAPPED, "Downloading animation") }
    HPZoomable(dismiss) {
        Box(Modifier.fillMaxWidth().aspectRatio(aspect(media.width, media.height).coerceIn(0.4f, 2.5f))) {
            val p = path
            if (p != null) AnimatedGif(p, media.thumb)
        }
    }
}

@OptIn(UnstableApi::class)
@Composable
private fun ViewerVideoNote(key: String, media: PostMedia.VideoNote, dismiss: HPViewerDismissState) {
    Box(Modifier.fillMaxSize().hpViewerDismiss(dismiss), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .fillMaxWidth(0.86f)
                .aspectRatio(1f)
                .clip(CircleShape),
        ) {
            InlinePlayerSurface(
                key = key,
                file = media.file,
                mimeType = "video/mp4",
                durationSeconds = media.durationSeconds,
                loop = false,
                muted = false,
                onSurfaceTap = null,
                showTransport = false,
            )
        }
    }
}

/** Documents in the viewer: PDF pages, text in the mono face, images zoomable, audio/video through the player. */
@OptIn(UnstableApi::class)
@Composable
private fun ViewerDocument(key: String, media: PostMedia.Document, dismiss: HPViewerDismissState) {
    val app = rememberTgApp()
    val state = rememberFileState(media.file)
    var path by remember(media.file.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(media.file.id) { path = app.media.localPath(media.file) ?: app.media.download(media.file, MediaRepo.PRIORITY_TAPPED, "Downloading file") }
    val kind = docKind(media.mimeType, media.fileName)
    val ready = path
    if (ready == null) {
        Box(Modifier.fillMaxSize().hpViewerDismiss(dismiss), contentAlignment = Alignment.Center) {
            if (state?.active == true) HPDownloadRing(state.progress, onCancel = { app.media.cancel(media.file) })
        }
        return
    }
    when (kind) {
        DocKind.PDF -> PdfPages(ready)
        DocKind.TEXT -> TextDocument(ready, dismiss)
        DocKind.IMAGE -> ViewerImage(media.file, null, dismiss)
        DocKind.AUDIO -> ViewerPlayer(key, media.file, media.mimeType, 0, 16f / 9f, loop = false, muted = false, dismiss = dismiss)
        DocKind.VIDEO -> ViewerPlayer(key, media.file, media.mimeType, 0, 16f / 9f, loop = false, muted = false, dismiss = dismiss)
        DocKind.OTHER -> Box(Modifier.fillMaxSize().hpViewerDismiss(dismiss))
    }
}

/** android.graphics.pdf.PdfRenderer pages, one bitmap per page, in a lazy list on the ink ground. */
@Composable
private fun PdfPages(path: String) {
    val app = rememberTgApp()
    val widthPx = with(androidx.compose.ui.platform.LocalDensity.current) { LocalConfiguration.current.screenWidthDp.dp.roundToPx() }
    var count by remember(path) { mutableStateOf(0) }
    LaunchedEffect(path) { count = app.media.pdfPageCount(path) }
    LazyColumn(Modifier.fillMaxSize().padding(vertical = HPTokens.Space.bottomSafe)) {
        items(count) { index ->
            var page by remember(path, index) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
            LaunchedEffect(path, index) { page = app.media.pdfPage(path, index, widthPx) }
            val bmp = page
            if (bmp != null) {
                Image(bitmap = bmp, contentDescription = "Page ${index + 1}", modifier = Modifier.fillMaxWidth().padding(bottom = HPTokens.Space.labelBottom))
            } else {
                Box(Modifier.fillMaxWidth().aspectRatio(0.7f))
            }
        }
    }
}

/** Text documents read into a scrollable mono view on the ink ground. */
@Composable
private fun TextDocument(path: String, dismiss: HPViewerDismissState) {
    val app = rememberTgApp()
    var text by remember(path) { mutableStateOf("") }
    LaunchedEffect(path) { text = app.media.readText(path).orEmpty() }
    Box(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = HPTokens.Space.cardPad, vertical = HPTokens.Space.bottomSafe),
    ) {
        HPText(text, HPTokens.Type.monoSmall, HPTokens.Colors.charcoalText)
    }
}
