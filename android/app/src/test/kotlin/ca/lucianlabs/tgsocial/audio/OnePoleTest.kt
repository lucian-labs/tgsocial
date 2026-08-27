package ca.lucianlabs.tgsocial.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.11.1 — the one-pole follower, asserted as a statement about **time** rather than about a
 * multiplier. The whole reason [OnePole.coefficient] exists is that "5 ms attack" has to survive a change of
 * sample rate; a test that only checked `y` moved in the right direction would pass with the coefficients
 * swapped.
 */
class OnePoleTest {

    private val rate = SpectrogramSpec.RATE

    @Test
    fun `a step input rises to one time constant in exactly the attack time`() {
        val follower = OnePole(SpectrogramSpec.attackAt(rate), SpectrogramSpec.releaseAt(rate))
        val samples = (SpectrogramSpec.ATTACK_SECONDS * rate).toInt()
        repeat(samples) { follower.next(1f) }
        // y(t) = 1 - exp(-t/tau); at t = tau that is 0.6321.
        assertEquals(0.6321f, follower.value, 0.01f)
    }

    @Test
    fun `and keeps rising toward the step, reaching it after several time constants`() {
        val follower = OnePole(SpectrogramSpec.attackAt(rate), SpectrogramSpec.releaseAt(rate))
        repeat((SpectrogramSpec.ATTACK_SECONDS * rate * 5).toInt()) { follower.next(1f) }
        assertEquals(1f, follower.value, 0.02f)
    }

    @Test
    fun `and decays to one time constant in exactly the release time`() {
        val follower = OnePole(SpectrogramSpec.attackAt(rate), SpectrogramSpec.releaseAt(rate), start = 1f)
        repeat((SpectrogramSpec.RELEASE_SECONDS * rate).toInt()) { follower.next(0f) }
        // 1/e of the starting value.
        assertEquals(0.3679f, follower.value, 0.01f)
    }

    @Test
    fun `attack is fast and release is slow, which is the shape of the take`() {
        assertTrue(
            "attack must move faster than release",
            SpectrogramSpec.attackAt(rate) > SpectrogramSpec.releaseAt(rate) * 10f,
        )
    }

    @Test
    fun `the coefficient is derived from the rate, not fixed`() {
        val slow = OnePole.coefficient(0.05, 8_000)
        val fast = OnePole.coefficient(0.05, 48_000)
        assertTrue("a higher rate needs a smaller per-sample step for the same time constant", fast < slow)
        // Same time constant, different rates: the same wall-clock behaviour either way.
        for (r in intArrayOf(8_000, 16_000, 48_000)) {
            val follower = OnePole(OnePole.coefficient(0.05, r), 1f)
            repeat((0.05 * r).toInt()) { follower.next(1f) }
            assertEquals("rate $r", 0.6321f, follower.value, 0.01f)
        }
    }

    @Test
    fun `a zero time constant tracks the input exactly`() {
        assertEquals(1f, OnePole.coefficient(0.0, rate), 0f)
        val follower = OnePole(1f, 1f)
        assertEquals(0.7f, follower.next(0.7f), 0f)
    }
}
