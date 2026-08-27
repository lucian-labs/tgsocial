package ca.lucianlabs.tgsocial.audio

import kotlin.math.exp

/**
 * PRODUCT §2.11.1 — the one-pole envelope follower: `y += (x > y ? attack : release) * (x - y)`.
 *
 * Fast attack, slow release, so the silhouette reads as the *shape of the take* rather than as a
 * peak-per-bin bar chart. One pole in each direction, nothing else.
 *
 * The two coefficients are **derived from the sample rate** rather than typed in as literals ([coefficient]);
 * a hard-coded 0.9 means one thing at 48 kHz and something else entirely at the decimated 16 kHz this runs
 * at, which is exactly the bug a magic number here produces.
 */
class OnePole(val attack: Float, val release: Float, start: Float = 0f) {

    var value: Float = start
        private set

    /** Feed one sample magnitude; returns the new envelope value. */
    fun next(x: Float): Float {
        val k = if (x > value) attack else release
        value += k * (x - value)
        return value
    }

    fun reset(to: Float = 0f) {
        value = to
    }

    companion object {
        /**
         * The one-pole coefficient for a time constant of [tauSeconds] at [sampleRate].
         *
         * `a = 1 − exp(−T/τ)` with `T = 1/rate` is the exact discretisation: it makes `y[n] = 1 − exp(−t/τ)`
         * for a unit step, so after exactly τ seconds the follower stands at `1 − 1/e ≈ 0.632` of the step and
         * after τ seconds of silence it has fallen to `1/e ≈ 0.368` — which is what
         * `OnePoleTest` asserts, and what makes "5 ms attack" a statement about milliseconds.
         */
        fun coefficient(tauSeconds: Double, sampleRate: Int): Float {
            require(sampleRate > 0) { "sampleRate must be > 0" }
            if (tauSeconds <= 0.0) return 1f
            return (1.0 - exp(-1.0 / (tauSeconds * sampleRate))).toFloat().coerceIn(0f, 1f)
        }
    }
}
