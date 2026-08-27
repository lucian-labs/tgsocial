package ca.lucianlabs.tgsocial

import android.app.Application
import android.content.ComponentCallbacks2
import android.content.res.Configuration
import android.util.Log
import androidx.media3.common.util.UnstableApi
import ca.lucianlabs.tgsocial.repo.ActivityRegistry
import ca.lucianlabs.tgsocial.repo.AudioStripRepo
import ca.lucianlabs.tgsocial.repo.CommentRepo
import ca.lucianlabs.tgsocial.repo.DiscoveryRepo
import ca.lucianlabs.tgsocial.repo.FeedRepo
import ca.lucianlabs.tgsocial.repo.LocalStore
import ca.lucianlabs.tgsocial.repo.MediaRepo
import ca.lucianlabs.tgsocial.repo.MyNodeRepo
import ca.lucianlabs.tgsocial.repo.NodeRepo
import ca.lucianlabs.tgsocial.repo.PostingRepo
import ca.lucianlabs.tgsocial.td.TelegramClient
import ca.lucianlabs.tgsocial.ui.media.PlaybackHub
import ca.lucianlabs.tgsocial.ui.media.mediaWidthDp

/** Process-scoped graph: one TDLib client with its collectors attached in onCreate, and the repositories over it. */
@UnstableApi
class TgApp : Application() {
    lateinit var tg: TelegramClient
        private set
    lateinit var activity: ActivityRegistry
        private set
    lateinit var store: LocalStore
        private set
    lateinit var nodes: NodeRepo
        private set
    lateinit var myNode: MyNodeRepo
        private set
    lateinit var feed: FeedRepo
        private set
    lateinit var comments: CommentRepo
        private set
    lateinit var discovery: DiscoveryRepo
        private set
    lateinit var posting: PostingRepo
        private set
    lateinit var media: MediaRepo
        private set
    lateinit var playback: PlaybackHub
        private set
    lateinit var strips: AudioStripRepo
        private set

    override fun onCreate() {
        super.onCreate()
        tg = TelegramClient(this)
        activity = ActivityRegistry(tg.scope)
        store = LocalStore(this)
        nodes = NodeRepo(tg, store, activity)
        myNode = MyNodeRepo(tg, store, nodes, activity)
        feed = FeedRepo(tg, nodes, store, activity)
        comments = CommentRepo(tg, nodes, activity)
        discovery = DiscoveryRepo(tg, nodes)
        posting = PostingRepo(this, tg)
        // The decode budget and the decode buckets are both derived here: bytes from the heap ceiling ART gave
        // this process, pixel sizes from the geometry below (MediaBudget documents the arithmetic).
        media = MediaRepo(tg, activity, columnMediaWidthPx(), resources.displayMetrics.widthPixels)
        playback = PlaybackHub(this, tg)
        // PRODUCT §2.11.1 — the spectrogram analyser. It keeps nothing itself: strips land in MediaRepo's
        // byte-bounded cache, so they trim with everything else under memory pressure.
        strips = AudioStripRepo(media, tg.scope)
        feed.displayWidthPx = resources.displayMetrics.widthPixels
        comments.displayWidthPx = resources.displayMetrics.widthPixels
        tg.start()
    }

    /**
     * The width, in real pixels, that a full-bleed feed image is drawn at right now — the House Pour column,
     * not the display. `mediaWidthDp` is the same expression the card itself lays out with.
     */
    private fun columnMediaWidthPx(): Int {
        val metrics = resources.displayMetrics
        return (mediaWidthDp(resources.configuration.screenWidthDp).value * metrics.density).toInt().coerceAtLeast(1)
    }

    /**
     * MainActivity handles `orientation|screenSize|screenLayout` itself, so the activity is never recreated on
     * rotation and nothing downstream would ever re-derive the decode geometry. Without this a landscape card —
     * a wider column than portrait, up to `columnMax` — asked for more pixels than the frozen portrait bucket
     * allowed and every inline photo fell through to the 2048 px zoom rendition, ~4x the bytes it draws.
     */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (!::media.isInitialized) return
        media.onDisplayChanged(columnMediaWidthPx(), resources.displayMetrics.widthPixels)
    }

    /**
     * The platform's memory-pressure signal. Decoded pixels are the only thing this process holds that is both
     * large and re-derivable — TDLib keeps the files on disk — so they are what goes first, before Android
     * decides to kill us instead. Nothing on screen blanks: a composable drawing an `ImageBitmap` holds its own
     * reference, and a card scrolled back into view decodes again from the local file.
     */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        when (level) {
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE -> media.trimMemory(0.75f)
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> media.trimMemory(0.5f)
            ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> hardTrim()
            // UI_HIDDEN (20) and everything above it: we are not the foreground app, so nothing needs pixels.
            else -> if (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) hardTrim()
        }
        Log.i(TAG, "onTrimMemory($level) → ${media.cacheStats()}")
    }

    /** Still delivered on API 26-33; a synonym for the hardest trim level. */
    @Suppress("OVERRIDE_DEPRECATION")
    override fun onLowMemory() {
        super.onLowMemory()
        hardTrim()
    }

    private fun hardTrim() {
        media.evictImages()
        playback.trimMemory()
    }

    private companion object {
        const val TAG = "TgApp"
    }
}
