package ca.lucianlabs.tgsocial.audio

/**
 * Rate reduction on the way out of the decoder: a box average over each output sample's span, not a
 * pick-every-Nth.
 *
 * Dropping samples aliases everything above the new Nyquist straight back down into the band the strip is
 * about to draw — a cymbal would paint itself across the low rows as a wash that is not in the recording.
 * A box average is a crude but real low-pass (a sinc-shaped response with its first null at the output rate),
 * costs one add per input sample, and is what makes the decimation honest at the price the strip can afford.
 *
 * Fractional ratios are handled by a phase accumulator, so 44 100 → 16 000 works as well as 48 000 → 16 000.
 *
 * ### [capacity] is a ceiling, never a reservation
 * The buffer **grows** to what the clip actually produces and stops at [capacity]; it is not allocated at
 * [capacity] up front. That distinction is the whole memory story of the audio path: the cap callers pass is
 * `SpectrogramSpec.MAX_SAMPLES` (10 minutes at 16 kHz = 9.6 M floats = 36.6 MB), so an eager `FloatArray`
 * charged every three-second voice note 36.6 MB — more than a third of a 96 MB heap, for 0.18 MB of signal,
 * and outside the accounting `MediaBudget` exists to keep. Doubling from [INITIAL] costs an amortised copy
 * per sample and makes the transient proportional to the clip.
 */
class Decimator(sourceRate: Int, targetRate: Int, private val capacity: Int) {
    init {
        require(sourceRate > 0 && targetRate > 0) { "rates must be > 0" }
        require(capacity >= 0) { "capacity must be >= 0" }
    }

    /** Output samples produced per input sample. */
    private val step: Double = targetRate.toDouble() / sourceRate

    /** Grown on demand up to [capacity]; see the class note on why this is not `FloatArray(capacity)`. */
    private var out = FloatArray(minOf(capacity, INITIAL))

    private var phase = 0.0
    private var sum = 0.0
    private var count = 0

    var size: Int = 0
        private set

    /** True once [capacity] output samples exist — the caller should stop decoding. */
    val full: Boolean get() = size >= capacity

    fun push(sample: Float) {
        if (full) return
        sum += sample
        count++
        phase += step
        while (phase >= 1.0 && !full) {
            phase -= 1.0
            if (size == out.size) grow()
            out[size++] = if (count > 0) (sum / count).toFloat() else 0f
            sum = 0.0
            count = 0
        }
    }

    /** Double, clamped to [capacity] — never past the cap, so the ceiling still binds the allocation. */
    private fun grow() {
        val next = (out.size * 2).coerceAtLeast(INITIAL).coerceAtMost(capacity)
        out = out.copyOf(next)
    }

    /** The decimated signal, trimmed to what was actually produced. */
    fun result(): FloatArray = if (size == out.size) out else out.copyOf(size)

    private companion object {
        /** 16 KB — a quarter-second at 16 kHz, so a voice note reaches its length in a handful of doublings. */
        const val INITIAL = 4096
    }
}
