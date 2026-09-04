package ca.lucianlabs.tgsocial.ui.media

import android.content.Context
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import android.net.Uri
import ca.lucianlabs.tgsocial.demo.DemoFiles
import ca.lucianlabs.tgsocial.demo.DemoMedia
import ca.lucianlabs.tgsocial.model.FileRef
import java.io.File
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.repo.MediaRepo
import ca.lucianlabs.tgsocial.repo.TdDataSource
import ca.lucianlabs.tgsocial.td.TelegramClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * PRODUCT §2.11 player rules: one audio item at a time (the hub owns the single audio ExoPlayer, so a second
 * `toggle` pauses the first by construction); playback continues while scrolling and across tabs; a now-playing
 * row docks above the floating tab bar while an item is loaded. Videos register through [claimVideo] so starting
 * one pauses the others, and starting audio pauses the active video (and the other way round).
 */
@UnstableApi
class PlaybackHub(private val context: Context, private val tg: TelegramClient) {
    data class NowPlaying(
        val key: String,
        val title: String,
        val playing: Boolean = false,
        val positionMs: Long = 0,
        val durationMs: Long = 0,
        /**
         * The clip's stable TDLib id. PRODUCT §2.11.2 — the dock draws the envelope the STRIP analysed, and
         * this is what it looks that up by; the dock never knows (or asks for) a geometry of its own.
         */
        val uniqueId: String = "",
        /** PRODUCT §2.11 — "tapping the row anywhere but its controls opens the post the audio came from". */
        val post: Post? = null,
    ) {
        val progress: Float get() = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    }

    private val main = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var audio: ExoPlayer? = null
    private var audioDurationMs: Long = 0
    private var ticker: Job? = null

    private val _now = MutableStateFlow<NowPlaying?>(null)
    val now: StateFlow<NowPlaying?> = _now.asStateFlow()

    private val _activeVideo = MutableStateFlow<String?>(null)
    val activeVideo: StateFlow<String?> = _activeVideo.asStateFlow()

    /** A fresh player wired to the TDLib data source; the caller owns and releases it (inline video, viewer). */
    fun newPlayer(priority: Int = MediaRepo.PRIORITY_TAPPED): ExoPlayer =
        ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(TdDataSource.Factory(tg, priority)))
            .build()

    /**
     * PRODUCT §2.22.4 — a demo fixture plays from the file the generator wrote, never through the TDLib data
     * source. Same player, same transport, same `MediaItem`; a different URI, and no `downloadFile` behind it.
     */
    fun mediaItem(ref: FileRef, mimeType: String): MediaItem {
        // `existing`, not `path`: this runs on the main thread while a player is being built, and generating
        // an 18-second clip here would be an ANR. The surfaces below pre-warm the file before they let a tap
        // start playback, exactly as they wait on a download.
        val uri = if (DemoMedia.isDemo(ref)) DemoFiles.existing(ref)?.let { Uri.fromFile(File(it)) } else TdDataSource.uri(ref)
        return MediaItem.Builder()
            .setUri(uri ?: TdDataSource.uri(ref))
            .apply { if (mimeType.isNotBlank()) setMimeType(mimeType) }
            .build()
    }

    private fun audioPlayer(): ExoPlayer = audio ?: newPlayer(MediaRepo.PRIORITY_TAPPED).also { p ->
        audio = p
        p.setAudioAttributes(
            AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
            true,
        )
        p.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) = refresh()
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) {
                    p.pause()
                    p.seekTo(0)
                }
                refresh()
            }
        })
    }

    /** Play or pause one audio/voice item. Starting a different item replaces the current one. */
    fun toggleAudio(key: String, title: String, ref: FileRef, mimeType: String, durationSeconds: Int, post: Post? = null) {
        val p = audioPlayer()
        val current = _now.value
        if (current?.key == key) {
            if (p.isPlaying) p.pause() else {
                _activeVideo.value = null
                p.play()
            }
            refresh()
            return
        }
        _activeVideo.value = null
        audioDurationMs = durationSeconds * 1000L
        _now.value = NowPlaying(key, title, playing = true, durationMs = audioDurationMs, uniqueId = ref.uniqueId, post = post)
        p.setMediaItem(mediaItem(ref, mimeType))
        p.prepare()
        p.play()
        startTicker()
    }

    /** The now-playing row's play/pause: toggles whatever is loaded. */
    fun toggleCurrent() {
        val p = audio ?: return
        if (_now.value == null) return
        if (p.isPlaying) p.pause() else {
            _activeVideo.value = null
            p.play()
        }
        refresh()
    }

    fun seekAudio(fraction: Float) {
        val p = audio ?: return
        val duration = if (p.duration != C.TIME_UNSET) p.duration else audioDurationMs
        if (duration > 0) p.seekTo((duration * fraction.coerceIn(0f, 1f)).toLong())
        refresh()
    }

    fun stopAudio() {
        audio?.stop()
        audio?.clearMediaItems()
        ticker?.cancel()
        _now.value = null
    }

    /** An inline or full-screen video is starting: pause the previous video and the audio player. */
    fun claimVideo(key: String) {
        audio?.pause()
        refresh()
        _activeVideo.value = key
    }

    fun releaseVideo(key: String) {
        if (_activeVideo.value == key) _activeVideo.value = null
    }

    private fun startTicker() {
        ticker?.cancel()
        ticker = main.launch {
            while (_now.value != null) {
                refresh()
                delay(250)
            }
        }
    }

    private fun refresh() {
        val p = audio ?: return
        val current = _now.value ?: return
        val duration = if (p.duration != C.TIME_UNSET && p.duration > 0) p.duration else audioDurationMs
        _now.value = current.copy(playing = p.isPlaying, positionMs = p.currentPosition.coerceAtLeast(0), durationMs = duration)
    }

    /**
     * Memory pressure (`TgApp.onTrimMemory`): an ExoPlayer that is loaded but not playing is pure retained
     * cost — codecs, buffers, a renderer thread — so release it. A player that is actually playing is the
     * product (PRODUCT §2.11 keeps audio going across tabs), so it survives.
     */
    fun trimMemory() {
        val p = audio ?: return
        if (p.isPlaying) return
        ticker?.cancel()
        ticker = null
        p.release()
        audio = null
        _now.value = null
    }

    /** Sign-out / process teardown. */
    fun release() {
        ticker?.cancel()
        audio?.release()
        audio = null
        _now.value = null
        _activeVideo.value = null
    }
}
