package ca.lucianlabs.tgsocial.protocol

/** PRODUCT §2.13 — public links. Always absolute to the canonical web host (PRODUCT §0). */
object PublicLink {
    const val ORIGIN = "https://tgsocial.lucianlabs.ca"

    /** `https://tgsocial.lucianlabs.ca/f/<channel>` — the link `Copy Link` copies. */
    fun feed(username: String): String = "$ORIGIN/f/$username"
}
