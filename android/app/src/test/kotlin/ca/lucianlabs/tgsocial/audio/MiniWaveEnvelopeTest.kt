package ca.lucianlabs.tgsocial.audio

import ca.lucianlabs.housepour.HPEnvelope
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.repo.AudioStripRepo
import ca.lucianlabs.tgsocial.repo.StripSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.11.2 — **the dock's waveform is a view of the analysis the strip already did.**
 *
 * "Playing a clip must never trigger a second analysis" is a claim about a number, so this counts:
 * [AudioStripRepo.analyses] rises exactly when an analysis starts, and every step of the dock's path —
 * looking the clip up, resampling it to the dock's own width, drawing it — leaves it where it was.
 *
 * The seam is [StripSource]: the strip cache and the bytes on disk, faked here so the *policy* can be
 * asserted without TDLib, a `MediaCodec`, or a `Bitmap`.
 */
class MiniWaveEnvelopeTest {

    /** The strip cache and the file system, as far as [AudioStripRepo] can tell. Counts what it is asked. */
    private class FakeStripSource : StripSource {
        val strips = HashMap<String, AudioStrip>()
        var pathLookups = 0
        var downloads = 0

        override fun strip(key: String): AudioStrip? = strips[key]

        override fun putStrip(key: String, strip: AudioStrip) {
            strips[key] = strip
        }

        override suspend fun localPath(ref: FileRef): String? {
            pathLookups++
            return null
        }

        override suspend fun download(ref: FileRef, priority: Int, label: String, timeoutMs: Long): String? {
            downloads++
            return null
        }
    }

    private val ref = FileRef(id = 7, uniqueId = "clip-7")
    private val duration = 30

    /** The row's geometry, and a different one for the dock — the whole reason a second analysis was a risk. */
    private val rowWidth = 960
    private val rowHeight = 132
    private val dockWidth = 288

    private fun repo(fake: FakeStripSource) = AudioStripRepo(fake, CoroutineScope(Dispatchers.Unconfined))

    private fun analysed(columns: Int): FloatArray = FloatArray(columns) { i -> (i % 10) / 10f }

    private fun cache(fake: FakeStripSource, repo: AudioStripRepo, envelope: FloatArray) {
        val key = repo.keyFor(ref.uniqueId, rowWidth, rowHeight)!!
        fake.putStrip(key, AudioStrip(spectrum = null, envelope = envelope, bytes = envelope.size * 4L))
    }

    @Test
    fun `the dock draws the strip's own envelope, and asks for no analysis of its own`() {
        val fake = FakeStripSource()
        val repo = repo(fake)
        val envelope = analysed(SpectrogramSpec.columnsFor(rowWidth))
        cache(fake, repo, envelope)

        // The player row draws its strip: cached, so nothing is analysed.
        val strip = repo.strip(ref.uniqueId, rowWidth, rowHeight)
        assertSame("the row drew the cached strip", envelope, strip?.envelope)
        assertEquals("nothing was analysed", 0, repo.analyses)

        // Playback starts. The dock asks by CLIP, at its own width — the geometry the strip cache is keyed by
        // would miss here, which is exactly the second analysis §2.11.2 forbids.
        val forDock = repo.envelope(ref.uniqueId)
        assertSame("the dock got the same array, not a new one", envelope, forDock)
        assertEquals("playing the clip analysed nothing", 0, repo.analyses)
        assertEquals("and did not go near the file", 0, fake.pathLookups + fake.downloads)

        // Drawing it is a resample to the dock's width and nothing else.
        val peaks = HPEnvelope.peaks(forDock, dockWidth)!!
        assertEquals("resampled to the dock's width", dockWidth, peaks.size)
        assertEquals("still nothing analysed", 0, repo.analyses)

        // And the row keeps re-reading it every recomposition without ever tipping into one.
        repeat(20) {
            repo.strip(ref.uniqueId, rowWidth, rowHeight)
            repo.envelope(ref.uniqueId)
        }
        assertEquals(0, repo.analyses)
    }

    /** The counter is not vacuous: an uncached clip DOES start one, exactly once, and never again. */
    @Test
    fun `an uncached clip is analysed once`() {
        val fake = FakeStripSource()
        val repo = repo(fake)
        repo.request(ref, duration, rowWidth, rowHeight)
        assertEquals("the row that has never seen this clip analyses it", 1, repo.analyses)
        assertTrue("and goes for the bytes", fake.pathLookups + fake.downloads > 0)

        // The decode failed (no bytes), which §2.11.1 makes a permanent decision, and a feed asks again a lot.
        repeat(10) { repo.request(ref, duration, rowWidth, rowHeight) }
        assertEquals("a failed clip is not retried", 1, repo.analyses)
    }

    /** A voice note's envelope arrives with the message; the dock draws that rather than a flat line. */
    @Test
    fun `an envelope that cost no analysis is enough for the dock`() {
        val fake = FakeStripSource()
        val repo = repo(fake)
        val fromTelegram = FloatArray(128) { it / 128f }
        repo.offerEnvelope(ref.uniqueId, fromTelegram)
        assertSame(fromTelegram, repo.envelope(ref.uniqueId))
        assertEquals(0, repo.analyses)

        // An analysed envelope wins, and the coarser one never overwrites it afterwards.
        val real = analysed(SpectrogramSpec.columnsFor(rowWidth))
        cache(fake, repo, real)
        repo.strip(ref.uniqueId, rowWidth, rowHeight)
        repo.offerEnvelope(ref.uniqueId, fromTelegram)
        assertSame("the analysis stands", real, repo.envelope(ref.uniqueId))
    }

    /** §2.11.2: "a clip whose strip degraded to the hairline shows a flat line rather than nothing." */
    @Test
    fun `a clip with no envelope resamples to nothing, which is the flat line`() {
        val repo = repo(FakeStripSource())
        assertNull("nothing analysed, nothing known", repo.envelope("never-seen"))
        assertNull("and nothing to draw", HPEnvelope.peaks(repo.envelope("never-seen"), dockWidth))
        assertEquals("asking did not start anything", 0, repo.analyses)
    }

    @Test
    fun `the resample keeps peaks rather than averaging them away`() {
        // A transient in one source column must survive into the column that covers it: an average would
        // turn the loudest moment of a take into nothing, which is the one thing the line is for.
        val source = FloatArray(100) { if (it == 42) 1f else 0.1f }
        val peaks = HPEnvelope.peaks(source, 10)!!
        assertEquals(10, peaks.size)
        assertEquals("the transient survived", 1f, peaks[4], 0.001f)
        assertEquals("its neighbours did not inherit it", 0.1f, peaks[3], 0.001f)

        // Nothing is invented at the other end: a short envelope is returned as it stands and the polyline
        // simply spreads it across the width.
        val short = FloatArray(8) { it / 8f }
        assertSame(short, HPEnvelope.peaks(short, 400))
        assertArrayEquals(short, HPEnvelope.peaks(short, 400)!!, 0f)
    }
}
