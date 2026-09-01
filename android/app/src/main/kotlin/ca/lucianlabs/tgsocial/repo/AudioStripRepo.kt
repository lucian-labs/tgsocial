package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.audio.AudioStrip
import ca.lucianlabs.tgsocial.audio.PcmDecoder
import ca.lucianlabs.tgsocial.audio.Spectrogram
import ca.lucianlabs.tgsocial.audio.SpectrogramSpec
import ca.lucianlabs.tgsocial.audio.StripRender
import ca.lucianlabs.tgsocial.model.FileRef
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/**
 * PRODUCT §2.11.1 — runs the spectrogram analysis and hands the result to the player row.
 *
 * ### Where the work happens
 * Nothing here touches the main thread. [request] returns immediately; the decode runs on
 * [Dispatchers.IO] (it is a `MediaCodec` pumping buffers) and the transform on [Dispatchers.Default] (it is
 * arithmetic, and belongs on the CPU pool rather than in the I/O pool's much larger thread budget).
 *
 * ### What it holds
 * The strips live in [MediaRepo]'s byte-bounded cache, which is the only place in this process allowed to
 * keep bitmaps resident; this class publishes a [ready] counter so a composable can re-read the cache when a
 * strip lands. Holding the strips here as well would mean a cache eviction frees nothing, which is how a
 * "cache" becomes a leak.
 *
 * It does hold the **envelopes** — [envelope] — and PRODUCT §2.11.2 is why. The dock's mini waveform is a
 * *view of the analysis the strip already did*, at the dock's width rather than the strip's, and the strip
 * cache is keyed by geometry: looking a clip up at the dock's width finds nothing and would start a second
 * analysis to draw a 40dp line. So the envelope — a few thousand floats, not a bitmap — is kept by clip and
 * resampled on read. It is a [ENVELOPE_CAP]-entry access-ordered map, so it is bounded like everything else
 * here, and it is the *only* thing playback ever reads: `request` is never reached from the dock.
 *
 * ### What it refuses to do
 * - Analyse a clip past [SpectrogramSpec.MAX_DURATION_SECONDS] — §2.11.1's ceiling. A 20-minute podcast
 *   keeps the hairline; the point of a cap is that the expensive path does not run.
 * - Analyse the same key twice concurrently, or retry a key that already failed. A file that will not decode
 *   on this device will not decode on the next scroll past it either, and a feed is very good at asking
 *   again.
 * - Start anything before the strip has been seen. That gate is the caller's: [request] is only reached from
 *   the strip's own on-screen callback (or from a tap on play).
 * - Run more than [MediaBudget.STRIP_ANALYSIS_CONCURRENCY] analyses at once. The decode's transient PCM is
 *   the largest allocation on this path — larger than the strip it produces, larger than the whole strip
 *   cache — and [Dispatchers.IO]'s 64 threads mean a fling past three audio posts would otherwise start
 *   three decodes with nothing between them and the heap ceiling. The permit is taken *after* the download,
 *   so a slow fetch never blocks an analysis whose bytes are already on disk.
 */
