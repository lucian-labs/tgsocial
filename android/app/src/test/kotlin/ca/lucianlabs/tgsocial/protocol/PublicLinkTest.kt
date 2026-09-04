package ca.lucianlabs.tgsocial.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** PRODUCT §2.13 — the URL `Copy Link` puts on the clipboard, with and without a self-hosted public reader. */
class PublicLinkTest {
    private val configured = "https://tgsocial.example.org"

    /** The default path: nothing configured, so the link is Telegram's own — no server of one's own required. */
    @Test
    fun feedFallsBackToTheTelegramLinkWhenNoOriginIsConfigured() {
        assertEquals("https://t.me/waveloop_devlog", PublicLink.feed("waveloop_devlog", null))
    }

    /** An empty or whitespace `TGS_PUBLIC_ORIGIN=` line means "no reader of my own", not an origin of `""`. */
    @Test
    fun blankConfigurationIsUnset() {
        assertNull(PublicLink.origin(null))
        assertNull(PublicLink.origin(""))
        assertNull(PublicLink.origin("   "))
        assertEquals("https://t.me/waveloop_devlog", PublicLink.feed("waveloop_devlog", PublicLink.origin("")))
    }

    @Test
    fun feedUrlIsAbsoluteOnTheConfiguredOrigin() {
        assertEquals("$configured/f/waveloop_devlog", PublicLink.feed("waveloop_devlog", PublicLink.origin(configured)))
    }

    /** A pasted origin usually carries its trailing slash; `<origin>//f/x` is not a route the reader serves. */
    @Test
    fun trailingSlashOnTheConfiguredOriginIsDropped() {
        assertEquals("$configured/f/waveloop_devlog", PublicLink.feed("waveloop_devlog", PublicLink.origin("$configured/")))
    }

    @Test
    fun feedUrlKeepsTheUsernameCasingItIsGiven() {
        assertEquals("$configured/f/WaveLoop_Devlog", PublicLink.feed("WaveLoop_Devlog", PublicLink.origin(configured)))
        assertEquals("https://t.me/WaveLoop_Devlog", PublicLink.feed("WaveLoop_Devlog", null))
    }

    /**
     * The shapes that would mint a `Copy Link` nobody can follow, refused exactly as
     * `setPublicOrigin` refuses them in `web/js/protocol.js` — one `TGS_PUBLIC_ORIGIN` value has to
     * mean one thing on every client. A bare host stops being a link the moment it is pasted into a
     * chat; a path-carrying origin builds `<origin>/tgs/f/x`, which the root-anchored public routes
     * and `web/nginx-public.conf` never serve; `javascript:` is not an origin at all.
     */
    @Test
    fun originsThatWouldNotResolveAreRefused() {
        assertNull(PublicLink.origin("tgsocial.example.org"))
        assertNull(PublicLink.origin("$configured/tgs"))
        assertNull(PublicLink.origin("javascript:alert(1)"))
        assertNull(PublicLink.origin("$configured?ref=x"))
        assertNull(PublicLink.origin("$configured#top"))
        assertNull(PublicLink.origin("https://tgsocial.example.org and more"))
    }

    /** Refused is the same state as unset: sharing lands on t.me, which works, rather than on nonsense. */
    @Test
    fun aRefusedOriginSharesTheTelegramLink() {
        assertEquals("https://t.me/waveloop_devlog", PublicLink.feed("waveloop_devlog", PublicLink.origin("tgsocial.example.org")))
    }

    /** A reader on a dev box or the LAN is plain http on a port — an origin, and kept as one. */
    @Test
    fun plainHttpAndPortsAreOrigins() {
        assertEquals("http://192.168.1.20:8080", PublicLink.origin("http://192.168.1.20:8080"))
        assertEquals("http://localhost:8000/f/waveloop_devlog", PublicLink.feed("waveloop_devlog", PublicLink.origin("http://localhost:8000/")))
    }
}
