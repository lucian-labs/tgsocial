package ca.lucianlabs.tgsocial.audio

import kotlin.math.exp
import kotlin.math.min

/**
 * Every number the spectrogram strip runs on, in one place with its derivation (PRODUCT §2.11.1).
 *
 * Colours and metrics are design tokens and live in `design/tokens.json`; these are *signal* constants, so
 * they live in code — but derived, never typed as literals at the point of use. The rule the strip has to
 * keep is "cost is bounded, and it degrades rather than blocking", and most of this file is that bound.
 */
object SpectrogramSpec {

    /**
     * The rate the clip is decimated to before analysis. §2.11.1: "8–16 kHz is plenty for a strip this
     * size" — take the top of that range, because it is also what sets the axis ceiling below.
     */
    const val RATE = 16_000

    /**
     * 2 048 points at [RATE] → 7.8 Hz bins over a 128 ms window, the same bin resolution Wake gets from
     * 8 192 points at 48 kHz (`WakeFFT.swift`: "fine enough to resolve the harmonic bands").
     */
    const val FFT_SIZE = 2048

    /** ~50 % overlap (§2.11.1). Fixed, so no audio is ever skipped between windows however long the clip is. */
    const val HOP = FFT_SIZE / 2

    /** The nominal axis of §2.11.1. */
    const val F_MIN = 20f
    const val F_MAX = 20_000f

    /**
     * The axis actually painted: the nominal ceiling clamped to Nyquist, because decimating to [RATE]
     * discards everything above it and Wake clamps the same way (`min(fMax, sr / 2)`).
     */
    fun effectiveFMax(rate: Int): Float = min(F_MAX, rate / 2f)

    /** How far under the rolling peak the strip's floor sits — Wake's `dynRangeDb`. */
    const val DYN_RANGE_DB = 48f

    /**
     * Wake's `agcFloor`: the magnitude below which the AGC stops opening, so true digital silence stays
     * dark instead of blowing up to full brightness. −120 dB, i.e. below anything a lossy codec produces,
     * because §2.11.1's whole point is that "a quiet recording still fills the strip".
     */
    const val AGC_FLOOR = 1e-6f

    /** Wake's `agcRelease`, expressed as the time constant it means rather than as a per-frame multiplier. */
    const val AGC_RELEASE_SECONDS = 3.0

    /**
     * Wake's spectral tilt (`tiltDbPerOct` / `tiltPivotHz`): natural sound has a ~1/f energy slope, so a raw
     * magnitude spectrum always reads bass-heavy. Lift by a fixed dB/octave about a mid-band pivot and
     * pink-ish content reads roughly flat.
     */
    const val TILT_DB_PER_OCT = 4.5f
    const val TILT_PIVOT_HZ = 1000f

    /** §2.11.1's "fast attack, slow release", as time constants; [attackAt] / [releaseAt] make them coefficients. */
    const val ATTACK_SECONDS = 0.005
    const val RELEASE_SECONDS = 0.180

    fun attackAt(rate: Int = RATE): Float = OnePole.coefficient(ATTACK_SECONDS, rate)
    fun releaseAt(rate: Int = RATE): Float = OnePole.coefficient(RELEASE_SECONDS, rate)

    /**
     * The AGC's per-frame release multiplier at a given hop — the direct analogue of Wake's `0.994`
     * ("≈ 5 s recovery at 30 Hz"), except derived, so a change to [HOP] or [RATE] cannot silently retune it.
     */
    fun agcReleaseAt(rate: Int = RATE, hop: Int = HOP): Float =
        exp(-(hop.toDouble() / rate) / AGC_RELEASE_SECONDS).toFloat()

    /**
     * Envelope normalisation floor. The silhouette is scaled to its own peak so a quiet take still reads,
     * but only down to here — below it the clip is silence and should look like silence, not like a
     * full-height wall of amplified noise. (Wake's `WavePane` does the same with `max(0.05, bins.max())`,
     * but over bins that are already normalised.)
     *
     * −60 dBFS, which is under any recording and above every codec's noise floor. Set this too high and the
     * floor stops being a silence guard and starts capping quiet takes: at −34 dBFS a genuinely soft voice
     * note draws at a fifth of the strip's height, which is the exact failure §2.11.1 forbids.
     */
    const val ENVELOPE_FLOOR = 0.001f

    /** How much of the strip's half-height the silhouette may claim, so the peaks do not touch the edges. */
    const val ENVELOPE_HEADROOM = 0.9f

    /**
     * §2.11.1's duration ceiling: "past a duration ceiling (about 10 minutes) … fall back to the
     * amplitude-only silhouette". A 10-minute clip at [RATE] is 9.6 M samples and ~9 400 hops; past that the
     * analysis stops being a background detail and starts being a reason the phone gets warm.
     */
    const val MAX_DURATION_SECONDS = 600

    /** The same bound in samples, applied to the decode itself so a lying duration cannot get past the cap. */
    const val MAX_SAMPLES = MAX_DURATION_SECONDS * RATE

    /**
     * Slack on a clip's declared duration before [samplesFor] cuts the decode off. Containers round their
     * duration down and several decoders emit a little past it; two seconds costs 128 KB and is the
     * difference between a cap and a truncated tail.
     */
    const val DURATION_SLACK_SECONDS = 2

    /**
     * The decode's sample ceiling for a clip of [durationSeconds] — the clip's own length plus
     * [DURATION_SLACK_SECONDS], never more than [MAX_SAMPLES].
     *
     * [MAX_SAMPLES] alone is a *cap*, and passing it as the ceiling for every clip turns it into a *floor*:
     * the decode then sizes its working buffer for ten minutes of audio whether the clip is ten minutes or
     * three seconds. Callers know the duration — TDLib sends it with the message — so they pass it, and the
     * transient the audio path holds becomes proportional to what is actually being analysed.
     */
    fun samplesFor(durationSeconds: Int, rate: Int = RATE): Int {
        if (durationSeconds <= 0 || rate <= 0) return 0
        val wanted = (durationSeconds.toLong() + DURATION_SLACK_SECONDS) * rate
        return wanted.coerceIn(0L, MAX_SAMPLES.toLong()).toInt()
    }

    fun analysable(durationSeconds: Int): Boolean =
        durationSeconds in 1..MAX_DURATION_SECONDS

    /**
     * §2.11.1: "one column per pixel, no more". Widths are quantised on the way down so a 2 dp difference in
     * layout between the feed and the thread screen does not produce a second analysis of the same clip —
     * the cache key is built from these, and it has to be the same key in both places.
     */
    const val MAX_COLUMNS = 512
    const val COLUMN_QUANTUM = 32
    const val MAX_ROWS = 128
    const val ROW_QUANTUM = 16

    fun columnsFor(widthPx: Int): Int =
        (min(widthPx, MAX_COLUMNS) / COLUMN_QUANTUM * COLUMN_QUANTUM).coerceAtLeast(COLUMN_QUANTUM)

    fun rowsFor(heightPx: Int): Int =
        (min(heightPx, MAX_ROWS) / ROW_QUANTUM * ROW_QUANTUM).coerceAtLeast(ROW_QUANTUM)

    /**
     * The cache key. It is the file's **identity** ([uniqueId] is TDLib's stable `remote.uniqueId`) plus the
     * geometry, and nothing about *where* it is being drawn — so the same clip in the feed and in a thread
     * shares one analysis, which is the point.
     */
    fun cacheKey(uniqueId: String, columns: Int, rows: Int): String = "strip:$uniqueId@${columns}x$rows"
}