class AudioStripRepo(
    private val media: StripSource,
    private val scope: CoroutineScope,
    private val cpu: CoroutineDispatcher = Dispatchers.Default,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {

    /** Bumped whenever a strip lands in the cache; the player row re-reads [strip] on a change. */
    private val _ready = MutableStateFlow(0)
    val ready: StateFlow<Int> = _ready.asStateFlow()

    /**
     * How many analyses this repo has actually started, ever.
     *
     * PRODUCT §2.11.2 — "playing a clip must never trigger a second analysis" — is a claim about a number,
     * so the number is observable and `MiniWaveEnvelopeTest` asserts it rather than trusting a comment.
     */
    @Volatile
    var analyses: Int = 0
        private set

    /**
     * The envelope for a clip, by `uniqueId` and at whatever geometry produced it — see the class note.
     * Bounded and access-ordered: unbounded, this would be a slow leak keyed by every clip ever played.
     */
    private val envelopes = object : LinkedHashMap<String, FloatArray>(0, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, FloatArray>) = size > ENVELOPE_CAP
    }

    private val lock = Any()
    private val inFlight = HashSet<String>()

    /** The concurrency bound above; see [MediaBudget.STRIP_ANALYSIS_CONCURRENCY] for the derivation. */
    private val analysis = Semaphore(MediaBudget.STRIP_ANALYSIS_CONCURRENCY)

    /**
     * Keys that will never produce a strip — a codec failure, an empty decode, a clip past the cap. Bounded
     * and access-ordered: an unbounded negative cache is a slow leak keyed by every clip ever scrolled past.
     */
    private val failed = object : LinkedHashMap<String, Boolean>(0, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Boolean>) = size > FAILED_CAP
    }

    /**
     * PRODUCT §2.11.2 — the envelope the strip analysed for this clip, at any geometry, or null.
     *
     * Reads only. Nothing on this path starts work: a clip nobody has analysed (or one whose strip degraded
     * to the hairline) answers null, and the dock draws the flat line §2.11.2 asks for.
     */
    fun envelope(uniqueId: String): FloatArray? = synchronized(lock) { envelopes[uniqueId] }

    /**
     * An envelope that cost no analysis — a voice note's TDLib waveform bytes (§2.11.1), which the player row
     * draws immediately. Offered so the dock can draw the same shape for a clip whose spectrum has not landed
     * yet; an analysed envelope always wins, and never gets overwritten by the coarser one.
     */
    fun offerEnvelope(uniqueId: String, envelope: FloatArray) {
        if (uniqueId.isBlank() || envelope.size < 2) return
        synchronized(lock) { if (uniqueId !in envelopes) envelopes[uniqueId] = envelope }
    }

    /**
     * The cached strip for this file at this geometry, or null — nothing here ever blocks.
     *
     * Handing one out also publishes its envelope to the dock (§2.11.2). The player row reads this on every
     * recomposition, so the dock's copy tracks whatever is actually on screen — including a strip this
     * process never analysed itself, and a strip re-analysed after a memory-pressure eviction.
     */
    fun strip(uniqueId: String, widthPx: Int, heightPx: Int): AudioStrip? {
        val key = keyFor(uniqueId, widthPx, heightPx) ?: return null
        val strip = media.strip(key) ?: return null
        if (strip.envelope.size >= 2) synchronized(lock) { envelopes[uniqueId] = strip.envelope }
        return strip
    }

    /** The cache key for a strip of this geometry, or null if it has not been measured yet. */
    fun keyFor(uniqueId: String, widthPx: Int, heightPx: Int): String? {
        if (uniqueId.isBlank() || widthPx <= 0 || heightPx <= 0) return null
        return SpectrogramSpec.cacheKey(
            uniqueId,
            SpectrogramSpec.columnsFor(widthPx),
            SpectrogramSpec.rowsFor(heightPx),
        )
    }

    /**
     * Analyse [ref] for a strip of this pixel geometry, unless it is already cached, already running, already
     * known to fail, or too long to be worth it. Safe to call on every recomposition.
     */
    fun request(ref: FileRef, durationSeconds: Int, widthPx: Int, heightPx: Int) {
        val key = keyFor(ref.uniqueId, widthPx, heightPx) ?: return
        if (media.strip(key) != null) return
        val columns = SpectrogramSpec.columnsFor(widthPx)
        val rows = SpectrogramSpec.rowsFor(heightPx)

        synchronized(lock) {
            if (key in inFlight || failed.containsKey(key)) return
            if (!SpectrogramSpec.analysable(durationSeconds)) {
                // Past the ceiling this is a permanent decision, not a transient failure: the fallback
                // silhouette for a clip this long would itself cost the decode the cap exists to avoid.
                failed[key] = true
                return
            }
            inFlight += key
            analyses++
        }

        scope.launch {
            try {
                // PRODUCT §2.11: visible media is fetched at priority 1. A strip *is* the visible media here,
                // and there is nothing to analyse until the bytes are on disk.
                val path = media.localPath(ref)
                    ?: media.download(ref, MediaRepo.PRIORITY_VISIBLE, "Analysing audio")
                    ?: return@launch fail(key)

                // The decode's ceiling is the CLIP's length, not §2.11.1's ten-minute cap: the cap bounds
                // what a lying container may cost, and sizing every decode by it would charge a three-second
                // voice note the ten-minute buffer (MediaBudget.pcmBytes(MAX_SAMPLES) = 36.6 MB).
                val samples = SpectrogramSpec.samplesFor(durationSeconds)
                val strip = analysis.withPermit {
                    val pcm = withContext(io) { PcmDecoder.decodeMono(path, maxSamples = samples) }
                        ?: return@launch fail(key)
                    val data = withContext(cpu) { Spectrogram.analyse(pcm, SpectrogramSpec.RATE, columns, rows) }
                    withContext(cpu) { StripRender.render(data) }
                }
                if (strip.spectrum == null && strip.envelope.size < 2) return@launch fail(key)

                media.putStrip(key, strip)
                // The dock's copy: an analysed envelope, kept by clip so playing it never asks for another
                // analysis at the dock's own width (§2.11.2).
                if (strip.envelope.size >= 2) synchronized(lock) { envelopes[ref.uniqueId] = strip.envelope }
                _ready.value++
            } finally {
                synchronized(lock) { inFlight -= key }
            }
        }
    }

    /** Sign-out: the strips themselves go with [MediaRepo.clear]. */
    fun clear() = synchronized(lock) {
        inFlight.clear()
        failed.clear()
        envelopes.clear()
    }

    private fun fail(key: String) = synchronized(lock) { failed[key] = true; Unit }

    private companion object {
        const val FAILED_CAP = 128

        /**
         * Envelopes kept for the dock. One entry is `columns` floats — a full-width strip's 1 400 columns is
         * 5.6 KB — so this ceiling is the same order as [MediaBudget.MIN_STRIP_BYTES] holds in bitmaps, for a
         * cache that outlives them precisely because it is cheap.
         */
        const val ENVELOPE_CAP = MediaBudget.STRIP_COUNT_LIMIT
    }
}
