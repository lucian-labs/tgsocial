package ca.lucianlabs.tgsocial.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/** PRODUCT §2.13 — the URL `Copy Link` puts on the clipboard: absolute, on the canonical host, `/f/<channel>`. */
class PublicLinkTest {
    @Test
    fun feedUrlIsAbsoluteOnTheCanonicalHost() {
        assertEquals("https://tgsocial.lucianlabs.ca/f/waveloop_devlog", PublicLink.feed("waveloop_devlog"))
    }

    @Test
    fun feedUrlKeepsTheUsernameCasingItIsGiven() {
        assertEquals("https://tgsocial.lucianlabs.ca/f/WaveLoop_Devlog", PublicLink.feed("WaveLoop_Devlog"))
    }
}
